import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import SGChatLock

// Zenlygram — Chat Lock backstop for ChatControllerImpl (compiled into TelegramUI; hooks in
// ChatController.swift are tagged `// SG: Chat Lock`). Every ChatControllerImpl of a locked chat gets a
// ChatLockControllerGate, however it was constructed (navigation, Forward, Reply in Another Chat, avatar
// "Send Message", username menus, previews, overlay banners, embedded panes).

extension ChatControllerImpl {
    /// Attaches the gate on first use. No gate for `.messageOptions` (renders only ids taken from the chat
    /// that is already open) or for custom contents (no peer).
    private func sgChatLockEnsureGate() -> ChatLockControllerGate? {
        if let gate = ChatLockControllerGate.gate(for: self) {
            return gate
        }
        if case .messageOptions = self.subject {
            return nil
        }
        // The key is always the chat's peer: for `.replyThread` that is the forum / discussion group,
        // never the thread.
        guard let peerId = self.chatLocation.peerId else {
            return nil
        }
        let style: ChatLockGateStyle
        var onCancel: ((ViewController) -> Void)?
        switch self.mode {
        case .standard(.default):
            style = .interactive
        case .standard(.previewing):
            style = .preview
        case .standard(.embedded):
            style = .passive
        case .overlay:
            style = .interactive
            onCancel = { controller in
                controller.dismiss()
            }
        case .inline:
            style = .passive
        }
        let gate = ChatLockControllerGate.attach(to: self, peerId: peerId, accountPeerId: self.context.account.peerId, style: style, onCancel: onCancel)
        gate?.onCover = { [weak self] in
            guard let self, self.isNodeLoaded else {
                return
            }
            self.view.endEditing(true)
            self.chatDisplayNode.dismissInput()
            self.dismissAllTooltips()
            // SG: Chat Lock — name the chat on its cover (first cover of a chat that was opened unlocked).
            self.sgChatLockInstallCoverTitleIfNeeded()
        }
        // Tapping a covered peek opens it like an uncovered one; the promoted chat then asks for the PIN.
        gate?.onPreviewTap = { [weak self] in
            guard let self, case .standard(.previewing) = self.mode else {
                return
            }
            self.animateFromPreviewing()
        }
        return gate
    }

    /// 4th input of the canReadHistory combine: false while the chat is covered, so a covered chat never
    /// marks messages read (or enables raise-to-listen). Additive — the caller-owned `canReadHistory`
    /// promise is untouched.
    func sgChatLockContentAllowed() -> Signal<Bool, NoError> {
        if let gate = self.sgChatLockEnsureGate() {
            return gate.contentAllowed
        }
        return .single(true)
    }

    /// From loadDisplayNode, right after the display node exists: the cover is in place before the first
    /// frame, and an input activation scheduled before load waits for the unlock.
    func sgChatLockViewDidLoad() {
        guard let gate = self.sgChatLockEnsureGate() else {
            return
        }
        gate.hostViewDidLoad()
        // SG: Chat Lock — name the chat on its cover.
        self.sgChatLockInstallCoverTitleIfNeeded()
        if gate.isCovered, let scheduledActivateInput = self.scheduledActivateInput {
            self.scheduledActivateInput = nil
            gate.performWhenUncovered { [weak self] in
                self?.activateInput(type: scheduledActivateInput)
            }
        }
    }

    /// activateInput(type:) is deferred (not dropped) while covered.
    func sgChatLockDeferActivateInput(_ type: ChatControllerActivateInput) -> Bool {
        guard let gate = ChatLockControllerGate.gate(for: self), gate.isCovered else {
            return false
        }
        gate.performWhenUncovered { [weak self] in
            self?.activateInput(type: type)
        }
        return true
    }

    /// Drag-and-drop into a covered chat is refused, and a covered chat exposes no hardware-keyboard
    /// shortcuts (`keyShortcuts` returns none): KeyShortcutsController keeps enumerating the top chat even
    /// under the UIKit PIN prompt, so Up (setupEditMessage + ensureInputViewFocused, then Cmd+A / Cmd+C),
    /// Return (focus the draft), Cmd+Ctrl+I (openPeerInfo pushed above the covered chat), Cmd+F etc. would
    /// otherwise run on it. Touches: ChatControllerNode.hitTest hands every one to the cover while covered
    /// (`sgChatLockCoverHitTest`), with the gate's touch blocker as the backstop.
    var sgChatLockIsCovered: Bool {
        return ChatLockControllerGate.gate(for: self)?.isCovered ?? false
    }

    /// First thing in ChatControllerNode.hitTest while covered, ahead of its routes to the input node (a bot's
    /// button keyboard), the input panels' overlay views and, in a peek, the message list: every point on
    /// the cover belongs to the cover (Unlock / Close; a tap anywhere else on a covered peek promotes it via
    /// the gate's onPreviewTap, and the promoted chat then prompts). Nil outside the cover.
    func sgChatLockCoverHitTest(_ point: CGPoint, in view: UIView, with event: UIEvent?) -> UIView? {
        return ChatLockControllerGate.gate(for: self)?.coverHitTest(point, in: view, with: event)
    }

    /// Last line of animateFromPreviewing: the peek is now a pushed chat, so it prompts (cancel pops it).
    func sgChatLockDidPromoteFromPreview() {
        ChatLockControllerGate.gate(for: self)?.setStyle(.interactive)
        // SG: Chat Lock — a peek's cover has no title; the pushed chat's cover does.
        self.sgChatLockUpdateCoverTitle(animated: false)
    }

