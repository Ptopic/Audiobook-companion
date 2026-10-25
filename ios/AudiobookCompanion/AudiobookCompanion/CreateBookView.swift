import SwiftUI
import UniformTypeIdentifiers

struct CreateBookView: View {
    let api: AudiobookAPI

    @State private var book: RemoteBook?
    @State private var selectedChapters: Set<String> = []
    @State private var jobs: [RemoteJob] = []
    @State private var voice = "af_heart"
    @State private var speed = 1.0
    @State private var showsImporter = false
    @State private var isUploading = false
    @State private var isSubmitting = false
    @State private var retryingJobs: Set<String> = []
    @State private var hasToken = false
    @State private var errorMessage: String?
    @State private var jobsError: String?
    @State private var successMessage: String?

    private let voices = ["af_heart", "af_bella", "af_nicole", "af_sarah", "am_adam", "am_michael", "bf_emma", "bm_george"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Create Audiobook")
                        .font(.custom("TimesNewRomanPSMT", size: 29))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Button { Task { await refreshJobs() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Refresh jobs")
                }

                uploadSection

                if let book {
                    chapterSection(book)
                    narrationSection
                }

                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }
                if let jobsError {
                    ErrorBanner(message: jobsError)
                }
                if let successMessage {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .font(AppTheme.Fonts.bodySmall)
                        .foregroundStyle(AppTheme.success)
                }

                jobsSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 23)
            .padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data]
        ) { result in
            switch result {
            case .success(let url):
                Task { await upload(url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .task {
            hasToken = RemoteTokenStore.load() != nil
            guard hasToken else { return }
            while !Task.isCancelled {
                await refreshJobs()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onAppear { hasToken = RemoteTokenStore.load() != nil }
    }

    private var uploadSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("EPUB")
            if !hasToken {
                Text("Add your remote access token in Settings to upload an EPUB.")
                    .font(AppTheme.Fonts.body)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Button { showsImporter = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isUploading ? "Uploading EPUB…" : "Choose EPUB from Files")
                            .font(AppTheme.Fonts.subheading)
                        Text("Select a book on your iPhone or in iCloud Drive")
                            .font(AppTheme.Fonts.bodySmall)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if isUploading { ProgressView().tint(AppTheme.accent) }
                    else { Image(systemName: "chevron.right").font(.system(size: 13)) }
                }
                .foregroundStyle(AppTheme.textPrimary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(AppTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(isUploading || isSubmitting)
        }
    }

    private func chapterSection(_ book: RemoteBook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("CHAPTERS")
            Text(book.title)
                .font(.custom("TimesNewRomanPSMT", size: 22))
                .foregroundStyle(AppTheme.textPrimary)
            if let author = book.author {
                Text(author).font(AppTheme.Fonts.body).foregroundStyle(AppTheme.textSecondary)
            }
            Text("\(selectedChapters.count) of \(book.chapters.count) selected")
                .font(AppTheme.Fonts.bodySmall)
                .foregroundStyle(AppTheme.textSecondary)

            LazyVStack(spacing: 1) {
                ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button { toggle(chapter.id) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selectedChapters.contains(chapter.id) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 21))
                                .foregroundStyle(selectedChapters.contains(chapter.id) ? AppTheme.accent : AppTheme.textSecondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(chapter.title)
                                    .font(AppTheme.Fonts.subheading)
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .multilineTextAlignment(.leading)
                                HStack {
                                    Text("\(index + 1) of \(book.chapters.count)")
                                    if let count = chapter.wordCount { Text("· \(count) words") }
                                }
                                .font(AppTheme.Fonts.bodySmall)
                                .foregroundStyle(AppTheme.textSecondary)
                                if let preview = chapter.preview, !preview.isEmpty {
                                    Text(preview)
                                        .font(AppTheme.Fonts.bodySmall)
                                        .foregroundStyle(AppTheme.textTertiary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(chapter.title), \(selectedChapters.contains(chapter.id) ? "selected" : "not selected")")
                    if index < book.chapters.count - 1 {
                        Divider().overlay(AppTheme.border)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var narrationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("NARRATION")
            Picker("Voice", selection: $voice) {
                ForEach(voices, id: \.self) { Text($0).tag($0) }
            }
            .tint(AppTheme.accent)
            .font(AppTheme.Fonts.body)

            HStack {
                Text("Speed")
                Spacer()
                Text(speed.formatted(.number.precision(.fractionLength(1))) + "×")
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.accent)
            }
            .font(AppTheme.Fonts.body)
            Slider(value: $speed, in: 0.5...2.0, step: 0.1)
                .tint(AppTheme.accent)

            Button { Task { await submit() } } label: {
                HStack {
                    if isSubmitting { ProgressView().tint(AppTheme.buttonSurface) }
                    else { Image(systemName: "waveform") }
                    Text(isSubmitting ? "Starting job…" : "Create audiobook")
                }
                .font(AppTheme.Fonts.subheading)
                .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .disabled(selectedChapters.isEmpty || isSubmitting || isUploading)
        }
        .foregroundStyle(AppTheme.textPrimary)
        .padding(16)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("JOBS")
            if jobs.isEmpty {
                Text("No jobs yet")
                    .font(AppTheme.Fonts.body)
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(job.title)
                                .font(AppTheme.Fonts.subheading)
                                .lineLimit(2)
                            Spacer()
                            Text(job.status.capitalized)
                                .font(AppTheme.Fonts.bodySmall)
                                .foregroundStyle(job.status == "done" ? AppTheme.success : AppTheme.accent)
                        }
                        .foregroundStyle(AppTheme.textPrimary)
                        ProgressView(value: job.progressFraction)
                            .tint(job.status == "failed" ? AppTheme.error : AppTheme.accent)
                        Text("\(Int((job.progressFraction * 100).rounded()))%")
                            .font(AppTheme.Fonts.bodySmall)
                            .foregroundStyle(AppTheme.textSecondary)
                        if let message = job.message, !message.isEmpty {
                            Text(message)
                                .font(AppTheme.Fonts.bodySmall)
                                .foregroundStyle(job.status == "failed" ? AppTheme.error : AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if job.status == "failed" {
                            Button {
                                Task { await retry(job) }
                            } label: {
                                if retryingJobs.contains(job.id) {
                                    ProgressView().tint(AppTheme.accent)
                                } else {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                }
                            }
                            .font(AppTheme.Fonts.bodySmall)
                            .buttonStyle(.bordered)
                            .tint(AppTheme.accent)
                            .disabled(retryingJobs.contains(job.id))
                            .accessibilityLabel("Retry \(job.title)")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.custom("AvenirNext-Medium", size: 11))
            .foregroundStyle(AppTheme.textSecondary)
    }

    private func toggle(_ id: String) {
        if selectedChapters.contains(id) { selectedChapters.remove(id) }
        else { selectedChapters.insert(id) }
    }

    private func upload(_ url: URL) async {
        guard url.pathExtension.lowercased() == "epub" else {
            errorMessage = "Choose an EPUB file."
            return
        }
        guard RemoteTokenStore.load()?.isEmpty == false else {
            hasToken = false
            errorMessage = RemoteAPIError.missingToken.localizedDescription
            return
        }
        isUploading = true
        errorMessage = nil
        successMessage = nil
        do {
            book = try await api.uploadEPUB(url)
            selectedChapters = []
        } catch {
            errorMessage = error.localizedDescription
        }
        isUploading = false
    }

    private func submit() async {
        guard let book else { return }
        isSubmitting = true
        errorMessage = nil
        successMessage = nil
        do {
            let chapterIDs = book.chapters.map(\.id).filter { selectedChapters.contains($0) }
            let created = try await api.createJob(bookID: book.id, chapters: chapterIDs, voice: voice, speed: speed)
            successMessage = "Job \(created.jobID) queued"
            await refreshJobs()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }

    private func refreshJobs() async {
        do {
            jobs = try await api.remoteJobs()
            jobsError = nil
        } catch {
            jobsError = error.localizedDescription
        }
    }

    private func retry(_ job: RemoteJob) async {
        retryingJobs.insert(job.id)
        errorMessage = nil
        successMessage = nil
        do {
            try await api.retryRemoteJob(id: job.id)
            successMessage = "Job queued for retry"
            await refreshJobs()
        } catch {
            errorMessage = error.localizedDescription
        }
        retryingJobs.remove(job.id)
    }
}
