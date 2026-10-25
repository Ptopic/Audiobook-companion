import Foundation
import Security

enum RemoteAPIError: LocalizedError {
    case missingToken
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingToken: "Add your remote access token in Settings first."
        case .invalidResponse: "The server returned an unexpected response. Please try again."
        case .server(let message): message
        }
    }
}

enum RemoteTokenStore {
    private static let service = "com.petartopic.audiobookcompanion.remote"
    private static let account = "access-token"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(token.utf8)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecSuccess { return }
        guard result == errSecItemNotFound else {
            throw RemoteAPIError.server("Could not update the token in Keychain.")
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw RemoteAPIError.server("Could not save the token in Keychain.")
        }
    }
}

struct AudiobookAPI {
    var baseURL: URL

    func catalog() async throws -> [AudiobookSummary] {
        let url = baseURL.appending(path: "api/audiobooks")
        return try await decode([AudiobookSummary].self, from: url)
    }

    func manifest(for summary: AudiobookSummary) async throws -> AudiobookManifest {
        let url = resolve(summary.manifestURL)
        return try await decode(AudiobookManifest.self, from: url)
    }

    func audioURL(for chapter: AudiobookChapter) -> URL? {
        guard let audioURL = chapter.audioURL else { return nil }
        return resolve(audioURL)
    }

    func assetURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        return resolve(value)
    }

    func uploadEPUB(_ fileURL: URL) async throws -> RemoteBook {
        let authorized = fileURL.startAccessingSecurityScopedResource()
        defer { if authorized { fileURL.stopAccessingSecurityScopedResource() } }

        let boundary = "Audiobook-\(UUID().uuidString)"
        let multipartURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: multipartURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: multipartURL) }

        let output = try FileHandle(forWritingTo: multipartURL)
        defer { try? output.close() }
        let unsafeFilenameCharacters = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\""))
        let cleanedFilename = fileURL.lastPathComponent.components(separatedBy: unsafeFilenameCharacters).joined()
        let filename = cleanedFilename.isEmpty ? "book.epub" : cleanedFilename
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/epub+zip\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try output.close()

        var request = try remoteRequest(path: "api/remote/books", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: multipartURL)
        return try remoteDecode(RemoteBook.self, data: data, response: response)
    }

    func createJob(bookID: String, chapters: [String], voice: String, speed: Double) async throws -> RemoteJobCreated {
        var request = try remoteRequest(path: "api/remote/books/\(bookID)/jobs", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "include_chapters": chapters,
            "voice": voice,
            "speed": speed,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        return try remoteDecode(RemoteJobCreated.self, data: data, response: response)
    }

    func remoteJobs() async throws -> [RemoteJob] {
        let request = try remoteRequest(path: "api/remote/jobs")
        let (data, response) = try await URLSession.shared.data(for: request)
        return try remoteDecode([RemoteJob].self, data: data, response: response)
    }

    func remoteJob(id: String) async throws -> RemoteJob {
        let request = try remoteRequest(path: "api/remote/jobs/\(id)")
        let (data, response) = try await URLSession.shared.data(for: request)
        return try remoteDecode(RemoteJob.self, data: data, response: response)
    }

    func retryRemoteJob(id: String) async throws {
        let request = try remoteRequest(path: "api/remote/jobs/\(id)/retry", method: "POST")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateRemoteResponse(data: data, response: response)
    }

    func deleteAudiobook(id: String) async throws {
        let request = try remoteRequest(path: "api/audiobooks/\(id)", method: "DELETE")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateRemoteResponse(data: data, response: response)
    }

    private func remoteRequest(path: String, method: String = "GET") throws -> URLRequest {
        guard let token = RemoteTokenStore.load(), !token.isEmpty else { throw RemoteAPIError.missingToken }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        return request
    }

    private func remoteDecode<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        try validateRemoteResponse(data: data, response: response)
        return try JSONDecoder().decode(type, from: data)
    }

    private func validateRemoteResponse(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RemoteAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw RemoteAPIError.server("Remote token was rejected. Update it in Settings.") }
            let detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = detail?["detail"] as? String ?? "Server error \(http.statusCode). Please try again."
            throw RemoteAPIError.server(message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func resolve(_ value: String) -> URL {
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return baseURL.appending(path: trimmed)
    }
}
