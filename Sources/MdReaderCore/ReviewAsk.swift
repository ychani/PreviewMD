import Foundation

/// Where "Rate PreviewMD…" and the one-time review ask send people.
///
/// PreviewMD has no website, so this is the "Leave a review" section of the
/// GitHub README. Linking to our own page (not a listing) lets us change
/// where reviews go without shipping a new app version — keep the README
/// heading text stable, or update this anchor with it.
public enum ReviewLink {
    /// Switch for Help ▸ Rate PreviewMD… and the review ask. On since CMO 2
    /// verified PreviewMD's public review listing (NAR-687, Nov 22 2026) and
    /// the README "Leave a review" section is public. Set it back to `false`
    /// if the listing stops working: the menu item hides and the ask stops.
    public static let isLive = true

    public static let url = URL(string: "https://github.com/ychani/PreviewMD#leave-a-review")!
}

/// What the person chose in the review ask.
public enum ReviewAskResponse: String, Sendable {
    /// Opened the review page. Never ask again.
    case leaveReview
    /// Ask once more after `ReviewAskPolicy.snoozeInterval`.
    case notNow
    /// Never ask again.
    case dontAskAgain
}

/// What is going on in the app when it considers asking. The ask only ever
/// shows at a calm moment: never while editing or mid-task.
public struct ReviewAskMoment: Equatable, Sendable {
    /// The Edit or Split view is showing (the person is writing).
    public var isEditing: Bool
    /// There are unsaved changes.
    public var hasUnsavedChanges: Bool
    /// A file is still loading or rendering.
    public var isLoading: Bool
    /// Read Aloud is speaking.
    public var isReadingAloud: Bool
    /// A sheet, alert or panel is already up.
    public var hasModalOpen: Bool

    public init(isEditing: Bool = false, hasUnsavedChanges: Bool = false, isLoading: Bool = false,
                isReadingAloud: Bool = false, hasModalOpen: Bool = false) {
        self.isEditing = isEditing
        self.hasUnsavedChanges = hasUnsavedChanges
        self.isLoading = isLoading
        self.isReadingAloud = isReadingAloud
        self.hasModalOpen = hasModalOpen
    }

    /// Nothing in progress: safe to ask.
    public var isCalm: Bool {
        !isEditing && !hasUnsavedChanges && !isLoading && !isReadingAloud && !hasModalOpen
    }
}

/// Persisted state for the review ask. Stored locally in UserDefaults; nothing
/// is sent anywhere.
public protocol ReviewAskStore: AnyObject {
    var firstSeen: Date? { get set }
    var previewsOpened: Int { get set }
    /// When the ask was last shown.
    var lastAsked: Date? { get set }
    /// How many times the ask has been shown.
    var timesAsked: Int { get set }
    /// Set by "Leave a review" or "Don't ask again", or after the second ask.
    var isFinished: Bool { get set }
}

/// UserDefaults-backed store (keys prefixed `reviewAsk.`).
public final class UserDefaultsReviewAskStore: ReviewAskStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var firstSeen: Date? {
        get { defaults.object(forKey: "reviewAsk.firstSeen") as? Date }
        set { defaults.set(newValue, forKey: "reviewAsk.firstSeen") }
    }
    public var previewsOpened: Int {
        get { defaults.integer(forKey: "reviewAsk.previewsOpened") }
        set { defaults.set(newValue, forKey: "reviewAsk.previewsOpened") }
    }
    public var lastAsked: Date? {
        get { defaults.object(forKey: "reviewAsk.lastAsked") as? Date }
        set { defaults.set(newValue, forKey: "reviewAsk.lastAsked") }
    }
    public var timesAsked: Int {
        get { defaults.integer(forKey: "reviewAsk.timesAsked") }
        set { defaults.set(newValue, forKey: "reviewAsk.timesAsked") }
    }
    public var isFinished: Bool {
        get { defaults.bool(forKey: "reviewAsk.finished") }
        set { defaults.set(newValue, forKey: "reviewAsk.finished") }
    }
}

/// Decides when to show the one gentle review ask.
///
/// - First ask: at least `minimumUsage` after PreviewMD first ran with this
///   feature **and** at least `minimumPreviews` documents previewed.
/// - "Not now": one more ask, no sooner than `snoozeInterval` later.
/// - "Leave a review", "Don't ask again", or a second ask (whatever the
///   answer): never again.
/// - At most one ask per launch, and only at a calm moment.
public final class ReviewAskPolicy {
    public static let minimumUsage: TimeInterval = 7 * 24 * 60 * 60
    public static let minimumPreviews = 10
    public static let snoozeInterval: TimeInterval = 30 * 24 * 60 * 60
    /// The first ask plus the one retry after "Not now".
    public static let maximumAsks = 2

    private let store: ReviewAskStore
    private let now: () -> Date
    private let isEnabled: Bool
    private var askedThisLaunch = false

    /// `isEnabled` is `ReviewLink.isLive` in the app; when false the ask never shows.
    public init(store: ReviewAskStore, isEnabled: Bool = ReviewLink.isLive,
                now: @escaping () -> Date = Date.init) {
        self.store = store
        self.isEnabled = isEnabled
        self.now = now
        if store.firstSeen == nil { store.firstSeen = now() }
    }

    /// A document finished rendering in the preview.
    public func recordPreviewOpened() {
        guard !store.isFinished else { return }
        store.previewsOpened += 1
    }

    /// Whether the ask may show right now.
    public func shouldAsk(at moment: ReviewAskMoment) -> Bool {
        guard isEnabled, moment.isCalm, !askedThisLaunch, !store.isFinished,
              store.timesAsked < Self.maximumAsks else { return false }
        let current = now()
        if let lastAsked = store.lastAsked {
            return current.timeIntervalSince(lastAsked) >= Self.snoozeInterval
        }
        guard let firstSeen = store.firstSeen,
              current.timeIntervalSince(firstSeen) >= Self.minimumUsage else { return false }
        return store.previewsOpened >= Self.minimumPreviews
    }

    /// Call right before showing the ask.
    public func markAsked() {
        askedThisLaunch = true
        store.timesAsked += 1
        store.lastAsked = now()
    }

    /// The person answered the ask.
    public func record(_ response: ReviewAskResponse) {
        switch response {
        case .leaveReview, .dontAskAgain:
            store.isFinished = true
        case .notNow:
            if store.timesAsked >= Self.maximumAsks { store.isFinished = true }
        }
    }
}
