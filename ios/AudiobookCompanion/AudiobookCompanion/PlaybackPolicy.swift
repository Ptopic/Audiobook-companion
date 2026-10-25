import Foundation

struct PlaybackPolicy {
    private(set) var intentGeneration = 0
    private(set) var interruptionActive = false
    private var resumeAfterInterruption = false

    mutating func didPlay() {
        intentGeneration += 1
        resumeAfterInterruption = false
    }

    mutating func didPause() {
        intentGeneration += 1
        resumeAfterInterruption = false
    }

    mutating func didBeginInterruption(wasPlaying: Bool) {
        intentGeneration += 1
        resumeAfterInterruption = resumeAfterInterruption || wasPlaying
        interruptionActive = true
    }

    mutating func didEndInterruption(shouldResume: Bool) -> Bool {
        interruptionActive = false
        let resume = shouldResume && resumeAfterInterruption
        resumeAfterInterruption = false
        return resume
    }

    func canAutoPlaySeek(startedAt generation: Int) -> Bool {
        !interruptionActive && generation == intentGeneration
    }

    static func isSameLoadedChapter(activeBookID: String?, requestedBookID: String,
                                    activeChapterID: String?, requestedChapterID: String,
                                    initialPosition: TimeInterval?) -> Bool {
        activeBookID == requestedBookID && activeChapterID == requestedChapterID && initialPosition == nil
    }

    static func nowPlayingRate(isPlaying: Bool, rate: Float) -> Double {
        isPlaying ? Double(rate) : 0
    }
}
