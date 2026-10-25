import XCTest
@testable import AudiobookPlaybackPolicy

final class PlaybackPolicyTests: XCTestCase {
    func testInterruptionInvalidatesPendingSeekAndResumesOnlyOnRecommendation() {
        var policy = PlaybackPolicy()
        policy.didPlay()
        let seekGeneration = policy.intentGeneration
        policy.didBeginInterruption(wasPlaying: true)

        XCTAssertFalse(policy.canAutoPlaySeek(startedAt: seekGeneration))
        policy.didBeginInterruption(wasPlaying: false)
        XCTAssertTrue(policy.didEndInterruption(shouldResume: true))
        XCTAssertFalse(policy.canAutoPlaySeek(startedAt: seekGeneration))

        policy.didBeginInterruption(wasPlaying: true)
        XCTAssertFalse(policy.didEndInterruption(shouldResume: false))
    }

    func testExplicitPauseDuringSeekAndInterruptionPreventsAutoplay() {
        var policy = PlaybackPolicy()
        policy.didPlay()
        let seekGeneration = policy.intentGeneration
        policy.didPause()
        XCTAssertFalse(policy.canAutoPlaySeek(startedAt: seekGeneration))

        policy.didBeginInterruption(wasPlaying: true)
        policy.didPause()
        XCTAssertFalse(policy.didEndInterruption(shouldResume: true))
    }

    func testLoadedChapterIdentityIncludesBookAndRestorePosition() {
        XCTAssertTrue(PlaybackPolicy.isSameLoadedChapter(
            activeBookID: "book-a", requestedBookID: "book-a",
            activeChapterID: "chapter-1", requestedChapterID: "chapter-1", initialPosition: nil
        ))
        XCTAssertFalse(PlaybackPolicy.isSameLoadedChapter(
            activeBookID: "book-a", requestedBookID: "book-b",
            activeChapterID: "chapter-1", requestedChapterID: "chapter-1", initialPosition: nil
        ))
        XCTAssertFalse(PlaybackPolicy.isSameLoadedChapter(
            activeBookID: "book-a", requestedBookID: "book-a",
            activeChapterID: "chapter-1", requestedChapterID: "chapter-1", initialPosition: 42
        ))
    }

    func testPausedNowPlayingRateIsZero() {
        XCTAssertEqual(PlaybackPolicy.nowPlayingRate(isPlaying: false, rate: 1.5), 0)
        XCTAssertEqual(PlaybackPolicy.nowPlayingRate(isPlaying: true, rate: 1.5), 1.5)
    }
}
