import SwiftUI

/// Exact values from design/player-prototype/index.html.
private enum PlayerDesign {
    static let text = Color(hex: "F4F0EB")
    static let muted = Color(hex: "B9AFA5")
    static let amber = Color(hex: "F6BD6B")
    static let author = Color(hex: "C2B8AE")
    static let chapterSubtitle = Color(hex: "B5AAA0")
    static let times = Color(hex: "B7ADA4")
    static let smallLabels = Color(hex: "B6AAA0")
    static let chrome = Color(hex: "E9E9E8")
    static let seekTrack = Color(hex: "5B5955")
    static let thumb = Color(hex: "FFDB9D")
    static let thumbRing = Color(hex: "FFD798").opacity(0.13)
    static let pauseIcon = Color(hex: "17130D")
    static let jumpIcon = Color(hex: "F4F4F1")
    static let bookmarkIcon = Color(hex: "F4F1ED")
    static let segmentBackground = Color.white.opacity(0.045)
    static let segmentText = Color(hex: "C8C0B9")
    static let segmentSelectedText = Color(hex: "F7F3EE")
    static let actionText = Color(hex: "E7E2DD")
    static let moonIcon = Color(hex: "FFD084")

    static let titleFont = Font.custom("TimesNewRomanPSMT", size: 25)

    static func avenir(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .medium ? "AvenirNext-Medium" : "AvenirNext-Regular", size: size)
    }
}

