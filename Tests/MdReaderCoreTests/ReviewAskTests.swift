import XCTest
@testable import MdReaderCore

private final class MemoryStore: ReviewAskStore {
    var firstSeen: Date?
    var previewsOpened = 0
    var lastAsked: Date?
    var timesAsked = 0
    var isFinished = false
}

final class ReviewAskTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var store = MemoryStore()
    private let calm = ReviewAskMoment()

    private func makePolicy() -> ReviewAskPolicy {
        ReviewAskPolicy(store: store, isEnabled: true, now: { [unowned self] in self.clock })
    }

    /// A policy for someone who has used PreviewMD long and often enough.
    private func eligiblePolicy() -> ReviewAskPolicy {
        let policy = makePolicy()
        for _ in 0..<10 { policy.recordPreviewOpened() }
        clock += 7 * day
        return makePolicy() // fresh launch
    }

    func testFirstLaunchRecordsFirstSeenOnce() {
        _ = makePolicy()
        let first = store.firstSeen
        clock += day
        _ = makePolicy()
        XCTAssertEqual(store.firstSeen, first)
    }

    func testNeedsSevenDaysAndTenPreviews() {
        let policy = makePolicy()
        for _ in 0..<9 { policy.recordPreviewOpened() }
        clock += 7 * day
        XCTAssertFalse(policy.shouldAsk(at: calm), "9 previews is not enough")
        policy.recordPreviewOpened()
        XCTAssertTrue(policy.shouldAsk(at: calm))
    }

    func testTenPreviewsBeforeSevenDaysDoesNotAsk() {
        let policy = makePolicy()
        for _ in 0..<50 { policy.recordPreviewOpened() }
        clock += 7 * day - 60
        XCTAssertFalse(policy.shouldAsk(at: calm))
        clock += 60
        XCTAssertTrue(policy.shouldAsk(at: calm))
    }

    func testShowsAtMostOncePerLaunch() {
        let policy = eligiblePolicy()
        XCTAssertTrue(policy.shouldAsk(at: calm))
        policy.markAsked()
        XCTAssertFalse(policy.shouldAsk(at: calm), "already asked; no answer yet")
        policy.record(.notNow)
        clock += 31 * day
        XCTAssertFalse(policy.shouldAsk(at: calm), "never twice in one launch")
    }

    func testLeaveReviewIsFinal() {
        let policy = eligiblePolicy()
        policy.markAsked()
        policy.record(.leaveReview)
        clock += 365 * day
        XCTAssertFalse(makePolicy().shouldAsk(at: calm))
    }

    func testNotNowAsksAgainAfterThirtyDaysThenNever() {
        var policy = eligiblePolicy()
        policy.markAsked()
        policy.record(.notNow)

        clock += 30 * day - 60
        policy = makePolicy()
        XCTAssertFalse(policy.shouldAsk(at: calm), "not before 30 days")

        clock += 60
        policy = makePolicy()
        XCTAssertTrue(policy.shouldAsk(at: calm), "asks once more after 30 days")
        policy.markAsked()
        policy.record(.notNow)

        clock += 90 * day
        XCTAssertFalse(makePolicy().shouldAsk(at: calm), "a second Not now ends it")
        XCTAssertTrue(store.isFinished)
    }

    func testDontAskAgainIsFinal() {
        let policy = eligiblePolicy()
        policy.markAsked()
        policy.record(.dontAskAgain)
        for _ in 0..<100 { makePolicy().recordPreviewOpened() }
        clock += 1000 * day
        XCTAssertFalse(makePolicy().shouldAsk(at: calm))
    }

    func testDontAskAgainOnSecondAskIsFinal() {
        var policy = eligiblePolicy()
        policy.markAsked()
        policy.record(.notNow)
        clock += 31 * day
        policy = makePolicy()
        policy.markAsked()
        policy.record(.dontAskAgain)
        clock += 31 * day
        XCTAssertFalse(makePolicy().shouldAsk(at: calm))
    }

    func testUnansweredAskCountsTowardTheLimit() {
        // Window closed or app quit while the ask was up: it still counts.
        var policy = eligiblePolicy()
        policy.markAsked()
        clock += 31 * day
        policy = makePolicy()
        XCTAssertTrue(policy.shouldAsk(at: calm))
        policy.markAsked()
        clock += 31 * day
        XCTAssertFalse(makePolicy().shouldAsk(at: calm))
    }

    func testNeverShowsMidTask() {
        let policy = eligiblePolicy()
        let busy: [ReviewAskMoment] = [
            ReviewAskMoment(isEditing: true),
            ReviewAskMoment(hasUnsavedChanges: true),
            ReviewAskMoment(isLoading: true),
            ReviewAskMoment(isReadingAloud: true),
            ReviewAskMoment(hasModalOpen: true),
        ]
        for moment in busy {
            XCTAssertFalse(policy.shouldAsk(at: moment), "\(moment)")
        }
        XCTAssertTrue(policy.shouldAsk(at: calm), "calm again: may ask")
    }

    func testUserDefaultsStoreRoundTrips() throws {
        let suite = "ReviewAskTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsReviewAskStore(defaults: defaults)
        let policy = ReviewAskPolicy(store: store, isEnabled: true, now: { [unowned self] in self.clock })
        for _ in 0..<10 { policy.recordPreviewOpened() }
        clock += 7 * day
        let reloaded = ReviewAskPolicy(store: UserDefaultsReviewAskStore(defaults: defaults),
                                       isEnabled: true, now: { [unowned self] in self.clock })
        XCTAssertTrue(reloaded.shouldAsk(at: calm))
        reloaded.markAsked()
        reloaded.record(.dontAskAgain)
        XCTAssertTrue(UserDefaultsReviewAskStore(defaults: defaults).isFinished)
    }

    func testReviewLinkPointsAtReadmeSection() {
        XCTAssertEqual(ReviewLink.url.absoluteString, "https://github.com/ychani/PreviewMD#leave-a-review")
    }

    func testLiveNowThatListingIsVerified() {
        // CMO 2 verified the AlternativeTo listing on NAR-687 (Nov 22).
        XCTAssertTrue(ReviewLink.isLive)
    }

    func testSwitchedOffWhileNoVerifiedListing() {
        // The off switch still wins over eligibility: if the listing is ever
        // pulled, isLive = false hides the menu item and the ask.
        let policy = ReviewAskPolicy(store: store, isEnabled: false, now: { [unowned self] in self.clock })
        for _ in 0..<50 { policy.recordPreviewOpened() }
        clock += 60 * day
        let later = ReviewAskPolicy(store: store, isEnabled: false, now: { [unowned self] in self.clock })
        XCTAssertFalse(later.shouldAsk(at: calm), "off switch wins over eligibility")
        let enabled = ReviewAskPolicy(store: store, isEnabled: true, now: { [unowned self] in self.clock })
        XCTAssertTrue(enabled.shouldAsk(at: calm), "same state asks once switched on")
    }
}
