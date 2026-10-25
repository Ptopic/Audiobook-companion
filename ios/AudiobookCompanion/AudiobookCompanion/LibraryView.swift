import Foundation
import SwiftUI
import UIKit

/// Exact values from design/home-prototype/index.html. Scoped here so other
/// screens keep their own prototype tokens (the prototypes differ slightly).
private enum HomeDesign {
    static let ink = Color(hex: "F1EEE9")
    static let author = Color(hex: "B8B1A9")
    static let count = Color(hex: "AAA8A4")
    static let duration = Color(hex: "B4AAA1")
    static let serverText = Color(hex: "E0E0DD")
    static let serverDot = Color(hex: "70D18D")
    static let refreshIcon = Color(hex: "E8E9E8")
    static let amber = Color(hex: "F2B65F")
    static let playIcon = Color(hex: "FFC275")
    static let progressTrack = Color(hex: "535250")
    static let tabInactive = Color(hex: "B0B1AF")

    static let titleFont = Font.custom("TimesNewRomanPSMT", size: 29.3)

    static func avenir(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .medium ? "AvenirNext-Medium" : "AvenirNext-Regular", size: size)
    }
}

struct LibraryView: View {
    private enum MainTab { case library, create, settings }
    private static let defaultServerURL = "https://books.petartopic.com/"
    private static let localServerURLs = [
        "http://127.0.0.1:8765/",
        "http://127.0.0.1:8876/",
        "http://localhost:8765/",
        "http://localhost:8876/",
    ]