struct BookDetailView: View {
    let summary: AudiobookSummary
    let api: AudiobookAPI
    @ObservedObject var player: PlayerModel
    var onDeleted: (String) -> Void = { _ in }
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var manifest: AudiobookManifest?
    @State private var selectedPanel = PlayerPanel.nowPlaying
    @State private var errorMessage: String?
    @State private var isDeleteConfirmationPresented = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var isDeleteErrorPresented = false
    @State private var seekBarBounds: CGRect = .null
    @State private var isReaderPresented = false

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.25), value: selectedPanel)

            if let manifest {
                GeometryReader { geo in
                    if selectedPanel == .nowPlaying {
                        VStack(spacing: 0) {
                            topBar
                                .padding(.top, 4)

                            PlayerNowPlaying(
                                title: manifest.title,
                                authorLine: manifest.author ?? summary.author ?? "Author unavailable",
                                coverURL: api.assetURL(manifest.coverURL ?? summary.coverURL),
                                chapter: activeOrFirstChapter(in: manifest),
                                chapterNumber: chapterNumber(in: manifest),
                                availableWidth: geo.size.width,
                                availableHeight: max(0, geo.size.height - 39),
                                paletteIndex: paletteIndex,
                                player: player,
                                onPlayPause: { togglePlayback(using: manifest) },
                                onSeek: { player.seek(to: $0, autoPlay: player.isPlaying) },
                                onJumpBackward: { player.jump(by: -15) },
                                onJumpForward: { player.jump(by: 15) },
                                onShowChapters: { withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { selectedPanel = .chapters } }
                            )
                            .simultaneousGesture(playerSwipeGesture)
                        }
                    } else {
                        TranscriptScreen(
                            title: manifest.title,
                            coverURL: api.assetURL(manifest.coverURL ?? summary.coverURL),
                            chapter: activeOrFirstChapter(in: manifest),
                            chapterNumber: chapterNumber(in: manifest),
                            chapters: manifest.chapters,
                            paletteIndex: paletteIndex,
                            player: player,
                            onTogglePlayback: { togglePlayback(using: manifest) },
                            onSeek: { player.seek(to: $0, autoPlay: player.isPlaying) },
                            onExpandPlayer: {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                    selectedPanel = .nowPlaying
                                }
                            },
                            onPlayChapter: { chapter in
                                play(chapter: chapter, segment: nil)
                            },
                            onSelectSegment: { segment in
                                if let chapter = activeOrFirstChapter(in: manifest) {
                                    play(chapter: chapter, segment: segment)
                                }
                            },
                            onOpenReader: { isReaderPresented = true },
                            onPanelSwipe: handlePlayerSwipe
                        )
                    }
                }
                .coordinateSpace(name: "playerContent")
                .onPreferenceChange(SeekBarBoundsPreferenceKey.self) { bounds in
                    seekBarBounds = bounds
                }
                .overlay(alignment: .leading) {
                    Color.clear
                        .frame(width: 24)
                        .contentShape(Rectangle())
                        .gesture(edgeBackGesture)
                        .padding(.top, selectedPanel == .nowPlaying ? 39 : 170)
                }
            } else {
                LoadingCard(message: "Loading audiobook")
                    .padding(AppTheme.Spacing.m)
            }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage {
                ErrorBanner(message: errorMessage)
                    .padding(.horizontal, AppTheme.Spacing.m)
                    .padding(.bottom, AppTheme.Spacing.s)
            }
        }
        .accessibilityHidden(isDeleteConfirmationPresented)
        .overlay {
            if isDeleteConfirmationPresented {
                deleteConfirmationOverlay
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Couldn’t delete audiobook", isPresented: $isDeleteErrorPresented) {
            Button("Try Again") { Task { await deleteAudiobook() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteError ?? "Please try again.")
        }
        .fullScreenCover(isPresented: $isReaderPresented) {
            if let manifest {
                ReaderView(
                    title: manifest.title,
                    bookID: summary.bookID,
                    chapters: manifest.chapters,
                    initialChapterID: activeOrFirstChapter(in: manifest)?.id,
                    api: api,
                    player: player,
                    onPlayChapter: { chapter in play(chapter: chapter, segment: nil) },
                    onPlaySegment: { chapter, segment in play(chapter: chapter, segment: segment) }
                )
            }
        }
        .task {
            await load()
        }
        .onDisappear {
            player.persistNow()
        }
        .onChange(of: player.playbackError) { _, error in
            if let error { errorMessage = error }
        }
        .tint(PlayerDesign.amber)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.xSmall ... .large)
    }

    @ViewBuilder
    private var background: some View {
        if selectedPanel == .nowPlaying {
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(hex: "302217"), location: 0),
                    .init(color: Color(hex: "2A1D12"), location: 0.34),
                    .init(color: Color(hex: "21170F"), location: 0.61),
                    .init(color: Color(hex: "0B0D0B"), location: 1),
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(hex: "171A1B"), location: 0),
                    .init(color: Color(hex: "111314"), location: 0.23),
                    .init(color: Color(hex: "0B0D0E"), location: 0.43),
                    .init(color: Color(hex: "131617"), location: 1),
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                closePlayer()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(PlayerDesign.chrome)
                    .frame(width: 35, height: 35)
                    .contentShape(Rectangle())
            }
            .padding(.leading, 18)
            .accessibilityLabel("Close player")

            Spacer(minLength: 0)

            PlayerSegmentedControl(selection: $selectedPanel)

            Spacer(minLength: 0)

            Menu {
                Button("Read Book", systemImage: "book") {
                    isReaderPresented = true
                }
                Button("Delete Audiobook", systemImage: "trash", role: .destructive) {
                    isDeleteConfirmationPresented = true
                }
            } label: {
                Group {
                    if isDeleting {
                        ProgressView()
                            .tint(PlayerDesign.chrome)
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(PlayerDesign.chrome)
                    }
                }
                .frame(width: 35, height: 35)
                .contentShape(Rectangle())
            }
            .padding(.trailing, 16)
            .accessibilityLabel("More options")
            .disabled(isDeleting)
        }
    }

    private var paletteIndex: Int {
        summary.title.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    }

    private var playerSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30, coordinateSpace: .named("playerContent"))
            .onEnded(handlePlayerSwipe)
    }

    private var edgeBackGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard !isDeleteConfirmationPresented else { return }
                guard value.translation.width >= 70,
                      value.translation.width > abs(value.translation.height) * 1.5 else { return }
                closePlayer()
            }
    }

    private func handlePlayerSwipe(_ value: DragGesture.Value) {
        guard !isDeleteConfirmationPresented else { return }
        guard !seekBarBounds.contains(value.startLocation) else { return }
        let horizontal = value.translation.width
        let vertical = value.translation.height
        guard abs(horizontal) >= 70,
              abs(horizontal) > abs(vertical) * 1.5 else { return }

        if horizontal > 0 && value.startLocation.x <= 24 {
            closePlayer()
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            selectedPanel = horizontal < 0 ? .chapters : .nowPlaying
        }
    }

    private func closePlayer() {
        player.persistNow()
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var deleteConfirmationOverlay: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    Text("Delete audiobook?")
                        .font(PlayerDesign.avenir(20, .medium))
                        .foregroundStyle(PlayerDesign.text)
                        .accessibilityAddTraits(.isHeader)

                    Text("This removes \"\(summary.title)\" from your library and deletes its audio files from server storage. Your source EPUB will remain.")
                        .font(PlayerDesign.avenir(14))
                        .foregroundStyle(PlayerDesign.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)

                    HStack(spacing: 12) {
                        Button {
                            isDeleteConfirmationPresented = false
                        } label: {
                            Text("Cancel")
                                .foregroundStyle(Color(hex: "FF694F"))
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color.white.opacity(0.12), in: Capsule())
                        }

                        Button(role: .destructive) {
                            isDeleteConfirmationPresented = false
                            Task { await deleteAudiobook() }
                        } label: {
                            Text("Delete")
                                .foregroundStyle(Color(hex: "FF686B"))
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color.white.opacity(0.12), in: Capsule())
                        }
                    }
                    .font(PlayerDesign.avenir(15, .medium))
                    .buttonStyle(.plain)
                    .padding(.top, 24)
                }
                .padding(24)
                .frame(width: min(400, geometry.size.width - 80))
                .background(Color(hex: "302D2A").opacity(0.97), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                }
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            manifest = try await api.manifest(for: summary)
            restoreSavedPlayback()
            errorMessage = player.playbackError
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteAudiobook() async {
        guard !isDeleting else { return }
        isDeleting = true
        deleteError = nil
        do {
            try await api.deleteAudiobook(id: summary.id)
            if player.activeBookID == summary.bookID || player.activeBookID == summary.id {
                player.stop()
            }
            PlaybackStateStore.remove(for: summary.bookID)
            if summary.id != summary.bookID {
                PlaybackStateStore.remove(for: summary.id)
            }
            onDeleted(summary.id)
        } catch {
            deleteError = error.localizedDescription
            isDeleteErrorPresented = true
        }
        isDeleting = false
    }

    /// Resumes this book's saved playback position, whatever was played last.
    private func restoreSavedPlayback() {
        guard let manifest else { return }
        if player.activeBookID == summary.bookID || player.activeBookID == summary.id { return }
        player.stop()
        guard
              let saved = PlaybackStateStore.state(for: summary.bookID) ?? PlaybackStateStore.state(for: summary.id),
              let chapter = manifest.chapters.first(where: { $0.id == saved.chapterID }),
              let url = api.audioURL(for: chapter) else { return }
        player.load(chapter: chapter, audioURL: url, bookID: summary.bookID, initialPosition: saved.position,
                    title: manifest.title, author: manifest.author ?? summary.author,
                    coverURL: api.assetURL(manifest.coverURL ?? summary.coverURL))
        player.rate = saved.rate
    }

    private func activeOrFirstChapter(in manifest: AudiobookManifest) -> AudiobookChapter? {
        guard player.activeBookID == summary.bookID || player.activeBookID == summary.id,
              let activeID = player.activeChapter?.id else { return manifest.chapters.first }
        return manifest.chapters.first(where: { $0.id == activeID }) ?? manifest.chapters.first
    }

    private func chapterNumber(in manifest: AudiobookManifest) -> Int {
        guard let chapter = activeOrFirstChapter(in: manifest),
              let index = manifest.chapters.firstIndex(where: { $0.id == chapter.id }) else { return 1 }
        return index + 1
    }

    private func togglePlayback(using manifest: AudiobookManifest) {
        if (player.activeBookID != summary.bookID && player.activeBookID != summary.id) || player.activeChapter == nil,
           let first = manifest.chapters.first {
            play(chapter: first, segment: nil, autoStart: true)
            return
        }
        player.togglePlayback()
    }

    private func play(chapter: AudiobookChapter, segment: AudiobookSegment?, autoStart: Bool = true) {
        guard let url = api.audioURL(for: chapter) else {
            errorMessage = "Chapter has no playable audio URL."
            return
        }
        let shouldLoad = player.activeChapter?.id != chapter.id
        player.load(chapter: chapter, audioURL: url, bookID: summary.bookID,
                    title: manifest?.title ?? summary.title, author: manifest?.author ?? summary.author,
                    coverURL: api.assetURL(manifest?.coverURL ?? summary.coverURL))
        if let segment {
            player.seek(to: segment, autoPlay: true)
        } else if shouldLoad || autoStart {
            player.play()
        }
    }
}

