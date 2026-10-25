import AVFoundation
import Combine
import Foundation
import MediaPlayer
import UIKit

/// Playback positions persisted per book, so switching books never loses a
/// book's progress and the app can resume any of them where they left off.
enum PlaybackStateStore {
    struct State: Codable {
        var bookID: String
        var chapterID: String
        var position: TimeInterval
        var rate: Float
    }

    private struct Store: Codable {
        var lastBookID: String?
        var states: [String: State]
    }

    private static let key = "persistedPlaybackStates"
    private static let legacyKey = "persistedPlaybackState"
    static let didChange = Notification.Name("PlaybackStateStore.didChange")
    static let changedBookIDKey = "bookID"

    /// Upserts the state for the book and marks it as the most recently played.
    static func save(_ state: State) {
        var store = loadStore()
        store.states[state.bookID] = state
        store.lastBookID = state.bookID
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: [changedBookIDKey: state.bookID])
    }

    /// The most recently played book's state (resume-on-launch).
    static func load() -> State? {
        let store = loadStore()
        guard let lastBookID = store.lastBookID else { return nil }
        return store.states[lastBookID]
    }

    static func state(for bookID: String) -> State? {
        loadStore().states[bookID]
    }

    static func remove(for bookID: String) {
        var store = loadStore()
        store.states.removeValue(forKey: bookID)
        if store.lastBookID == bookID {
            store.lastBookID = nil
        }
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: [changedBookIDKey: bookID])
    }

    private static func loadStore() -> Store {
        if let data = UserDefaults.standard.data(forKey: key),
           let store = try? JSONDecoder().decode(Store.self, from: data) {
            return store
        }
        // Migrate the pre-multi-book single-state entry so no progress is lost.
        if let data = UserDefaults.standard.data(forKey: legacyKey),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return Store(lastBookID: state.bookID, states: [state.bookID: state])
        }
        return Store(lastBookID: nil, states: [:])
    }
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var activeChapter: AudiobookChapter?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackError: String?
    @Published var rate: Float = 1.0 {
        didSet {
            if isPlaying { player?.rate = rate }
            updateNowPlayingInfo()
            persistCheckpoint(force: true)
        }
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var sessionObservers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    private var bookID: String?
    private var bookTitle = ""
    private var bookAuthor: String?
    private var coverURL: URL?
    private var lastPersistedPosition: TimeInterval = -1
    private var seekGeneration = 0
    private var pendingSeekGeneration: Int?
    private var playbackPolicy = PlaybackPolicy()

    var activeBookID: String? { bookID }

    init() {
        installRemoteCommands()
        installAudioSessionObservers()
        updateRemoteCommandAvailability()
    }

    var currentSegment: AudiobookSegment? {
        guard let chapter = activeChapter else { return nil }
        return chapter.segments.last(where: { currentTime >= $0.start && currentTime < $0.end })
    }

    func load(chapter: AudiobookChapter, audioURL: URL, bookID: String,
              initialPosition: TimeInterval? = nil, title: String, author: String?, coverURL: URL?) {
        if PlaybackPolicy.isSameLoadedChapter(activeBookID: self.bookID, requestedBookID: bookID,
                                              activeChapterID: activeChapter?.id, requestedChapterID: chapter.id,
                                              initialPosition: initialPosition) {
            return
        }
        persistCheckpoint(force: true)
        player?.pause()
        removeTimeObserver()
        removeItemObservers()
        artworkTask?.cancel()
        seekGeneration += 1
        playbackPolicy.didPause()
        pendingSeekGeneration = nil
        self.bookID = bookID
        bookTitle = title
        bookAuthor = author
        self.coverURL = coverURL
        artwork = nil
        activeChapter = chapter
        currentTime = min(max(initialPosition ?? 0, 0), max(chapter.duration, 0))
        isPlaying = false
        playbackError = nil
        player = AVPlayer(url: audioURL)
        if initialPosition != nil, let player {
            let generation = seekGeneration
            pendingSeekGeneration = generation
            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600)) { [weak self, weak player] _ in
                Task { @MainActor in
                    guard let self, let player,
                          self.player === player, self.seekGeneration == generation else { return }
                    self.pendingSeekGeneration = nil
                    let actualTime = player.currentTime().seconds
                    if actualTime.isFinite {
                        self.currentTime = actualTime
                        self.persistCheckpoint(force: true)
                    }
                }
            }
        }
        installTimeObserver()
        installItemObservers()
        loadArtwork()
        updateNowPlayingInfo()
        updateRemoteCommandAvailability()
        persistCheckpoint(force: true)
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let player, !isPlaying, !playbackPolicy.interruptionActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            playbackError = "Audio playback is unavailable: \(error.localizedDescription)"
            return
        }
        playbackError = nil
        playbackPolicy.didPlay()
        if let chapter = activeChapter, currentTime >= chapter.duration, chapter.duration > 0 {
            seek(to: 0, autoPlay: true)
            return
        }
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        playbackPolicy.didPause()
        player?.pause()
        isPlaying = false
        persistCheckpoint(force: true)
        updateNowPlayingInfo()
    }

    func seek(to segment: AudiobookSegment, autoPlay: Bool = true) {
        seek(to: segment.start, autoPlay: autoPlay)
    }

    func seek(to seconds: TimeInterval, autoPlay: Bool = false) {
        guard let player else { return }
        let bounded = max(0, min(seconds, activeChapter?.duration ?? seconds))
        let target = CMTime(seconds: bounded, preferredTimescale: 600)
        seekGeneration += 1
        let generation = seekGeneration
        let intentGeneration = playbackPolicy.intentGeneration
        pendingSeekGeneration = generation
        currentTime = bounded
        persistCheckpoint(force: true)
        updateNowPlayingInfo()
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            Task { @MainActor in
                guard let self, let player,
                      self.player === player, self.seekGeneration == generation else { return }
                self.pendingSeekGeneration = nil
                if !finished {
                    let actualTime = player.currentTime().seconds
                    if actualTime.isFinite {
                        self.currentTime = actualTime
                        self.persistCheckpoint(force: true)
                        self.updateNowPlayingInfo()
                    }
                    return
                }
                self.currentTime = bounded
                if autoPlay && self.playbackPolicy.canAutoPlaySeek(startedAt: intentGeneration) { self.play() }
                self.updateNowPlayingInfo()
            }
        }
    }

    func jump(by offset: TimeInterval) {
        seek(to: currentTime + offset, autoPlay: isPlaying)
    }

    /// Persists immediately (used when the app leaves the foreground).
    func persistNow() {
        persistCheckpoint(force: true)
    }

    func stop() {
        persistCheckpoint(force: true)
        player?.pause()
        removeTimeObserver()
        removeItemObservers()
        artworkTask?.cancel()
        seekGeneration += 1
        playbackPolicy.didPause()
        pendingSeekGeneration = nil
        player = nil
        bookID = nil
        bookTitle = ""
        bookAuthor = nil
        coverURL = nil
        artwork = nil
        activeChapter = nil
        currentTime = 0
        isPlaying = false
        playbackError = nil
        lastPersistedPosition = -1
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateRemoteCommandAvailability()
    }

    deinit {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        statusObserver?.invalidate()
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        for (command, target) in remoteTargets { command.removeTarget(target) }
    }

    private func installTimeObserver() {
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let self, let player, self.player === player else { return }
                guard self.pendingSeekGeneration == nil else { return }
                let time = player.currentTime().seconds
                guard time.isFinite else { return }
                self.currentTime = time
                if abs(self.currentTime - self.lastPersistedPosition) >= 2 {
                    self.persistCheckpoint(force: true)
                    self.updateNowPlayingInfo()
                }
            }
        }
    }

    private func persistCheckpoint(force: Bool) {
        guard let chapter = activeChapter, let bookID else { return }
        if !force, abs(currentTime - lastPersistedPosition) < 2 { return }
        lastPersistedPosition = currentTime
        PlaybackStateStore.save(.init(bookID: bookID, chapterID: chapter.id, position: currentTime, rate: rate))
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func installItemObservers() {
        guard let item = player?.currentItem else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player?.currentItem === item else { return }
                self.currentTime = self.activeChapter?.duration ?? self.currentTime
                self.pause()
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] notification in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player?.currentItem === item else { return }
                self.failPlayback((notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error) ?? item.error)
            }
        }
        statusObserver = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player?.currentItem === item, item.status == .failed else { return }
                self.failPlayback(item.error)
            }
        }
    }

    private func removeItemObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
    }

    private func failPlayback(_ error: Error?) {
        pause()
        playbackError = error.map { "Playback failed: \($0.localizedDescription)" }
            ?? "Playback failed. Please try again."
    }

    private func installAudioSessionObservers() {
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleInterruption(notification) }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleRouteChange(notification) }
        })
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawValue) else { return }
        switch type {
        case .began:
            playbackPolicy.didBeginInterruption(wasPlaying: isPlaying)
            player?.pause()
            isPlaying = false
            persistCheckpoint(force: true)
            updateNowPlayingInfo()
        case .ended:
            let shouldResume = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            if playbackPolicy.didEndInterruption(shouldResume: shouldResume) { play() }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: rawValue) == .oldDeviceUnavailable else { return }
        pause()
    }

    private func installRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.preferredIntervals = [15]
        register(commands.playCommand) { model, _ in model.play() }
        register(commands.pauseCommand) { model, _ in model.pause() }
        register(commands.togglePlayPauseCommand) { model, _ in model.togglePlayback() }
        register(commands.skipBackwardCommand) { model, _ in model.jump(by: -15) }
        register(commands.skipForwardCommand) { model, _ in model.jump(by: 15) }
        register(commands.previousTrackCommand) { model, _ in model.jump(by: -15) }
        register(commands.nextTrackCommand) { model, _ in model.jump(by: 15) }
        register(commands.changePlaybackPositionCommand) { model, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            model.seek(to: event.positionTime, autoPlay: model.isPlaying)
        }
    }

    private func register(_ command: MPRemoteCommand,
                          action: @escaping @MainActor (PlayerModel, MPRemoteCommandEvent) -> Void) {
        let target = command.addTarget { [weak self] event in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self, self.player != nil else { return }
                action(self, event)
            }
            return .success
        }
        remoteTargets.append((command, target))
    }

    private func updateRemoteCommandAvailability() {
        let commands = MPRemoteCommandCenter.shared()
        let available = player != nil
        commands.playCommand.isEnabled = available
        commands.pauseCommand.isEnabled = available
        commands.togglePlayPauseCommand.isEnabled = available
        commands.skipBackwardCommand.isEnabled = available
        commands.skipForwardCommand.isEnabled = available
        commands.previousTrackCommand.isEnabled = available
        commands.nextTrackCommand.isEnabled = available
        commands.changePlaybackPositionCommand.isEnabled = available
    }

    private func updateNowPlayingInfo() {
        guard let chapter = activeChapter else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: bookTitle,
            MPMediaItemPropertyAlbumTitle: chapter.title,
            MPMediaItemPropertyMediaType: MPMediaType.audioBook.rawValue,
            MPMediaItemPropertyPlaybackDuration: chapter.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: PlaybackPolicy.nowPlayingRate(isPlaying: isPlaying, rate: rate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if let bookAuthor { info[MPMediaItemPropertyArtist] = bookAuthor }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        if #available(iOS 18.0, *) {
            info[MPNowPlayingInfoPropertyExcludeFromSuggestions] = true
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork() {
        guard let coverURL else { return }
        let expectedBookID = bookID
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: coverURL),
                  !Task.isCancelled, let image = UIImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            guard let self, self.bookID == expectedBookID, self.coverURL == coverURL else { return }
            self.artwork = artwork
            self.updateNowPlayingInfo()
        }
    }
}