    @ObservedObject var player: PlayerModel
    @AppStorage("serverURL") private var serverURL = Self.defaultServerURL
    @State private var books: [AudiobookSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var navigationPath: [AudiobookSummary] = []
    @State private var selectedTab = MainTab.library
    @State private var tokenDraft = ""
    @State private var tokenConfigured = false
    @State private var tokenError: String?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                ZStack {
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(hex: "141715"), location: 0),
                            .init(color: Color(hex: "111412"), location: 0.61),
                            .init(color: Color(hex: "111413"), location: 1),
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(hex: "232522").opacity(0.42), location: 0),
                            .init(color: Color(hex: "232522").opacity(0), location: 0.38),
                        ]),
                        startPoint: UnitPoint(x: 0.35, y: 0),
                        endPoint: UnitPoint(x: 0.55, y: 1)
                    )
                }
                .ignoresSafeArea()

                if selectedTab == .create {
                    CreateBookView(api: api)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 21) {
                            if selectedTab == .library {
                                header
                                libraryContent
                            } else if selectedTab == .settings {
                                settingsContent
                            }
                        }
                        .padding(.horizontal, 17)
                        .padding(.bottom, AppTheme.Spacing.xxl)
                    }
                    .scrollIndicators(.hidden)
                    .safeAreaPadding(.top, 23)
                    .safeAreaPadding(.bottom, 76)
                }
            }
            .overlay(alignment: .bottom) { bottomBar }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AudiobookSummary.self) { summary in
                BookDetailView(
                    summary: summary,
                    api: api,
                    player: player,
                    onDeleted: { deletedID in
                        books.removeAll { $0.id == deletedID }
                        navigationPath.removeAll { $0.id == deletedID }
                    },
                    onClose: {
                        navigationPath.removeAll { $0.id == summary.id }
                    }
                )
            }
            .task {
                migrateLocalServerURL()
                tokenConfigured = RemoteTokenStore.load() != nil
                await load()
            }
            .refreshable {
                await load()
            }
        }
        .tint(AppTheme.accent)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.xSmall ... .large)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 33) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Audiobook Companion")
                        .font(HomeDesign.titleFont)
                        .foregroundStyle(HomeDesign.ink)
                        .lineLimit(1)
                        .frame(height: 34, alignment: .leading)

                    Button {
                        selectedTab = .settings
                    } label: {
                        ServerStatusChip(host: serverHost)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 8)

                Button {
                    Task { await load() }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(hex: "272827"))
                            .frame(width: 47, height: 47)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(HomeDesign.refreshIcon)
                            .rotationEffect(.degrees(isLoading ? 180 : 0))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.11), lineWidth: 1)
                    }
                }
                .padding(.trailing, 7)
                .accessibilityLabel("Reload library")
                .disabled(isLoading)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Your Library")
                    .font(HomeDesign.avenir(20))
                    .foregroundStyle(HomeDesign.ink)

                Spacer()

                Text("\(books.count) \(books.count == 1 ? "audiobook" : "audiobooks")")
                    .font(HomeDesign.avenir(13))
                    .foregroundStyle(HomeDesign.count)
                    .padding(.trailing, 9)
            }
        }
        .padding(.leading, 4)
    }

    private var serverEditor: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Text("Server")
                .font(AppTheme.Fonts.captionMedium)
                .foregroundStyle(AppTheme.textSecondary)

            HStack(spacing: AppTheme.Spacing.s) {
                TextField("Server URL", text: $serverURL)
                    .font(AppTheme.Fonts.bodySmall)
                    .foregroundStyle(AppTheme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit {
                        Task { await load() }
                    }

                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .accessibilityLabel("Load server")
            }
        }
        .padding(AppTheme.Spacing.m)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Settings")
                .font(HomeDesign.titleFont)
                .foregroundStyle(HomeDesign.ink)
            serverEditor
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("Remote access token")
                        .font(AppTheme.Fonts.subheading)
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    if tokenConfigured {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(AppTheme.Fonts.bodySmall)
                            .foregroundStyle(AppTheme.success)
                    }
                }
                SecureField(tokenConfigured ? "Enter a new token to replace" : "Paste access token", text: $tokenDraft)
                    .font(AppTheme.Fonts.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .padding(12)
                    .background(AppTheme.buttonSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button("Save token") {
                    do {
                        try RemoteTokenStore.save(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                        tokenDraft = ""
                        tokenConfigured = true
                        tokenError = nil
                    } catch {
                        tokenError = error.localizedDescription
                    }
                }
                .font(AppTheme.Fonts.subheading)
                .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                if let tokenError { ErrorBanner(message: tokenError) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 4)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            bottomBarItem("Library", icon: .library, selected: selectedTab == .library) {
                selectedTab = .library
                navigationPath.removeAll()
                Task { await load() }
            }
            bottomBarItem("Create", icon: .create, selected: selectedTab == .create) {
                selectedTab = .create
            }
            bottomBarItem("Now Playing", icon: .nowPlaying, selected: false) {
                if let book = nowPlayingTarget {
                    selectedTab = .library
                    navigationPath = [book]
                }
            }
            bottomBarItem("Settings", icon: .settings, selected: selectedTab == .settings) {
                selectedTab = .settings
                tokenConfigured = RemoteTokenStore.load() != nil
            }
        }
        .frame(height: 67)
        .frame(maxWidth: .infinity)
        .background(Color(hex: "111413").opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.13)).frame(height: 1)
        }
    }

    private func bottomBarItem(
        _ title: String,
        icon: TabIconKind,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                TabIcon(kind: icon)
                Text(title)
                    .font(HomeDesign.avenir(11))
            }
            .foregroundStyle(selected ? HomeDesign.amber : HomeDesign.tabInactive)
            .frame(maxWidth: .infinity)
            .frame(height: 67)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var libraryContent: some View {
        if isLoading && books.isEmpty {
            LoadingCard(message: "Loading your library")
        } else if books.isEmpty {
            EmptyLibraryCard {
                Task { await load() }
            }
        } else {
            VStack(spacing: 13) {
                ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                    NavigationLink(value: book) {
                        AudiobookLibraryCard(
                            book: book,
                            paletteIndex: index,
                            coverURL: api.assetURL(book.coverURL)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if let errorMessage {
            ErrorBanner(message: errorMessage)
        }
    }

    private var api: AudiobookAPI {
        AudiobookAPI(baseURL: URL(string: serverURL) ?? URL(string: Self.defaultServerURL)!)
    }

    private var serverHost: String {
        URL(string: serverURL)?.host() ?? serverURL
    }

    private func migrateLocalServerURL() {
        guard Self.localServerURLs.contains(serverURL) else { return }
        serverURL = Self.defaultServerURL
    }

    private var nowPlayingTarget: AudiobookSummary? {
        if let activeBookID = player.activeBookID,
           let book = books.first(where: { $0.bookID == activeBookID || $0.id == activeBookID }) {
            return book
        }
        if let saved = PlaybackStateStore.load(),
           let book = books.first(where: { $0.bookID == saved.bookID || $0.id == saved.bookID }) {
            return book
        }
        return books.first
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            books = try await api.catalog()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct ServerStatusChip: View {
    let host: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(HomeDesign.serverDot)
                .frame(width: 9, height: 9)

            Text(host)
                .font(HomeDesign.avenir(14))
                .foregroundStyle(HomeDesign.serverText)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(
            LinearGradient(
                colors: [Color(hex: "242625"), Color(hex: "1E211F")],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.075), lineWidth: 1)
        }
    }
}

private struct AudiobookLibraryCard: View {
    let book: AudiobookSummary
    let paletteIndex: Int
    let coverURL: URL?
    @State private var savedPlayback: PlaybackStateStore.State?

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            BookCover(
                title: book.title,
                size: CGSize(width: 124, height: paletteIndex == 0 ? 161 : 163),
                paletteIndex: paletteIndex,
                artworkURL: coverURL
            )

            VStack(alignment: .leading, spacing: 0) {
                Text(book.title)
                    .font(HomeDesign.avenir(16.3))
                    .foregroundStyle(HomeDesign.ink)
                    .lineLimit(1)
                    .frame(height: 20, alignment: .leading)

                Text(book.author ?? "Author unavailable")
                    .font(HomeDesign.avenir(13.5))
                    .foregroundStyle(HomeDesign.author)
                    .lineLimit(1)
                    .frame(height: 15, alignment: .leading)
                    .padding(.top, 9)

                ProgressView(value: playbackProgress)
                    .tint(HomeDesign.amber)
                    .frame(height: 5)
                    .background(HomeDesign.progressTrack)
                    .clipShape(Capsule())
                    .padding(.top, 31)

                HStack {
                    Text(progressLabel)
                    Spacer()
                    Text("\(Int((playbackProgress * 100).rounded()))%")
                }
                .font(HomeDesign.avenir(12))
                .foregroundStyle(HomeDesign.duration)
                .frame(height: 15, alignment: .leading)
                .padding(.top, 10)
            }
            .padding(.top, 17)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 11)
        .padding(.horizontal, 13)
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, minHeight: paletteIndex == 0 ? 185 : 189, alignment: .leading)
        .background(
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(hex: "342D28"), location: 0),
                    .init(color: Color(hex: "2C2A27"), location: 0.43),
                    .init(color: Color(hex: "252624"), location: 1),
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.045), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.11), radius: 9.5, x: 0, y: 7)
        .overlay(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.025), lineWidth: 3)
                    .frame(width: 54, height: 54)
                Circle()
                    .fill(Color(hex: "151615"))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Circle().stroke(Color.white.opacity(0.24), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 9.5, x: 0, y: 9)
                Image(systemName: "play.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(HomeDesign.playIcon)
                    .offset(x: 1)
            }
            .accessibilityHidden(true)
            .padding(.top, 20)
            .padding(.trailing, 17)
        }
        .onAppear(perform: refreshPlayback)
        .onReceive(NotificationCenter.default.publisher(for: PlaybackStateStore.didChange)) { notification in
            guard let changedBookID = notification.userInfo?[PlaybackStateStore.changedBookIDKey] as? String,
                  changedBookID == book.bookID || changedBookID == book.id else { return }
            refreshPlayback()
        }
    }

    private var playbackProgress: Double {
        guard totalDuration > 0 else { return 0 }
        return min(max(elapsedDuration / totalDuration, 0), 1)
    }

    private var progressLabel: String {
        "\(durationLabel(elapsedDuration)) of \(durationLabel(totalDuration))"
    }

    private var totalDuration: TimeInterval {
        if let chapters = book.chapters, !chapters.isEmpty {
            return chapters.reduce(0) { $0 + max($1.duration, 0) }
        }
        return max(book.duration ?? 0, 0)
    }

    private var elapsedDuration: TimeInterval {
        guard let saved = savedPlayback, let chapters = book.chapters else { return 0 }
        var elapsed: TimeInterval = 0
        for chapter in chapters {
            if chapter.id == saved.chapterID {
                return elapsed + min(max(saved.position, 0), max(chapter.duration, 0))
            }
            elapsed += max(chapter.duration, 0)
        }
        return 0
    }

    private func refreshPlayback() {
        savedPlayback = PlaybackStateStore.state(for: book.bookID) ?? PlaybackStateStore.state(for: book.id)
    }

    private func durationLabel(_ value: TimeInterval) -> String {
        let minutes = max(0, Int(value) / 60)
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 { return "\(hours)h \(remainder)m" }
        return "\(remainder)m"
    }
}