private enum PlayerPanel: String, CaseIterable {
    case nowPlaying = "Now Playing"
    case chapters = "Chapters"
}

private struct PlayerSegmentedControl: View {
    @Binding var selection: PlayerPanel

    var body: some View {
        HStack(spacing: 0) {
            segment("Now Playing", panel: .nowPlaying)
            segment("Chapters", panel: .chapters)
        }
        .padding(2)
        .frame(width: 204, height: 35)
        .background(PlayerDesign.segmentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func segment(_ title: String, panel: PlayerPanel) -> some View {
        let selected = selection == panel
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                selection = panel
            }
        } label: {
            Text(title)
                .font(PlayerDesign.avenir(13))
                .foregroundStyle(selected ? PlayerDesign.segmentSelectedText : PlayerDesign.segmentText)
                .frame(width: selected ? 107 : nil)
                .frame(maxWidth: selected ? 107 : .infinity)
                .frame(height: 31)
                .background {
                    if selected {
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), Color.white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PlayerNowPlaying: View {
    let title: String
    let authorLine: String
    let coverURL: URL?
    let chapter: AudiobookChapter?
    let chapterNumber: Int
    let availableWidth: CGFloat
    let availableHeight: CGFloat
    let paletteIndex: Int
    @ObservedObject var player: PlayerModel
    let onPlayPause: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onJumpBackward: () -> Void
    let onJumpForward: () -> Void
    let onShowChapters: () -> Void

    private var duration: TimeInterval {
        max(chapter?.duration ?? 0, 0)
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(player.currentTime / duration, 0), 1)
    }

    private var coverSize: CGSize {
        // Fixed controls plus the vertical gaps at compact and regular heights.
        let fixedHeight: CGFloat = 341 + 95 * verticalSpacingScale
        let width = min(305, availableWidth - 48, max(0, availableHeight - fixedHeight) * 305 / 312)
        return CGSize(width: width, height: width * 312 / 305)
    }

    private var verticalSpacingScale: CGFloat {
        min(max((availableHeight - 620) / 120, 0), 1)
    }

    private func spacing(_ compact: CGFloat, _ regular: CGFloat) -> CGFloat {
        compact + (regular - compact) * verticalSpacingScale
    }

    var body: some View {
        VStack(spacing: 0) {
            BookCover(
                title: title,
                size: coverSize,
                paletteIndex: paletteIndex,
                artworkURL: coverURL,
                cornerRadius: 13
            )
            .allowsHitTesting(false)
            .padding(.top, spacing(8, 21))

            VStack(spacing: 0) {
                Text(title)
                    .font(PlayerDesign.titleFont)
                    .foregroundStyle(PlayerDesign.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(height: 34)
                Text(authorLine)
                    .font(PlayerDesign.avenir(14))
                    .foregroundStyle(PlayerDesign.author)
                    .frame(height: 21)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, spacing(8, 18))

            VStack(spacing: 0) {
                Text("Chapter \(chapterNumber)")
                    .font(PlayerDesign.avenir(16))
                    .foregroundStyle(PlayerDesign.text)
                    .frame(height: 23)
                if let subtitle = chapterSubtitle {
                    Text(subtitle)
                        .font(PlayerDesign.avenir(13))
                        .foregroundStyle(PlayerDesign.chapterSubtitle)
                        .frame(height: 19)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, spacing(6, 14))

            VStack(spacing: 7) {
                PlayerSeekBar(progress: progress) { fraction in
                    guard duration > 0 else { return }
                    onSeek(fraction * duration)
                }
                .frame(height: 18)
                .accessibilityLabel("Playback position")

                HStack {
                    Text(timeString(player.currentTime))
                    Spacer()
                    Text("\u{2212}" + timeString(max(duration - player.currentTime, 0)))
                }
                .font(PlayerDesign.avenir(12))
                .foregroundStyle(PlayerDesign.times)
                .frame(height: 18)
            }
            .padding(.top, spacing(10, 21))

            transport
                .frame(maxWidth: .infinity)
                .padding(.top, spacing(10, 22))

            actions
                .padding(.top, spacing(14, 39))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, spacing(8, 24))
        .contentShape(Rectangle())
    }

    private var chapterSubtitle: String? {
        guard let raw = chapter?.title else { return nil }
        var value = raw
        if let slash = value.lastIndex(of: "/") {
            value = String(value[value.index(after: slash)...])
        }
        if let dot = value.lastIndex(of: "."), dot > value.startIndex {
            value = String(value[..<dot])
        }
        guard !value.isEmpty else { return nil }
        let display = value.prefix(1).uppercased() + value.dropFirst()
        return display.caseInsensitiveCompare("Chapter \(chapterNumber)") == .orderedSame ? nil : display
    }

    private var transportSpacing: CGFloat {
        max(14, (availableWidth - 48 - 262) / 4)
    }

    private var transport: some View {
        HStack(alignment: .top, spacing: transportSpacing) {
            VStack(spacing: 7) {
                SpeedButton(rate: $player.rate)
                Text("Speed")
                    .font(PlayerDesign.avenir(11))
                    .foregroundStyle(PlayerDesign.smallLabels)
                    .frame(width: 46, height: 15)
            }
            .padding(.top, 22)

            Jump15Button(forward: false, action: onJumpBackward)
                .padding(.top, 14)

            Button(action: onPlayPause) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "FFD38C"), Color(hex: "F6B85E")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    if player.isPlaying {
                        PauseBarsShape()
                            .fill(PlayerDesign.pauseIcon)
                            .frame(width: 33, height: 33)
                    } else {
                        PlayTriangleShape()
                            .fill(PlayerDesign.pauseIcon)
                            .frame(width: 30, height: 30)
                            .offset(x: 1.5)
                    }
                }
                .frame(width: 78, height: 78)
                .shadow(color: Color(hex: "FFBD67").opacity(0.27), radius: 11.5)
                .shadow(color: .black.opacity(0.32), radius: 10, y: 10)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Jump15Button(forward: true, action: onJumpForward)
                .padding(.top, 14)

            VStack(spacing: 8) {
                BookmarkShape()
                    .stroke(PlayerDesign.bookmarkIcon, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                    .frame(width: 28, height: 35)
                Text("Bookmark")
                    .font(PlayerDesign.avenir(11))
                    .foregroundStyle(PlayerDesign.smallLabels)
                    .frame(width: 65, height: 15)
                    .fixedSize()
            }
            .frame(width: 46)
            .padding(.top, 21)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(action: onShowChapters) {
                HStack(spacing: 10) {
                    QueueIcon()
                        .fill(PlayerDesign.actionText)
                        .frame(width: 20, height: 20)
                    Text("Chapter Queue")
                        .font(PlayerDesign.avenir(15))
                }
                .frame(width: 190, height: 55)
            }

            Button {} label: {
                HStack(spacing: 12) {
                    MoonIcon()
                        .frame(width: 20, height: 20)
                    Text("Sleep Timer")
                        .font(PlayerDesign.avenir(14))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 55)
            }
            .accessibilityLabel("Sleep timer")
        }
        .buttonStyle(ActionPillStyle())
    }
}

private struct ActionPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(PlayerDesign.actionText)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.075), Color.white.opacity(0.035)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct PlayerSeekBar: View {
    let progress: Double
    var trackColor: Color = PlayerDesign.seekTrack
    var fillColor: Color = PlayerDesign.amber
    var showsThumb: Bool = true
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(trackColor)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fillColor)
                    .frame(width: max(6, width * fraction))
            }
            .frame(height: 6)
            .overlay(alignment: .leading) {
                if showsThumb {
                    Circle()
                        .fill(PlayerDesign.thumb)
                        .frame(width: 18, height: 18)
                        .shadow(color: PlayerDesign.thumbRing, radius: 2)
                        .shadow(color: .black.opacity(0.3), radius: 3.5, y: 3)
                        .offset(x: min(max(width * fraction, 9), width - 9) - 9)
                }
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrub(min(max(value.location.x / max(width, 1), 0), 1))
                    }
            )
            .position(x: width / 2, y: geo.size.height / 2)
        }
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: SeekBarBoundsPreferenceKey.self,
                    value: geo.frame(in: .named("playerContent"))
                )
            }
        }
    }
}