    // MARK: - Cover title (SG: Chat Lock)

    /// Adds the chat's name above its cover the first time the chat is covered (so chats that are never
    /// covered pay nothing), then follows the cover: shown while covered, faded out with it on unlock.
    private func sgChatLockInstallCoverTitleIfNeeded() {
        guard self.isNodeLoaded, let gate = ChatLockControllerGate.gate(for: self), gate.isCovered, let peerId = self.chatLocation.peerId else {
            return
        }
        if SGChatLockCoverTitleView.get(self) != nil {
            return
        }
        // Through the node: this runs from inside loadDisplayNode, where UIKit's `view` getter would re-enter.
        let view = self.displayNode.view
        let titleView = SGChatLockCoverTitleView(frame: view.bounds)
        SGChatLockCoverTitleView.set(titleView, on: self)
        view.addSubview(titleView)
        titleView.titleDisposable = (sgChatLockChatTitle(context: self.context, peerId: peerId)
        |> deliverOnMainQueue).start(next: { [weak self, weak titleView] title in
            guard let self, let titleView else {
                return
            }
            titleView.title = title
            self.sgChatLockUpdateCoverTitle(animated: false)
        })
        // False exactly while the gate covers the chat; emitted synchronously on the main thread, together
        // with the cover appearing / starting to fade out.
        titleView.visibilityDisposable = gate.contentAllowed.start(next: { [weak self] _ in
            self?.sgChatLockUpdateCoverTitle(animated: true)
        })
    }

    /// Shown only on a covered, pushed chat (not a peek, an embedded / inline pane or an overlay) whose title
    /// is known, and never for a Secret Vault chat (re-checked: the chat may have been vaulted meanwhile).
    private func sgChatLockUpdateCoverTitle(animated: Bool) {
        guard let titleView = SGChatLockCoverTitleView.get(self) else {
            return
        }
        var isVisible = false
        if let gate = ChatLockControllerGate.gate(for: self), gate.isCovered, gate.style == .interactive, case .standard(.default) = self.mode, let peerId = self.chatLocation.peerId, sgChatLockMayNameChat(peerId, accountPeerId: self.context.account.peerId) {
            isVisible = true
        }
        if isVisible, let title = titleView.title {
            titleView.isShown = true
            titleView.layer.removeAllAnimations()
            titleView.label.text = title
            titleView.label.textColor = self.presentationData.theme.list.itemPrimaryTextColor
            titleView.alpha = 1.0
            titleView.isHidden = false
            return
        }
        titleView.isShown = false
        if titleView.isHidden {
            return
        }
        if animated {
            // Same fade as the gate's cover on unlock.
            UIView.animate(withDuration: 0.2, animations: {
                titleView.alpha = 0.0
            }, completion: { [weak titleView] _ in
                guard let titleView, !titleView.isShown else {
                    return
                }
                titleView.isHidden = true
                titleView.alpha = 1.0
            })
        } else {
            titleView.isHidden = true
        }
    }
}

/// SG: Chat Lock — the chat's name over its cover, where the navigation bar's title sits: the cover hides the
/// navigation bar, so a chat reached from a notification, link or resume would otherwise not say which chat it
/// is. Title only. Never takes touches (the cover and the gate's touch blocker behave as without it).
private final class SGChatLockCoverTitleView: UIView {
    private static var associatedKey: UInt8 = 0

    static func get(_ host: ChatControllerImpl) -> SGChatLockCoverTitleView? {
        return objc_getAssociatedObject(host, &SGChatLockCoverTitleView.associatedKey) as? SGChatLockCoverTitleView
    }

    static func set(_ view: SGChatLockCoverTitleView, on host: ChatControllerImpl) {
        objc_setAssociatedObject(host, &SGChatLockCoverTitleView.associatedKey, view, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    let label = UILabel()
    var title: String?
    /// The latest decision (a fade-out that ends after the title was shown again must not hide it).
    var isShown = false
    var titleDisposable: Disposable?
    var visibilityDisposable: Disposable?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Above the gate's cover (zPosition 10_000).
        self.layer.zPosition = 10_001.0
        self.isUserInteractionEnabled = false
        self.isHidden = true

        self.label.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17.0, weight: .semibold), maximumPointSize: 24.0)
        self.label.adjustsFontForContentSizeCategory = true
        self.label.textAlignment = .center
        self.label.numberOfLines = 1
        self.label.lineBreakMode = .byTruncatingTail
        self.label.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.label)

        // Breakable, so a host that has no size yet never logs a constraint conflict.
        let leading = self.label.leadingAnchor.constraint(greaterThanOrEqualTo: self.safeAreaLayoutGuide.leadingAnchor, constant: 16.0)
        leading.priority = UILayoutPriority(rawValue: 999.0)
        let trailing = self.label.trailingAnchor.constraint(lessThanOrEqualTo: self.safeAreaLayoutGuide.trailingAnchor, constant: -16.0)
        trailing.priority = UILayoutPriority(rawValue: 999.0)
        NSLayoutConstraint.activate([
            self.label.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            // The navigation bar's title line: a 44 pt bar right below the top safe area.
            self.label.centerYAnchor.constraint(equalTo: self.safeAreaLayoutGuide.topAnchor, constant: 22.0),
            leading,
            trailing
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.titleDisposable?.dispose()
        self.visibilityDisposable?.dispose()
    }
}