struct BookCover: View {
    let title: String
    let size: CGSize
    var paletteIndex = 0
    var artworkName: String? = nil
    var artworkURL: URL? = nil
    var cornerRadius: CGFloat? = nil

    private var resolvedCornerRadius: CGFloat {
        cornerRadius ?? (artworkName == nil && artworkURL == nil ? AppTheme.Radius.m : 6)
    }

    var body: some View {
        ZStack {
            if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        fallbackCover
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
            } else if let artworkName,
               let url = Bundle.main.url(forResource: artworkName, withExtension: "png"),
               let artwork = UIImage(contentsOfFile: url.path) {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                fallbackCover
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 5, x: 0, y: 5)
    }

    private var fallbackCover: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "waveform")
                .font(.system(size: max(18, size.width * 0.22), weight: .light))
                .foregroundStyle(.white.opacity(0.32))
            VStack(spacing: AppTheme.Spacing.s) {
                Text(title)
                    .font(.system(size: max(12, size.width * 0.14), weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.64)
                Rectangle().fill(.white.opacity(0.45)).frame(width: size.width * 0.28, height: 1)
                Text("AUDIOBOOK")
                    .font(.system(size: max(7, size.width * 0.07), weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(AppTheme.Spacing.s)
        }
    }

    private var palette: [Color] {
        let options: [[Color]] = [
            [Color(hex: "153238"), Color(hex: "0B1518"), Color(hex: "D59A50")],
            [Color(hex: "2D251B"), Color(hex: "101211"), Color(hex: "C77C4B")],
            [Color(hex: "182E2A"), Color(hex: "0C1110"), Color(hex: "9A6B45")],
            [Color(hex: "243141"), Color(hex: "0F1216"), Color(hex: "C7A05A")],
        ]
        return options[abs(paletteIndex) % options.count]
    }
}

struct LoadingCard: View {
    let message: String

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            ProgressView()
                .tint(AppTheme.accent)
            Text(message)
                .font(AppTheme.Fonts.bodySmall)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.l, style: .continuous))
    }
}

