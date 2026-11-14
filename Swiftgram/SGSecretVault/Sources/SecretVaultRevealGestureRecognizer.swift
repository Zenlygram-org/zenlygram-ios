import UIKit

/// The Secret Vault's title shortcut: a long press on the root "Chats" title asks for the vault PIN.
///
/// It is the only title gesture on purpose. Whenever a Telegram passcode is set, the title is also the stock
/// passcode button (`ChatListTitleView.buttonView`: a single tap locks the whole app), so the former 3-tap
/// streak locked the app on its first tap. A long press instead cancels that button's touch when it is
/// recognized (`cancelsTouchesInView`, UIKit's default, must stay `true`), so it never locks the app.
/// Default gesture arbitration is kept as well: a press that turns into a scroll fails instead of opening
/// anything.
///
/// The separate secret-code reveal uses chat search instead. When that mode is selected, this title
/// shortcut is not attached.
public final class SecretVaultRevealGestureRecognizer: UILongPressGestureRecognizer {
    private let onReveal: () -> Void

    public init(onReveal: @escaping () -> Void) {
        self.onReveal = onReveal
        super.init(target: nil, action: nil)
        self.addTarget(self, action: #selector(self.handleLongPress))
    }

    @objc private func handleLongPress() {
        // One request per press: a held press keeps reporting `.changed` until it ends.
        guard self.state == .began else {
            return
        }
        self.onReveal()
    }
}
