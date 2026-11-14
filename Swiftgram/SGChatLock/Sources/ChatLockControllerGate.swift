import Foundation
import UIKit
import UIKit.UIGestureRecognizerSubclass
import Display
import Postbox
import SwiftSignalKit
import TelegramPresentationData

public enum ChatLockGateStyle {
    /// A chat the user opened: prompts as soon as it is on screen; cancelling closes it.
    case interactive
    /// A long-press peek: cover only, never prompts, never keeps a grant alive.
    case preview
    /// An embedded / inline chat: cover with an Unlock button, no automatic prompt.
    case passive
}

/// Zenlygram — Chat Lock backstop (L3). Attached to every screen that renders one chat's content
/// (ChatControllerImpl, forum / monoforum topic lists, the music player). Until a grant exists it keeps an
/// opaque cover over the host from the first frame, swallows every touch that reaches the host outside
/// that cover (ChatLockTouchBlockerGestureRecognizer), withholds `contentAllowed` (read receipts, keyboard,
/// drops) and — for interactive hosts — asks for the PIN when the host is first shown (or re-shown after a
/// relock). No code path that constructs such a screen can skip it: direct construction, previews,
/// promotion, overlay, inline, embedded.
///
/// Main thread only. Stored strongly as an associated object on the host; the host is held weakly.
public final class ChatLockControllerGate {
    private static var associatedKey: UInt8 = 0

    let key: ChatLockKey
    private(set) weak var host: ViewController?
    public private(set) var style: ChatLockGateStyle
    private let customCancel: ((ViewController) -> Void)?

    /// Called when the host becomes covered after having been visible (relock, lock set on a preview).
    public var onCover: (() -> Void)?

    /// Called when a covered `.preview` host is tapped (the cover swallows the host's own tap handling):
    /// hosts that can be promoted from a peek (ChatControllerImpl.animateFromPreviewing) set this, and the
    /// promotion then prompts through setStyle(.interactive). Hosts whose hitTest sends a peek's touches
    /// past the cover (ChatControllerNode hands them to its message list) must route them to the cover
    /// first with `coverHitTest`, or this never fires.
    public var onPreviewTap: (() -> Void)?

    private var covered: Bool
    private let contentAllowedValue: ValuePromise<Bool>
    private var deferredActions: [() -> Void] = []
    private var visibilityDisposable: Disposable?
    private var holdDisposable: Disposable?
    private var coverView: ChatLockCoverView?
    private var observerView: ChatLockHostObserverView?
    private var touchBlocker: ChatLockTouchBlockerGestureRecognizer?
    private var relockDisposable: Disposable?
    private var promptInFlight = false
    /// Whether the automatic prompt is still owed for the current covered period: set when the gate starts
    /// covered or becomes covered, and on every relock (also for a chat that was already covered); cleared
    /// when a prompt for it is requested (automatic, Unlock button, preview promotion) and left cleared when
    /// the user cancels that prompt. A prompt that ends `.interrupted` (taken down by the app passcode,
    /// superseded, never presented) was not answered, so it re-arms. Window re-entries — e.g. an iPad detail
    /// chat coming back after a full-screen UIKit modal presented from the master column closes — and the
    /// didBecomeActive resume only prompt while it is set, so a chat whose prompt the user cancelled on the
    /// cover is not asked for again out of the blue. Its cover keeps the Unlock and Close buttons.
    private var autoPromptOwed: Bool