private struct SeekBarBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        guard !next.isNull else { return }
        value = value.isNull ? next : value.union(next)
    }
}

private struct SpeedButton: View {
    @Binding var rate: Float

    var body: some View {
        Menu {
            ForEach([Float(0.8), Float(1.0), Float(1.25), Float(1.5), Float(2.0)], id: \.self) { value in
                Button(label(for: value)) {
                    rate = value
                }
            }
        } label: {
            Text(label(for: rate))
                .font(PlayerDesign.avenir(13))
                .foregroundStyle(PlayerDesign.amber)
                .frame(width: 46, height: 38)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "2D251E"), Color(hex: "211E1A")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
        }
        .accessibilityLabel("Playback speed")
    }

    private func label(for value: Float) -> String {
        value == 1 ? "1.0x" : String(format: "%.2gx", value)
    }
}

/// The reference's arc-with-arrowhead "15" jump icons (48-unit viewBox space).
private struct Jump15Button: View {
    let forward: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                JumpArcShape(forward: forward)
                    .stroke(PlayerDesign.jumpIcon, style: StrokeStyle(lineWidth: 2.35, lineCap: .round))
                JumpArrowShape(forward: forward)
                    .fill(PlayerDesign.jumpIcon)
                Text("15")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(PlayerDesign.jumpIcon)
                    .position(x: forward ? 24.5 : 23.5, y: 26.5)
            }
            .frame(width: 46, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(forward ? "Forward 15 seconds" : "Back 15 seconds")
    }
}

