import AppKit
import MdReaderCore

/// Shows the one gentle review ask (policy in `ReviewAskPolicy`) and opens
/// the review page for "Rate PreviewMD…".
///
/// Wording is Brand & Editorial's final text (NAR-688), verbatim.
@MainActor
final class ReviewAskPresenter {
    /// Wait this long after a window opens, then check again that nothing
    /// is in progress before asking.
    private static let settleDelay: TimeInterval = 3

    private let policy: ReviewAskPolicy
    private var pending = false

    init(policy: ReviewAskPolicy = ReviewAskPolicy(store: UserDefaultsReviewAskStore())) {
        self.policy = policy
    }

    static func openReviewPage() {
        NSWorkspace.shared.open(ReviewLink.url)
    }

    func recordPreviewOpened() {
        policy.recordPreviewOpened()
    }

    /// A document window opened. After it settles, ask if the policy allows
    /// and the app is calm; otherwise wait for the next window.
    func windowDidOpen(moment: @escaping @MainActor () -> ReviewAskMoment) {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                guard self.policy.shouldAsk(at: moment()),
                      let window = AppState.documentWindow(), window.attachedSheet == nil else { return }
                self.policy.markAsked()
                self.present(on: window)
            }
        }
    }

    private func present(on window: NSWindow) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        // Final wording from Brand & Editorial (NAR-688 copy document).
        alert.messageText = "Want to share feedback on PreviewMD?"
        alert.informativeText = "I’d like to hear what you think of PreviewMD. Honest feedback is welcome."
        alert.addButton(withTitle: "Leave a review")
        alert.addButton(withTitle: "Not now")
        alert.addButton(withTitle: "Don't ask again")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn:
                    self?.policy.record(.leaveReview)
                    Self.openReviewPage()
                case .alertThirdButtonReturn:
                    self?.policy.record(.dontAskAgain)
                default:
                    self?.policy.record(.notNow)
                }
            }
        }
    }
}
