import Foundation

struct AudiobookSummary: Identifiable, Decodable, Hashable {
    let id: String
    let bookID: String
    let title: String
    let author: String?
    let coverURL: String?
    let duration: TimeInterval?
    let chapters: [AudiobookChapterSummary]?
    let manifestURL: String
    let packageURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case bookID = "book_id"
        case title
        case author
        case coverURL = "cover_url"
        case duration
        case chapters
        case manifestURL = "manifest_url"
        case packageURL = "package_url"
    }
}

struct AudiobookChapterSummary: Decodable, Hashable {
    let id: String
    let duration: TimeInterval
}

struct AudiobookManifest: Identifiable, Decodable, Hashable {
    let schema: String
    let id: String
    let jobID: String
    let title: String
    let author: String?
    let coverURL: String?
    let chapters: [AudiobookChapter]

    enum CodingKeys: String, CodingKey {
        case schema
        case id
        case jobID = "job_id"
        case title
        case author
        case coverURL = "cover_url"
        case chapters
    }
}

struct AudiobookChapter: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let duration: TimeInterval
    let audioFile: String
    let audioURL: String?
    let segments: [AudiobookSegment]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case duration
        case audioFile = "audio_file"
        case audioURL = "audio_url"
        case segments
    }
}

struct AudiobookSegment: Identifiable, Decodable, Hashable {
    let id: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct RemoteBook: Identifiable, Decodable {
    let id: String
    let title: String
    let author: String?
    let chapters: [RemoteChapter]
}

struct RemoteChapter: Identifiable, Decodable {
    let id: String
    let title: String
    let preview: String?
    let wordCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, preview
        case wordCount = "word_count"
    }
}

struct RemoteJob: Identifiable, Decodable {
    let id: String
    let bookID: String
    let title: String
    let status: String
    let progress: Double
    let message: String?

    enum CodingKeys: String, CodingKey {
        case id, title, status, progress, message
        case bookID = "book_id"
    }

    var progressFraction: Double {
        min(max(progress > 1 ? progress / 100 : progress, 0), 1)
    }
}

struct RemoteJobCreated: Decodable {
    let jobID: String

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
    }
}