private struct JumpArcShape: Shape {
    let forward: Bool

    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 48
        var p = Path()
        if forward {
            p.move(to: CGPoint(x: 31, y: 9))
            p.addCurve(to: CGPoint(x: 7, y: 26), control1: CGPoint(x: 19, y: 5), control2: CGPoint(x: 8, y: 14))
            p.addCurve(to: CGPoint(x: 25, y: 45), control1: CGPoint(x: 6, y: 37), control2: CGPoint(x: 14, y: 45))
            p.addCurve(to: CGPoint(x: 42, y: 30), control1: CGPoint(x: 34, y: 45), control2: CGPoint(x: 41, y: 39))
        } else {
            p.move(to: CGPoint(x: 17, y: 9))
            p.addCurve(to: CGPoint(x: 41, y: 26), control1: CGPoint(x: 29, y: 5), control2: CGPoint(x: 40, y: 14))
            p.addCurve(to: CGPoint(x: 23, y: 45), control1: CGPoint(x: 42, y: 37), control2: CGPoint(x: 34, y: 45))
            p.addCurve(to: CGPoint(x: 6, y: 30), control1: CGPoint(x: 14, y: 45), control2: CGPoint(x: 7, y: 39))
        }
        return p.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

private struct JumpArrowShape: Shape {
    let forward: Bool

    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 48
        var p = Path()
        p.move(to: forward ? CGPoint(x: 30, y: 5) : CGPoint(x: 18, y: 5))
        p.addLine(to: forward ? CGPoint(x: 37, y: 10) : CGPoint(x: 11, y: 10))
        p.addLine(to: forward ? CGPoint(x: 30, y: 14) : CGPoint(x: 18, y: 14))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

private struct PauseBarsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 32
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 8, y: 4, width: 5, height: 24), cornerSize: CGSize(width: 2, height: 2))
        p.addRoundedRect(in: CGRect(x: 19, y: 4, width: 5, height: 24), cornerSize: CGSize(width: 2, height: 2))
        return p.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