    /// Attaches (or returns the existing) gate. Returns nil when `peerId` is nil or is the account's own
    /// peer (Saved Messages is never locked). Safe to call before the host's view is loaded.
    @discardableResult
    public static func attach(to host: ViewController, peerId: PeerId?, accountPeerId: PeerId, style: ChatLockGateStyle, onCancel: ((ViewController) -> Void)? = nil) -> ChatLockControllerGate? {
        guard let peerId, peerId != accountPeerId else {
            return nil
        }
        if let existing = ChatLockControllerGate.gate(for: host) {
            return existing
        }
        let gate = ChatLockControllerGate(host: host, key: ChatLockKey(accountPeerId: accountPeerId, peerId: peerId), style: style, onCancel: onCancel)
        objc_setAssociatedObject(host, &ChatLockControllerGate.associatedKey, gate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return gate
    }

    public static func gate(for host: ViewController) -> ChatLockControllerGate? {
        return objc_getAssociatedObject(host, &ChatLockControllerGate.associatedKey) as? ChatLockControllerGate
    }

    private init(host: ViewController, key: ChatLockKey, style: ChatLockGateStyle, onCancel: ((ViewController) -> Void)?) {
        self.host = host
        self.key = key
        self.style = style
        self.customCancel = onCancel

        let session = ChatLockSession.shared
        let visible = session.isContentVisible(peerId: key.peerId, accountPeerId: key.accountPeerId)
        self.covered = !visible
        self.autoPromptOwed = !visible
        self.contentAllowedValue = ValuePromise(visible, ignoreRepeated: true)

        session.registerGate(self)
        self.visibilityDisposable = session.observeVisibility(key, { [weak self] visible in
            self?.visibilityUpdated(visible)
        })
        // A relock starts a new covered period for a chat that was already covered as well (its earlier
        // prompt cancelled or interrupted; visibilityUpdated does not re-cover it): it prompts again on
        // resume, or when it is next shown. Runs after the relocked grants' covers went up.
        self.relockDisposable = session.addRelockHandler({ [weak self] _ in
            guard let self, self.covered, !self.promptInFlight else {
                return
            }
            // SG: Secret Vault — the vault never prompts automatically: a vaulted chat whose vault is closed
            // keeps its cover (Unlock / Close) instead.
            if ChatLockSession.shared.isVaultClosedFor(self.key) {
                return
            }
            self.autoPromptOwed = true
        })
        if visible && style != .preview {
            self.startHolding()
        }
    }

    deinit {
        self.visibilityDisposable?.dispose()
        self.holdDisposable?.dispose()
        self.relockDisposable?.dispose()
    }

    // MARK: - Public API

    /// Adds the cover (when covered) and the window-observer sentinel. Call right after the host's display
    /// node is created (from loadDisplayNode) so the first frame is already covered.
    public func hostViewDidLoad() {
        self.installViewsIfNeeded()
    }

    public var isCovered: Bool {
        return self.covered
    }

    /// For hosts whose hitTest routes touches around their subview order, called first thing while covered:
    /// ChatControllerNode.hitTest hands touches straight to the input node (a bot's button keyboard), the
    /// input panels' overlay views and, in a peek, the message list (whose tap recognizer this gate's touch
    /// blocker would fail). Every point inside the cover belongs to it: its Unlock / Close buttons, or the
    /// cover itself, whose tap opens a covered peek (`onPreviewTap`). Nil when not covered, when the cover
    /// is not in place yet, or for a point outside it.
    public func coverHitTest(_ point: CGPoint, in view: UIView, with event: UIEvent?) -> UIView? {
        guard self.covered, let coverView = self.coverView, coverView.superview != nil, !coverView.isHidden else {
            return nil
        }
        let coverPoint = view.convert(point, to: coverView)
        guard coverView.bounds.contains(coverPoint) else {
            return nil
        }
        return coverView.hitTest(coverPoint, with: event) ?? coverView
    }

    /// False while covered. Starts with the visibility at attach time.
    public var contentAllowed: Signal<Bool, NoError> {
        return self.contentAllowedValue.get()
    }

    /// `.preview` → `.interactive` (peek promoted to a pushed chat) prompts at once if the host is on screen.
    public func setStyle(_ style: ChatLockGateStyle) {
        guard self.style != style else {
            return
        }
        self.style = style
        if case .preview = style {
            self.holdDisposable?.dispose()
            self.holdDisposable = nil
        } else if !self.covered {
            self.startHolding()
        }
        if self.covered, let coverView = self.coverView {
            coverView.update(style: style, presentationData: ChatLockSession.shared.currentPresentationData())
        }
        // A promoted peek is a newly shown chat: it prompts (owed or not).
        if case .interactive = style, self.covered, !self.promptInFlight, self.isHostViewInWindow {
            self.requestUnlock(reason: .openChat, cancelClosesHost: true)
        }
    }

    /// Runs `action` now when uncovered, otherwise once the host is uncovered.
    public func performWhenUncovered(_ action: @escaping () -> Void) {
        if self.covered {
            self.deferredActions.append(action)
        } else {
            action()
        }
    }

    // MARK: - Session hooks

    /// Whether the host is still part of the UI: a member of its navigation stack, in a window, or a
    /// window-presented controller still in the view hierarchy. (Display keeps `navigationController` and
    /// `presentingViewController` after a pop / dismissal, so neither alone means "attached".)
    var isHostAttached: Bool {
        guard let host = self.host else {
            return false
        }
        if let navigationController = host.navigationController as? NavigationController, navigationController.viewControllers.contains(where: { $0 === host }) {
            return true
        }
        if host.isViewLoaded {
            if host.view.window != nil {
                return true
            }
            if host.presentingViewController != nil && host.view.superview != nil {
                return true
            }
        }
        return false
    }

    /// SG: Secret Vault — an `.interactive` host that is still part of the UI (the vault eviction's candidates).
    var isInteractiveAttachedHost: Bool {
        guard case .interactive = self.style else {
            return false
        }
        return self.isHostAttached
    }

    /// SG: Secret Vault — removes the host and everything stacked above it, iPad master-column controllers
    /// included (unlike `performCancel`, which keeps them: the vault list itself is one); a host in no stack is
    /// dismissed.
    func evict(animated: Bool) {
        guard let host = self.host else {
            return
        }
        if let navigationController = host.navigationController as? NavigationController, let index = navigationController.viewControllers.firstIndex(where: { $0 === host }) {
            navigationController.setViewControllers(Array(navigationController.viewControllers.prefix(index)), animated: animated)
        } else if let customCancel = self.customCancel {
            customCancel(host)
        } else {
            host.dismiss()
        }
    }

    func ensureHolding() {
        if !self.covered, self.style != .preview {
            self.startHolding()
        }
    }

    /// A covered interactive chat that still owes its automatic prompt (newly shown, or relocked) and is the
    /// visible top of its stack (or not in a stack).
    var canResumePrompt: Bool {
        guard self.covered, self.autoPromptOwed, case .interactive = self.style, !self.promptInFlight, let host = self.host, self.isHostViewInWindow else {
            return false
        }
        // SG: Secret Vault — the vault never prompts automatically (only the cover's Unlock button, a promoted
        // peek or an explicit navigation ask for the vault PIN).
        if ChatLockSession.shared.isVaultClosedFor(self.key) {
            return false
        }
        if let navigationController = host.navigationController as? NavigationController, navigationController.viewControllers.contains(where: { $0 === host }) {
            return navigationController.viewControllers.last === host
        }
        return true
    }

    func promptIfNeeded(reason: ChatLockPromptReason) {
        guard self.canResumePrompt, !ChatLockSession.isAppExtension, UIApplication.shared.applicationState == .active else {
            return
        }
        self.requestUnlock(reason: reason, cancelClosesHost: true)
    }

    // MARK: - State

    private func visibilityUpdated(_ visible: Bool) {
        if visible {
            if self.covered {
                self.uncover()
            }
        } else if !self.covered {
            self.cover()
        }
    }

    private func cover() {
        self.covered = true
        self.autoPromptOwed = true
        self.holdDisposable?.dispose()
        self.holdDisposable = nil
        if let view = self.hostView {
            self.installViewsIfNeeded()
            view.endEditing(true)
        }
        self.contentAllowedValue.set(false)
        self.onCover?()
    }

    private func uncover() {
        self.covered = false
        self.autoPromptOwed = false
        self.updateTouchBlocker()
        if let coverView = self.coverView {
            UIView.animate(withDuration: 0.2, animations: {
                coverView.alpha = 0.0
            }, completion: { [weak self, weak coverView] _ in
                guard let self, let coverView, !self.covered else {
                    return
                }
                coverView.removeFromSuperview()
                coverView.alpha = 1.0
            })
        }
        self.contentAllowedValue.set(true)
        let actions = self.deferredActions
        self.deferredActions = []
        for action in actions {
            action()
        }
        if self.style != .preview {
            self.startHolding()
        }
    }

    private func startHolding() {
        guard self.holdDisposable == nil else {
            return
        }
        self.holdDisposable = ChatLockSession.shared.hold(peerId: self.key.peerId, accountPeerId: self.key.accountPeerId, isAttached: { [weak self] in
            return self?.isHostAttached ?? false
        })
    }

    // MARK: - Views

    /// Display hosts: `view == displayNode.view`. Read through the node so this is safe from inside
    /// loadDisplayNode (UIKit's `view` getter would re-enter loadView there).
    private var hostView: UIView? {
        guard let host = self.host, host.isNodeLoaded else {
            return nil
        }
        return host.displayNode.view
    }

    private var isHostViewInWindow: Bool {
        return self.hostView?.window != nil
    }

    private func installViewsIfNeeded() {
        guard let view = self.hostView else {
            return
        }
        if self.observerView == nil {
            let observerView = ChatLockHostObserverView(frame: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
            observerView.onWindowChange = { [weak self] isInWindow in
                self?.hostWindowChanged(isInWindow: isInWindow)
            }
            view.addSubview(observerView)
            self.observerView = observerView
        }
        if self.touchBlocker == nil {
            let touchBlocker = ChatLockTouchBlockerGestureRecognizer()
            view.addGestureRecognizer(touchBlocker)
            self.touchBlocker = touchBlocker
        }
        if self.covered {
            let coverView: ChatLockCoverView
            if let current = self.coverView {
                coverView = current
            } else {
                coverView = ChatLockCoverView(frame: view.bounds)
                coverView.onUnlock = { [weak self] in
                    self?.unlockTapped()
                }
                coverView.onClose = { [weak self] in
                    self?.closeTapped()
                }
                coverView.onBackgroundTap = { [weak self] in
                    guard let self, self.covered, case .preview = self.style else {
                        return
                    }
                    self.onPreviewTap?()
                }
                self.coverView = coverView
            }
            coverView.update(style: self.style, presentationData: ChatLockSession.shared.currentPresentationData())
            coverView.layer.removeAllAnimations()
            coverView.alpha = 1.0
            coverView.frame = view.bounds
            if coverView.superview !== view {
                coverView.removeFromSuperview()
                view.addSubview(coverView)
            } else {
                view.bringSubviewToFront(coverView)
            }
        }
        self.updateTouchBlocker()
    }

    /// The blocker runs whenever the cover is up, in every style, and never while the chat is visible. It
    /// leaves the cover's own recognizers alone: a covered peek opens through the cover's tap
    /// (`onPreviewTap`), not through the host's tap-to-open recognizer (ChatControllerNode's message-list
    /// tap is inside the host and would be failed here, which is why that host routes a covered peek's
    /// touches to the cover with `coverHitTest`).
    private func updateTouchBlocker() {
        guard let touchBlocker = self.touchBlocker else {
            return
        }
        touchBlocker.coverView = self.coverView
        touchBlocker.isEnabled = self.covered
    }

    private func hostWindowChanged(isInWindow: Bool) {
        if isInWindow {
            if self.covered, let view = self.hostView, let coverView = self.coverView, coverView.superview === view {
                // Subviews added after the cover (navigation bar, panels) must not end up above it.
                view.bringSubviewToFront(coverView)
            }
            // Prompts only while the automatic prompt is owed (first appearance, a relock, or an unanswered
            // interrupted prompt): not when the host merely comes back into the window after its prompt was
            // cancelled, e.g. after an unrelated full-screen modal.
            DispatchQueue.main.async { [weak self] in
                self?.promptIfNeeded(reason: .openChat)
            }
        } else {
            ChatLockSession.shared.setNeedsHolderCheck(self.key)
        }
    }

    // MARK: - Actions

    private func requestUnlock(reason: ChatLockPromptReason, cancelClosesHost: Bool) {
        guard let host = self.host else {
            return
        }
        self.promptInFlight = true
        self.autoPromptOwed = false
        ChatLockSession.shared.requireUnlock(peerId: self.key.peerId, accountPeerId: self.key.accountPeerId, reason: reason, from: host, completion: { [weak self] result in
            guard let self else {
                return
            }
            self.promptInFlight = false
            switch result {
            case .unlocked:
                break
            case .cancelled:
                if cancelClosesHost, self.covered, let host = self.host {
                    self.performCancel(host)
                }
            case .interrupted:
                // Nobody answered this prompt (the app passcode took it down, another prompt superseded it, it
                // never got a window, it gave up waiting): still owed, so the chat prompts on resume or when it
                // is next shown, as the presenter and the relock expect.
                if self.covered {
                    self.autoPromptOwed = true
                }
            }
        })
    }

    private func unlockTapped() {
        guard self.covered, !self.promptInFlight else {
            return
        }
        self.requestUnlock(reason: .openChat, cancelClosesHost: false)
    }

    private func closeTapped() {
        guard let host = self.host else {
            return
        }
        self.performCancel(host)
    }

    private func performCancel(_ host: ViewController) {
        if let customCancel = self.customCancel {
            customCancel(host)
            return
        }
        if let navigationController = host.navigationController as? NavigationController, let index = navigationController.viewControllers.firstIndex(where: { $0 === host }) {
            // Drop the host and everything stacked above it (PeerInfo, pickers, sub-lists opened from the
            // covered chat, e.g. by a hardware-keyboard shortcut under the PIN prompt); keep iPad
            // master-column controllers, like the relock eviction does.
            let controllers = navigationController.viewControllers
            let kept = Array(controllers[..<index]) + controllers[(index + 1)...].filter { controller in
                if let controller = controller as? ViewController, case .master = controller.navigationPresentation {
                    return true
                }
                return false
            }
            if kept.count == controllers.count - 1 {
                navigationController.filterController(host, animated: true)
            } else {
                navigationController.setViewControllers(kept, animated: true)
            }
        } else {
            host.dismiss()
        }
    }
}

// MARK: - Views

/// Hidden 1×1 sentinel inside the host view: entering a window drives the (owed) prompt, leaving it re-checks
/// whether the unlock grant is still held (Display gives no appearance callbacks when a UIKit modal closes).
final class ChatLockHostObserverView: UIView {
    var onWindowChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isHidden = true
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        self.onWindowChange?(self.window != nil)
    }
}

/// Opaque cover over a locked chat's content. Swallows the touches that reach it (the gate's
/// ChatLockTouchBlockerGestureRecognizer takes the ones a host routes around it) and hides every sibling
/// from VoiceOver. Buttons are centred because hit-testing ignores `zPosition` (a later-added sibling could
/// otherwise sit above an edge button).
final class ChatLockCoverView: UIView {
    var onUnlock: (() -> Void)?
    var onClose: (() -> Void)?
    var onBackgroundTap: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let unlockButton = UIButton(type: .custom)
    private let closeButton = UIButton(type: .system)
    private let stackView = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.layer.zPosition = 10_000.0
        self.isUserInteractionEnabled = true
        self.accessibilityViewIsModal = true

