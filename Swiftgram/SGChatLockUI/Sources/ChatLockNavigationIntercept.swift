import Foundation
import Display
import AccountContext
import SGChatLock

// Zenlygram — Chat Lock entry gate for navigateToChatControllerImpl (compiled into TelegramUI).
//
// Called once, right AFTER the age-verification branch, so an age-restricted locked chat shows the age
// sheet first and then exactly one PIN. Keyed by `chatLocation.peerId`, so it covers `.peer`, `.replyThread`
// (topics, comments: the forum / discussion group) and the forum branch alike. On cancel nothing has been
// pushed, so the user stays exactly where they were.
//
// Returns true when navigation was intercepted (a prompt is pending); on success it re-enters with the
// age check skipped, and the fresh pending grant lets that pass straight through.
func sgChatLockInterceptNavigation(_ params: NavigateToChatControllerParams) -> Bool {
    let peerId = params.chatLocation.peerId
    let accountPeerId = params.context.account.peerId
    let session = ChatLockSession.shared
    if session.isContentVisible(peerId: peerId, accountPeerId: accountPeerId) {
        return false
    }
    session.requireUnlock(peerId: peerId, accountPeerId: accountPeerId, reason: .openChat, from: params.navigationController, completion: { result in
        if case .unlocked = result {
            navigateToChatControllerImpl(params.withSkipAgeVerification(true))
        }
    })
    return true
}