private struct EmptyLibraryCard: View {
    let onReload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Image(systemName: "headphones")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(AppTheme.accent)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("No audiobooks yet")
                    .font(AppTheme.Fonts.subheading)
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Generate a book on the server, then refresh this library.")
                    .font(AppTheme.Fonts.bodySmall)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onReload) {
                Label("Reload Library", systemImage: "arrow.clockwise")
                    .font(AppTheme.Fonts.captionMedium)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.l, style: .continuous))
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.error)
            Text(message)
                .font(AppTheme.Fonts.caption)
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.error.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous))
    }
}

enum TabIconKind {
    case library
    case create
    case nowPlaying
    case settings
}

/// Tab bar icons matching the SVGs in design/home-prototype/index.html.
/// Geometry lives in the 24x24 viewBox space; holes use the even-odd rule.
private struct TabIcon: View {
    let kind: TabIconKind

    var body: some View {
        Group {
            if kind == .create {
                Image(systemName: "plus.square")
                    .font(.system(size: 22, weight: .regular))
            } else {
                shape
                    .fill(style: FillStyle(eoFill: true))
            }
        }
        .frame(width: 22, height: 22)
    }

    private var shape: AnyShape {
        switch kind {
        case .library: AnyShape(TabLibraryIconShape())
        case .create: AnyShape(Rectangle())
        case .nowPlaying: AnyShape(TabNowPlayingIconShape())
        case .settings: AnyShape(TabSettingsIconShape())
        }
    }
}

private func tabIconTransform(_ rect: CGRect) -> CGAffineTransform {
    CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
}

private struct TabLibraryIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 5, y: 2, width: 6, height: 20),
                         cornerSize: CGSize(width: 2, height: 2))
        p.addRoundedRect(in: CGRect(x: 13, y: 2, width: 7, height: 20),
                         cornerSize: CGSize(width: 2, height: 2))
        p.addRoundedRect(in: CGRect(x: 16, y: 9, width: 2, height: 4),
                         cornerSize: CGSize(width: 1, height: 1))
        return p.applying(tabIconTransform(rect))
    }
}