        self.iconView.contentMode = .scaleAspectFit
        self.iconView.isAccessibilityElement = false

        self.titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17.0, weight: .semibold), maximumPointSize: 24.0)
        self.titleLabel.adjustsFontForContentSizeCategory = true
        self.titleLabel.textAlignment = .center
        self.titleLabel.numberOfLines = 0
        self.titleLabel.accessibilityTraits = .header

        self.unlockButton.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17.0, weight: .semibold), maximumPointSize: 24.0)
        self.unlockButton.titleLabel?.adjustsFontForContentSizeCategory = true
        self.unlockButton.layer.cornerRadius = 12.0
        // These buttons have no UIButton.Configuration. Keep the same padding using the public
        // Objective-C property instead of opting them into configuration-driven layout/styling.
        self.unlockButton.setValue(NSValue(uiEdgeInsets: UIEdgeInsets(top: 12.0, left: 28.0, bottom: 12.0, right: 28.0)), forKey: "contentEdgeInsets")
        self.unlockButton.addTarget(self, action: #selector(self.unlockPressed), for: .touchUpInside)

        self.closeButton.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17.0, weight: .regular), maximumPointSize: 24.0)
        self.closeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        self.closeButton.setValue(NSValue(uiEdgeInsets: UIEdgeInsets(top: 12.0, left: 20.0, bottom: 12.0, right: 20.0)), forKey: "contentEdgeInsets")
        self.closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)

        self.stackView.axis = .vertical
        self.stackView.alignment = .center
        self.stackView.spacing = 16.0
        self.stackView.translatesAutoresizingMaskIntoConstraints = false
        self.stackView.addArrangedSubview(self.iconView)
        self.stackView.addArrangedSubview(self.titleLabel)
        self.stackView.addArrangedSubview(self.unlockButton)
        self.stackView.addArrangedSubview(self.closeButton)
        self.stackView.setCustomSpacing(28.0, after: self.titleLabel)
        self.stackView.setCustomSpacing(4.0, after: self.unlockButton)
        self.addSubview(self.stackView)

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.backgroundTapped(_:)))
        tapRecognizer.cancelsTouchesInView = false
        self.addGestureRecognizer(tapRecognizer)

        NSLayoutConstraint.activate([
            self.stackView.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            self.stackView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.stackView.leadingAnchor.constraint(greaterThanOrEqualTo: self.leadingAnchor, constant: 24.0),
            self.stackView.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor, constant: -24.0),
            self.unlockButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44.0),
            self.closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44.0)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(style: ChatLockGateStyle, presentationData: PresentationData) {
        let theme = presentationData.theme
        self.backgroundColor = theme.list.plainBackgroundColor.withAlphaComponent(1.0)

        let accentColor = theme.list.itemAccentColor
        let isPreview: Bool
        if case .preview = style {
            isPreview = true
        } else {
            isPreview = false
        }
        let iconConfiguration = UIImage.SymbolConfiguration(pointSize: isPreview ? 64.0 : 48.0, weight: .regular)
        self.iconView.image = UIImage(systemName: "lock.fill", withConfiguration: iconConfiguration)?.withTintColor(accentColor, renderingMode: .alwaysOriginal)

        self.titleLabel.text = FenixuzChatLockStrings.coverTitle
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.titleLabel.isHidden = isPreview

        self.unlockButton.setTitle(FenixuzChatLockStrings.unlock, for: .normal)
        self.unlockButton.setTitleColor(theme.list.itemCheckColors.foregroundColor, for: .normal)
        self.unlockButton.backgroundColor = accentColor
        self.unlockButton.isHidden = isPreview

        self.closeButton.setTitle(FenixuzChatLockStrings.close, for: .normal)
        self.closeButton.tintColor = accentColor
        if case .interactive = style {
            self.closeButton.isHidden = false
        } else {
            self.closeButton.isHidden = true
        }

        self.accessibilityLabel = FenixuzChatLockStrings.coverTitle
    }

    @objc private func unlockPressed() {
        self.onUnlock?()
    }

    @objc private func closePressed() {
        self.onClose?()
    }

    @objc private func backgroundTapped(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended {
            self.onBackgroundTap?()
        }
    }
}