private struct PlayTriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 24
        var p = Path()
        p.move(to: CGPoint(x: 6, y: 3.7))
        p.addLine(to: CGPoint(x: 8.3, y: 2.4))
        p.addLine(to: CGPoint(x: 21.3, y: 10.7))
        p.addLine(to: CGPoint(x: 21.3, y: 13.3))
        p.addLine(to: CGPoint(x: 8.3, y: 21.6))
        p.addLine(to: CGPoint(x: 6, y: 20.3))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

private struct BookmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 24
        var p = Path()
        p.move(to: CGPoint(x: 5.5, y: 2.5))
        p.addLine(to: CGPoint(x: 18.5, y: 2.5))
        p.addArc(tangent1End: CGPoint(x: 20.5, y: 2.5), tangent2End: CGPoint(x: 20.5, y: 4.5), radius: 2)
        p.addLine(to: CGPoint(x: 20.5, y: 27))
        p.addLine(to: CGPoint(x: 12, y: 21))
        p.addLine(to: CGPoint(x: 3.5, y: 27))
        p.addLine(to: CGPoint(x: 3.5, y: 4.5))
        p.addArc(tangent1End: CGPoint(x: 3.5, y: 2.5), tangent2End: CGPoint(x: 5.5, y: 2.5), radius: 2)
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

private struct QueueIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 24
        var p = Path()
        for y in [6.0, 12.0, 18.0] {
            p.addEllipse(in: CGRect(x: 3 - 1.2, y: y - 1.2, width: 2.4, height: 2.4))
        }
        for y in [5.0, 11.0, 17.0] {
            p.addRoundedRect(in: CGRect(x: 8, y: y, width: 13, height: 2), cornerSize: CGSize(width: 1, height: 1))
        }
        return p.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

/// Crescent moon: prototype masks a r9 circle at (11,12) with a r8 circle at
/// (16,8). The cutter only partially overlaps, so this must be a real mask
/// (destinationOut), not an even-odd fill.
private struct MoonIcon: View {
    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / 24
            ZStack {
                Circle()
                    .fill(PlayerDesign.moonIcon)
                    .frame(width: 18 * scale, height: 18 * scale)
                    .offset(x: -1 * scale, y: 0)
                Circle()
                    .frame(width: 16 * scale, height: 16 * scale)
                    .offset(x: 4 * scale, y: -4 * scale)
                    .blendMode(.destinationOut)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .compositingGroup()
        }
    }
}

/// Exact values from design/transcript-prototype/index.html.
private enum TranscriptDesign {
    static let text = Color(hex: "EEEDEB")
    static let muted = Color(hex: "B3B1AF")
    static let amber = Color(hex: "FFC36D")
    static let activeText = Color(hex: "FFC16D")
    static let lineText = Color(hex: "E7E6E4")
    static let lineTime = Color(hex: "B5B4B2")
    static let chapterLine = Color(hex: "B7B7B7")
    static let times = Color(hex: "B4B2B0")
    static let collapse = Color(hex: "DEDEDE")
    static let pauseButtonIcon = Color(hex: "F5F5F4")
    static let tabInactive = Color(hex: "BFC0C1")
    static let tabActive = Color(hex: "F0EFED")
    static let activeBorder = Color(hex: "F8BC67")
    static let track = Color(hex: "555659")
    static let cardBorder = Color.white.opacity(0.075)

    static func avenir(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .medium ? "AvenirNext-Medium" : "AvenirNext-Regular", size: size)
    }
}

private enum TranscriptScreenTab: String, CaseIterable {
    case chapters = "Chapters"
    case transcript = "Transcript"
}

private struct TranscriptScreen: View {
    let title: String
    let coverURL: URL?
    let chapter: AudiobookChapter?
    let chapterNumber: Int
    let chapters: [AudiobookChapter]
    let paletteIndex: Int
    @ObservedObject var player: PlayerModel
    let onTogglePlayback: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onExpandPlayer: () -> Void
    let onPlayChapter: (AudiobookChapter) -> Void
    let onSelectSegment: (AudiobookSegment) -> Void
    let onOpenReader: () -> Void
    let onPanelSwipe: (DragGesture.Value) -> Void