private struct TabNowPlayingIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: 1, y: 1, width: 22, height: 22))
        p.move(to: CGPoint(x: 10, y: 7))
        p.addLine(to: CGPoint(x: 17, y: 12))
        p.addLine(to: CGPoint(x: 10, y: 17))
        p.closeSubpath()
        return p.applying(tabIconTransform(rect))
    }
}

private struct TabSettingsIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [CGPoint] = [
            CGPoint(x: 9.448, y: 1.76),
            CGPoint(x: 12.792, y: 1.76),
            CGPoint(x: 13.324, y: 3.736),
            CGPoint(x: 15.072, y: 4.496),
            CGPoint(x: 16.896, y: 3.508),
            CGPoint(x: 19.252, y: 5.864),
            CGPoint(x: 18.264, y: 7.688),
            CGPoint(x: 19.024, y: 9.436),
            CGPoint(x: 21.0, y: 10.12),
            CGPoint(x: 21.0, y: 13.464),
            CGPoint(x: 19.024, y: 13.996),
            CGPoint(x: 18.264, y: 15.744),
            CGPoint(x: 19.252, y: 17.568),
            CGPoint(x: 16.896, y: 19.924),
            CGPoint(x: 15.072, y: 18.936),
            CGPoint(x: 13.324, y: 19.696),
            CGPoint(x: 12.792, y: 21.52),
            CGPoint(x: 9.448, y: 21.52),
            CGPoint(x: 8.916, y: 19.544),
            CGPoint(x: 7.168, y: 18.784),
            CGPoint(x: 5.344, y: 19.772),
            CGPoint(x: 2.988, y: 17.416),
            CGPoint(x: 3.976, y: 15.592),
            CGPoint(x: 3.216, y: 13.844),
            CGPoint(x: 1.24, y: 13.464),
            CGPoint(x: 1.24, y: 10.12),
            CGPoint(x: 3.216, y: 9.588),
            CGPoint(x: 3.976, y: 7.84),
            CGPoint(x: 2.988, y: 6.016),
            CGPoint(x: 5.344, y: 3.66),
            CGPoint(x: 7.168, y: 4.648),
            CGPoint(x: 8.916, y: 3.888),
        ]
        var p = Path()
        p.move(to: points[0])
        p.addLines(points)
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: 6.408, y: 7.08, width: 9.424, height: 9.424))
        return p.applying(tabIconTransform(rect))
    }
}

enum AppTheme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 14
        static let l: CGFloat = 22
        static let xl: CGFloat = 28
    }

    enum Fonts {
        static let display = Font.system(size: 23, weight: .semibold, design: .serif)
        static let displaySmall = Font.system(size: 21, weight: .semibold, design: .serif)
        static let heading = Font.system(size: 17, weight: .semibold)
        static let subheading = Font.system(size: 14, weight: .semibold)
        static let body = Font.system(size: 13, weight: .regular)
        static let bodySmall = Font.system(size: 12, weight: .regular)
        static let caption = Font.system(size: 10, weight: .regular)
        static let captionMedium = Font.system(size: 10, weight: .medium)
    }

    static let accent = Color(hex: "F1B45E")
    static let accentDeep = Color(hex: "B56A37")
    static let success = Color(hex: "73D390")
    static let error = Color(hex: "FF6B5C")

    static let textPrimary = Color(light: "F7F0E7", dark: "F7F0E7")
    static let textSecondary = Color(light: "B7AEA3", dark: "B7AEA3")
    static let textTertiary = Color(light: "7F756B", dark: "7F756B")
    static let surface = Color(light: "242422", dark: "242422").opacity(0.86)
    static let surfaceElevated = Color(light: "302C28", dark: "302C28").opacity(0.95)
    static let border = Color.white.opacity(0.08)
    static let track = Color.white.opacity(0.12)
    static let buttonSurface = Color(light: "171512", dark: "171512")

    static let backgroundGradient = LinearGradient(
        colors: [Color(hex: "151815"), Color(hex: "111312"), Color(hex: "241A12")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardGradient = LinearGradient(
        colors: [Color.white.opacity(0.12), Color.white.opacity(0.055)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    init(light lightHex: String, dark darkHex: String) {
        self.init(uiColor: UIColor(
            light: UIColor(Color(hex: lightHex)),
            dark: UIColor(Color(hex: darkHex))
        ))
    }
}

extension UIColor {
    convenience init(light: UIColor, dark: UIColor) {
        self.init { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        }
    }
}

struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView(player: PlayerModel())
    }
}