/// Attached to the host view and enabled while the host is covered. Hosts may route hit-testing around
/// their subview order, and nodes added after the cover sit above it for hit-testing although the cover is
/// drawn on top. (ChatControllerNode.hitTest, which hands touches straight to the input node, the input
/// panels' overlay views and a peek's message list, sends them to the cover first via
/// `ChatLockControllerGate.coverHitTest`; this blocker is the backstop there and the guard for the other
/// hosts.) Every touch whose hit view is outside the cover is taken here on touch-down:
/// `delaysTouchesBegan` + `cancelsTouchesInView` keep it from ever reaching that view, and the host's own
/// recognizers are prevented (or made to wait for this one, which never fails). Recognizers outside the
/// host (navigation swipe-back, a parent's scrolling, the context menu around a peek) and the cover's own
/// recognizers (its tap opens a covered peek) are left alone. A tap that ends on one of the cover's visible
/// buttons is forwarded to it, so Unlock / Close keep working where a view above the cover overlaps them.
final class ChatLockTouchBlockerGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// Touches that hit-test into the cover belong to the cover.
    weak var coverView: UIView?

    private var trackedTouch: UITouch?
    private weak var pendingControl: UIControl?

    init() {
        super.init(target: nil, action: nil)
        self.delegate = self
        self.cancelsTouchesInView = true
        self.delaysTouchesBegan = true
        self.delaysTouchesEnded = true
        self.isEnabled = false
    }

    // MARK: - Relations with other recognizers

    /// The host's recognizers this blocker holds back: everything attached inside the host view except the
    /// cover's own (the cover's tap opens a covered peek; it must never wait for this blocker, which never
    /// sees the cover's touches and so never fails for them).
    private func isHeldBack(_ other: UIGestureRecognizer) -> Bool {
        guard let view = self.view, let otherView = other.view, otherView.isDescendant(of: view) else {
            return false
        }
        if let coverView = self.coverView, otherView.isDescendant(of: coverView) {
            return false
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let coverView = self.coverView, let touchView = touch.view else {
            return true
        }
        return !touchView.isDescendant(of: coverView)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return !self.isHeldBack(otherGestureRecognizer)
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        return self.isHeldBack(preventedGestureRecognizer)
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Also holds back the host's recognizers whose delegates allow simultaneous recognition.
        return self.isEnabled && self.isHeldBack(otherGestureRecognizer)
    }

    // MARK: - Touches

    /// The visible, enabled cover button under `touch`, if any.
    private func coverControl(at touch: UITouch) -> UIControl? {
        guard let coverView = self.coverView, coverView.window != nil, !coverView.isHidden, coverView.alpha > 0.01 else {
            return nil
        }
        var current = coverView.hitTest(touch.location(in: coverView), with: nil)
        while let view = current, view !== coverView {
            if let control = view as? UIControl, control.isEnabled {
                return control
            }
            current = view.superview
        }
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // Continuous: `.began` already claims the touch (the hit view never sees it); the gesture then
        // follows the first finger to its end so a tap on a cover button can be forwarded.
        guard self.state == .possible, let touch = touches.first else {
            return
        }
        self.trackedTouch = touch
        self.pendingControl = self.coverControl(at: touch)
        self.state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if self.state == .began || self.state == .changed {
            self.state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard self.state == .began || self.state == .changed, let trackedTouch = self.trackedTouch, touches.contains(trackedTouch) else {
            return
        }
        var forwardTo: UIControl?
        if let pendingControl = self.pendingControl, self.coverControl(at: trackedTouch) === pendingControl {
            forwardTo = pendingControl
        }
        self.state = .ended
        if let forwardTo {
            // After the touch dispatch: the action may present the PIN screen or close the host.
            DispatchQueue.main.async { [weak forwardTo] in
                forwardTo?.sendActions(for: .touchUpInside)
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        if self.state == .began || self.state == .changed {
            self.state = .cancelled
        }
    }

    override func reset() {
        super.reset()
        self.trackedTouch = nil
        self.pendingControl = nil
    }
}