    @State private var tab: TranscriptScreenTab = .transcript

    private var duration: TimeInterval {
        max(chapter?.duration ?? 0, 0)
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(player.currentTime / duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            miniPlayerCard
            tabsRow
            tabContent
                .simultaneousGesture(
                    DragGesture(minimumDistance: 30, coordinateSpace: .named("playerContent"))
                        .onEnded(onPanelSwipe)
                )
        }
    }

    private var miniPlayerCard: some View {
        ZStack(alignment: .topLeading) {
            BookCover(
                title: title,
                size: CGSize(width: 72, height: 86),
                paletteIndex: paletteIndex,
                artworkURL: coverURL,
                cornerRadius: 7
            )
            .allowsHitTesting(false)
            .padding(.leading, 14)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(TranscriptDesign.avenir(15.5))
                    .foregroundStyle(TranscriptDesign.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(height: 22)
                    .padding(.top, 18)

                Text("Chapter \(chapterNumber)")
                    .font(TranscriptDesign.avenir(12.5))
                    .foregroundStyle(TranscriptDesign.chapterLine)
                    .lineLimit(1)
                    .frame(height: 20)

                PlayerSeekBar(
                    progress: progress,
                    trackColor: TranscriptDesign.track,
                    fillColor: TranscriptDesign.amber,
                    showsThumb: false,
                    onScrub: { fraction in
                        guard duration > 0 else { return }
                        onSeek(fraction * duration)
                    }
                )
                .frame(height: 6)
                .padding(.top, 10)
                .accessibilityLabel("Playback progress")

                HStack {
                    Text(timeString(player.currentTime))
                    Spacer()
                    Text("\u{2212}" + timeString(max(duration - player.currentTime, 0)))
                }
                .font(TranscriptDesign.avenir(12))
                .foregroundStyle(TranscriptDesign.times)
                .frame(height: 17)
                .padding(.top, 11)
            }
            .padding(.leading, 99)
            .padding(.trailing, 17)
        }
        .frame(height: 115)
        .background(
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(hex: "292B2C"), location: 0),
                    .init(color: Color(hex: "222425"), location: 0.58),
                    .init(color: Color(hex: "27292A"), location: 1),
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(TranscriptDesign.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 10, y: 8)
        .overlay(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 11) {
                Button(action: onTogglePlayback) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.085))
                            .frame(width: 41, height: 41)
                        if player.isPlaying {
                            MiniPauseBarsShape()
                                .fill(TranscriptDesign.pauseButtonIcon)
                                .frame(width: 20, height: 22)
                        } else {
                            PlayTriangleShape()
                                .fill(TranscriptDesign.pauseButtonIcon)
                                .frame(width: 18, height: 18)
                                .offset(x: 1)
                        }
                    }
                    .padding(.top, 18)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button(action: onExpandPlayer) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(TranscriptDesign.collapse)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                        .padding(.top, 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand player")
            }
            .padding(.trailing, 10)
        }
        .padding(.leading, 14)
        .padding(.trailing, 3)
    }

    private var tabsRow: some View {
        HStack(spacing: 0) {
            tabLabel("Chapters", target: .chapters)
            tabLabel("Transcript", target: .transcript)
            Button(action: onOpenReader) {
                Label("Read", systemImage: "book")
                    .font(TranscriptDesign.avenir(14))
                    .foregroundStyle(TranscriptDesign.tabInactive)
                    .frame(maxWidth: .infinity)
                    .frame(height: 55)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Read original EPUB")
        }
        .frame(height: 55)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color(hex: "151718"), Color(hex: "191A1A"), Color(hex: "151718")],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.045)).frame(height: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                let third = geo.size.width / 3
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(TranscriptDesign.amber)
                    .frame(width: max(0, third - 19), height: 5)
                    .position(
                        x: tab == .transcript ? third * 1.5 : third * 0.5,
                        y: geo.size.height - 8.5
                    )
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.095)).frame(height: 1)
                .allowsHitTesting(false)
        }
    }

    private func tabLabel(_ label: String, target: TranscriptScreenTab) -> some View {
        let selected = tab == target
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                tab = target
            }
        } label: {
            Text(label)
                .font(TranscriptDesign.avenir(14))
                .foregroundStyle(selected ? TranscriptDesign.tabActive : TranscriptDesign.tabInactive)
                .frame(maxWidth: .infinity)
                .frame(height: 55)
                .offset(y: -2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabContent: some View {
        if tab == .transcript {
            transcriptList
        } else {
            ChaptersPanel(
                chapters: chapters,
                activeChapter: player.activeChapter,
                isPlaying: player.isPlaying,
                onPlay: onPlayChapter
            )
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    let segments = chapter?.segments ?? []
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        TranscriptLineRow(
                            segment: segment,
                            isActive: isActiveSegment(segment),
                            showsSeparator: index < segments.count - 1
                        ) {
                            onSelectSegment(segment)
                        }
                        .id(segment.id)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 7)
                .padding(.top, 2)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if let id = player.currentSegment?.id {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: player.activeChapter?.id) { _, _ in
                if let id = player.currentSegment?.id {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func isActiveSegment(_ segment: AudiobookSegment) -> Bool {
        guard let chapter else { return false }
        return player.activeChapter?.id == chapter.id && player.currentSegment?.id == segment.id
    }
}

private struct TranscriptLineRow: View {
    let segment: AudiobookSegment
    let isActive: Bool
    let showsSeparator: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 0) {
                Text(timeString(segment.start))
                    .font(TranscriptDesign.avenir(14))
                    .foregroundStyle(isActive ? TranscriptDesign.activeText : TranscriptDesign.lineTime)
                    .frame(width: 73, alignment: .leading)
                    .lineLimit(1)
                    .fixedSize()

                Text(segment.text)
                    .font(TranscriptDesign.avenir(15))
                    .foregroundStyle(isActive ? TranscriptDesign.activeText : TranscriptDesign.lineText)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: isActive ? 250 : 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.top, 13)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(activeBackground)
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(TranscriptDesign.activeBorder, lineWidth: 1)
                }
            }
            .shadow(color: isActive ? Color(hex: "FFB75A").opacity(0.20) : .clear, radius: 8)
            .shadow(color: isActive ? Color(hex: "F9AA43").opacity(0.18) : .clear, radius: 5)
            .overlay(alignment: .bottom) {
                if showsSeparator && !isActive {
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 1)
                        .padding(.leading, 13)
                        .padding(.trailing, 8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var activeBackground: some View {
        if isActive {
            ZStack {
                Color(hex: "5B3E24").opacity(0.52)
                RadialGradient(
                    colors: [Color(hex: "C27325").opacity(0.27), .clear],
                    center: UnitPoint(x: 0.15, y: 0.3),
                    startRadius: 0,
                    endRadius: 170
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct MiniPauseBarsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let transform = CGAffineTransform(
            scaleX: rect.width / 24,
            y: rect.height / 24
        )
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 5, y: 2, width: 5, height: 20), cornerSize: CGSize(width: 2, height: 2))
        p.addRoundedRect(in: CGRect(x: 14, y: 2, width: 5, height: 20), cornerSize: CGSize(width: 2, height: 2))
        return p.applying(transform)
    }
}

private struct ChaptersPanel: View {
    let chapters: [AudiobookChapter]
    let activeChapter: AudiobookChapter?
    var isPlaying: Bool = false
    let onPlay: (AudiobookChapter) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    let isActive = activeChapter?.id == chapter.id
                    Button {
                        onPlay(chapter)
                    } label: {
                        HStack(spacing: 14) {
                            Text(String(format: "%02d", index + 1))
                                .font(TranscriptDesign.avenir(12))
                                .foregroundStyle(TranscriptDesign.muted)
                                .frame(width: 28, alignment: .leading)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayTitle(chapter))
                                    .font(TranscriptDesign.avenir(14))
                                    .foregroundStyle(TranscriptDesign.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(timeString(chapter.duration))
                                    .font(TranscriptDesign.avenir(12))
                                    .foregroundStyle(TranscriptDesign.muted)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: isActive && isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 26, weight: .regular))
                                .foregroundStyle(TranscriptDesign.amber)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 58)
                        .background(isActive ? TranscriptDesign.amber.opacity(0.12) : Color.white.opacity(0.045))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            if isActive {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(TranscriptDesign.amber.opacity(0.45), lineWidth: 1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 17)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func displayTitle(_ chapter: AudiobookChapter) -> String {
        var value = chapter.title
        if let slash = value.lastIndex(of: "/") {
            value = String(value[value.index(after: slash)...])
        }
        if let dot = value.lastIndex(of: "."), dot > value.startIndex {
            value = String(value[..<dot])
        }
        guard !value.isEmpty else { return chapter.title }
        return value.prefix(1).uppercased() + value.dropFirst()
    }
}

private func timeString(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value.rounded()))
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}

struct BookDetailView_Previews: PreviewProvider {
    static var previews: some View {
        BookDetailView(
            summary: AudiobookSummary(
                id: "preview",
                bookID: "book",
                title: "A Killer's Wife",
                author: "Victor Methos",
                coverURL: nil,
                duration: nil,
                chapters: nil,
                manifestURL: "/manifest",
                packageURL: nil
            ),
            api: AudiobookAPI(baseURL: URL(string: "https://books.petartopic.com/")!),
            player: PlayerModel()
        )
    }
}
