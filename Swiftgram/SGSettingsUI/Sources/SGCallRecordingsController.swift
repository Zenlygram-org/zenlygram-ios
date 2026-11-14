// MARK: Zenlygram — the call-recordings list.
//
// Everything a recording can do, in one place: listen back, hand it to the system share sheet, send
// it to the user's own Saved Messages, or delete it. Nothing here syncs, backs up or reports
// anything; the two ways a recording leaves the device are the share sheet and Saved Messages, and
// both are a tap the user makes in that moment (the setting under Zenlygram ▸ Call Recording is the
// only automatic path, and it lives on the recorder's side, not here).
//
// PROTECTED CHATS STAY PROTECTED HERE. A call with a Secret Vault contact or a Chat-Locked chat is
// listed redacted — no name, no date, no duration — and playing, sharing or sending it first asks
// for the very same local authorization that opening that chat would (`ChatLockSession.requireUnlock`
// for the account that MADE the recording and the peer it was made with, not the account whose
// settings are open). A recording whose identity cannot be checked while protection is configured
// (made before recordings carried the peer, or while the protection state is unreadable) offers no
// way to listen or export at all — only Delete, so nothing sensitive is ever left on disk with no
// row to remove it. The rules live in `SGCallRecordingPrivacy` / `SGCallRecordingRowPresentation`.
//
// THE CALL BEING RECORDED RIGHT NOW HAS A ROW (its sidecar is written at start, so a crash cannot
// orphan it). It says "recording now" and offers only Delete: its file is half-written and still
// open in the encoder. That delete is a durable tombstone, honoured when the call ends — or on the
// next launch if the app dies first; see `SGCallRecordingStore.delete(id:)`.
//
// A RECORDING ON ITS WAY TO SAVED MESSAGES IS STILL A RECORDING ON THIS PHONE. It keeps its row,
// the row says it is being sent, and its file is not touched until the server has acknowledged the
// message — see SGCallRecordingDelivery. Deleting one that is mid-send cancels the upload FIRST and
// deletes only if that succeeded; a delete that left a message on its way would deliver a recording
// the user just deleted.
//
// NO SURPRISE PLAYBACK. Play is refused while a call is in progress (the arbiter would queue the
// playback behind the call and start it, out loud, when the call ends), and anything playing stops
// when this screen goes away or the protected chat it belongs to locks again.
//
// While call recording itself is unavailable in this build the screen still lists, plays and
// deletes what is already on the device, but offers no export.

import SGCallRecording
import SGCallRecordingDelivery
import SGCallRecordingDeliveryCore
import SGChatLock
import SGProtectedStore
import SGStrings
import SGCustomerSyncCore

import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import TelegramCallsUI
import PresentationDataUtils
import ItemListUI
import AccountContext

// MARK: - Formatting

private func sgCallRecordingDurationString(_ duration: Double) -> String {
    let total = max(0, Int(duration.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

private func sgCallRecordingSizeString(_ bytes: Int64) -> String {
    if bytes < 1024 {
        return "\(bytes) B"
    }
    let kilobytes = Double(bytes) / 1024.0
    if kilobytes < 1024.0 {
        return String(format: "%.0f KB", kilobytes)
    }
    return String(format: "%.1f MB", kilobytes / 1024.0)
}

private let sgCallRecordingDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

private func sgCallRecordingBadgeText(_ badge: SGCallRecordingRowBadge, lang: String) -> String {
    switch badge {
    case .live:
        return i18n("CallRecording.Live", lang)
    case .playing:
        return i18n("CallRecording.Playing", lang)
    case .sendFailed:
        return i18n("CallRecording.SendToSaved.Failed", lang)
    case .incomplete:
        return i18n("CallRecording.Incomplete", lang)
    case .sending:
        return i18n("CallRecording.SendToSaved.Waiting", lang)
    }
}

// MARK: - Privacy

/// The verdict for the recorded pair, from the shared fail-closed protection store.
private func sgCallRecordingPrivacy(_ item: SGCallRecordingItem) -> SGCallRecordingPrivacy {
    let store = SGProtectedStore.shared
    return item.privacy(isProtectionConfigured: store.isAnyProtectionConfigured, protection: { peerId, accountPeerId in
        switch store.protection(peerId: peerId, accountPeerId: accountPeerId) {
        case .none:
            return .none
        case .locked, .vaulted:
            return .protected
        case .unknown:
            return .unknown
        }
    })
}

private func sgCallRecordingPresentation(_ item: SGCallRecordingItem, privacy: SGCallRecordingPrivacy, playingId: String?, activeId: String?) -> SGCallRecordingRowPresentation {
    let sendStatus = SGCallRecordingDelivery.shared.status(item: item)
    return SGCallRecordingRowPresentation(
        privacy: privacy,
        isLive: activeId == item.id,
        isPlaying: playingId == item.id,
        isSendWaiting: sendStatus == .waiting,
        isSendFailed: sendStatus == .failed,
        isComplete: item.isComplete,
        isExportAvailable: sgCallRecordingAvailable
    )
}

// MARK: - Arguments

private final class SGCallRecordingsArguments {
    let openItem: (SGCallRecordingItem) -> Void
    let openManagementOnly: (String) -> Void
    let deleteAll: () -> Void

    init(openItem: @escaping (SGCallRecordingItem) -> Void, openManagementOnly: @escaping (String) -> Void, deleteAll: @escaping () -> Void) {
        self.openItem = openItem
        self.openManagementOnly = openManagementOnly
        self.deleteAll = deleteAll
    }
}

// MARK: - Entries

private enum SGCallRecordingsSection: Int32 {
    case list
    case actions
}

private enum SGCallRecordingsEntry: ItemListNodeEntry {
    case header(String)
    case recording(Int32, SGCallRecordingItem, SGCallRecordingRowPresentation, String)
    /// A recording that exists but cannot be shown: locked or damaged sidecar, or hidden by a cleanup
    /// that has not finished. Neutral title, no details at all, Delete only. (index, id, title)
    case managementOnly(Int32, String, String)
    case footer(String)
    case deleteAll(String)

    var section: ItemListSectionId {
        switch self {
        case .deleteAll:
            return SGCallRecordingsSection.actions.rawValue
        default:
            return SGCallRecordingsSection.list.rawValue
        }
    }

    var stableId: Int64 {
        switch self {
        case .header:
            return Int64.min
        case let .recording(index, _, _, _), let .managementOnly(index, _, _):
            return Int64(index) + 1
        case .footer:
            return Int64.max - 1
        case .deleteAll:
            return Int64.max
        }
    }

    private var sortIndex: Int32 {
        switch self {
        case .header:
            return 0
        case let .recording(index, _, _, _), let .managementOnly(index, _, _):
            return 1 + index
        case .footer:
            return Int32.max - 1
        case .deleteAll:
            return Int32.max
        }
    }

    static func == (lhs: SGCallRecordingsEntry, rhs: SGCallRecordingsEntry) -> Bool {
        switch lhs {
        case let .header(lText):
            if case let .header(rText) = rhs, lText == rText {
                return true
            }
            return false
        case let .recording(lIndex, lItem, lPresentation, lLang):
            if case let .recording(rIndex, rItem, rPresentation, rLang) = rhs, lIndex == rIndex, lItem == rItem, lPresentation == rPresentation, lLang == rLang {
                return true
            }
            return false
        case let .managementOnly(lIndex, lId, lTitle):
            if case let .managementOnly(rIndex, rId, rTitle) = rhs, lIndex == rIndex, lId == rId, lTitle == rTitle {
                return true
            }
            return false
        case let .footer(lText):
            if case let .footer(rText) = rhs, lText == rText {
                return true
            }
            return false
        case let .deleteAll(lText):
            if case let .deleteAll(rText) = rhs, lText == rText {
                return true
            }
            return false
        }
    }

    static func < (lhs: SGCallRecordingsEntry, rhs: SGCallRecordingsEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SGCallRecordingsArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, multiline: true, sectionId: self.section)
        case let .recording(_, item, presentation, lang):
            let title: String
            if presentation.isRedacted {
                title = i18n("CallRecording.Protected.Title", lang)
            } else {
                title = item.peerTitle.isEmpty ? i18n("CallRecording.UnknownPeer", lang) : item.peerTitle
            }
            // Status FIRST, then what may be shown about the call, then the size. The detail line is
            // truncated to one line, so whatever comes last is what gets cut — never the status. A
            // redacted row shows no size either: for Opus it tracks the duration.
            var parts = presentation.badges.map { sgCallRecordingBadgeText($0, lang: lang) }
            if presentation.showsDate {
                parts.append(sgCallRecordingDateFormatter.string(from: Date(timeIntervalSince1970: item.startTimestamp)))
            }
            if presentation.showsDuration {
                parts.append(sgCallRecordingDurationString(item.duration))
            }
            if !presentation.isRedacted {
                parts.append(sgCallRecordingSizeString(item.totalSize))
            }
            // ItemListDisclosureItem DRAWS `attributedLabel` but SPEAKS `label` (its accessibility
            // value; the detail line is never spoken). So the primary status is what is drawn on the
            // right, and the whole detail line — already redacted for a protected row — is what
            // VoiceOver reads after the title.
            let primary = presentation.primaryBadge
            let isWarning = primary?.isWarning ?? false
            let primaryText = primary.map { sgCallRecordingBadgeText($0, lang: lang) } ?? ""
            let primaryColor = isWarning ? presentationData.theme.list.itemDestructiveColor : presentationData.theme.list.itemSecondaryTextColor
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: title,
                label: parts.joined(separator: ", "),
                attributedLabel: NSAttributedString(string: primaryText, font: Font.regular(presentationData.fontSize.itemListBaseFontSize), textColor: primaryColor),
                labelStyle: .text,
                additionalDetailLabel: parts.isEmpty ? nil : parts.joined(separator: "  ·  "),
                additionalDetailLabelColor: isWarning ? .destructive : .generic,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.openItem(item)
                }
            )
        case let .managementOnly(_, id, title):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: title,
                label: "",
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.openManagementOnly(id)
                }
            )
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .deleteAll(text):
            return ItemListActionItem(presentationData: presentationData, title: text, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.deleteAll()
            })
        }
    }
}

/// What the empty list tells the user to do. It must never point at a Record button the call screen
/// will not show (no iOS Call Integration on this device) or cannot use (Integration switched off).
private func sgCallRecordingsEmptyText(_ startSupport: SGCallRecordingStartSupport, lang: String) -> String {
    switch startSupport {
    case .available:
        return i18n("CallRecording.List.Empty", lang)
    case .requiresCallKit:
        return i18n("CallRecording.NeedsCallKit", lang)
    case .unsupportedOnDevice:
        return i18n("CallRecording.List.Empty.NoCallKit", lang)
    case .featureUnavailable:
        return i18n("CallRecording.Unavailable.Text", lang)
    }
}

private func sgCallRecordingsEntries(items: [SGCallRecordingItem], managementOnlyIds: [String], hasAnyFiles: Bool, playingId: String?, activeId: String?, startSupport: SGCallRecordingStartSupport, lang: String) -> [SGCallRecordingsEntry] {
    var entries: [SGCallRecordingsEntry] = []
    if items.isEmpty && managementOnlyIds.isEmpty {
        entries.append(.header(i18n("CallRecording.List.Title", lang)))
        entries.append(.footer(sgCallRecordingsEmptyText(startSupport, lang: lang)))
        // MARK: Zenlygram — "Delete All" is gated on what is ON DISK, not on what this list can
        // show: leftovers from an older build, a tombstone or temp file, a cleanup ledger. Without
        // this row the screen would say "No recordings yet" over files the user cannot remove.
        if hasAnyFiles {
            entries.append(.deleteAll(i18n("CallRecording.List.DeleteAll", lang)))
        }
        return entries
    }
    var rows: [(item: SGCallRecordingItem, presentation: SGCallRecordingRowPresentation)] = []
    for item in items {
        rows.append((item, sgCallRecordingPresentation(item, privacy: sgCallRecordingPrivacy(item), playingId: playingId, activeId: activeId)))
    }
    // The total is withheld as soon as any row is redacted or unavailable: with the other sizes on
    // screen, a total would give away the size of the one that is not.
    if managementOnlyIds.isEmpty && !rows.contains(where: { $0.presentation.isRedacted }) {
        let totalSize = items.reduce(Int64(0)) { $0 + $1.totalSize }
        entries.append(.header("\(i18n("CallRecording.List.Title", lang))  ·  \(sgCallRecordingSizeString(totalSize))"))
    } else {
        entries.append(.header(i18n("CallRecording.List.Title", lang)))
    }
    var index: Int32 = 0
    for row in rows {
        entries.append(.recording(index, row.item, row.presentation, lang))
        index += 1
    }
    for id in managementOnlyIds {
        entries.append(.managementOnly(index, id, i18n("CallRecording.Damaged.Title", lang)))
        index += 1
    }
    entries.append(.footer(i18n(sgCallRecordingAvailable ? "CallRecording.List.Footer" : "CallRecording.Unavailable.Text", lang)))
    entries.append(.deleteAll(i18n("CallRecording.List.DeleteAll", lang)))
    return entries
}

// MARK: - Controller

public func sgCallRecordingsController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var presentNativeControllerImpl: ((UIViewController) -> Void)?
    var getSourceViewImpl: (() -> UIView?)?
    var getHostImpl: (() -> UIViewController?)?
    var isOnScreenImpl: (() -> Bool)?

    // Re-read the directory whenever something changed; the list is a handful of small sidecars.
    let refreshPromise = ValuePromise<Bool>(true, ignoreRepeated: false)
    // While a PROTECTED recording plays: the chat-lock hold that keeps its grant alive, and the
    // visibility observer that stops playback the moment that chat locks again.
    let protectedPlayback = MetaDisposable()
    let ongoingCallDisposable = MetaDisposable()

    func alert(_ title: String, _ text: String) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(textAlertController(context: context, title: title, text: text, actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
        ]), nil)
    }

    func stopPlayback() {
        protectedPlayback.set(nil)
        SGCallRecordingPlayer.shared.stop()
    }

    /// Runs `action` only once the app's existing local authorization for the RECORDED pair has
    /// succeeded. `.open` runs at once; `.unverifiable` never runs (no proof exists for it).
    func authorize(_ privacy: SGCallRecordingPrivacy, _ action: @escaping () -> Void) {
        switch privacy {
        case .open:
            action()
        case .unverifiable:
            let lang = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
            alert(i18n("CallRecording.List.Title", lang), i18n("CallRecording.Protected.Unverifiable.Text", lang))
        case let .protected(accountPeerId, peerId):
            let peer = EnginePeer.Id(peerId)
            let account = EnginePeer.Id(accountPeerId)
            ChatLockSession.shared.requireUnlock(peerId: peer, accountPeerId: account, reason: .openChat, from: getHostImpl?(), completion: { result in
                guard case .unlocked = result else {
                    return
                }
                action()
                // A successful prompt leaves a pending grant (for a vault peer, the account's whole
                // vault) open for a minute. Nothing here is a chat screen that would use it, so it is
                // released at once: a hold that is never attached lets it lapse after the short
                // registration grace. Whatever `action` needs to keep (playback, the share sheet) it
                // has already held itself, attached to what is actually on screen.
                ChatLockSession.shared.hold(peerId: peer, accountPeerId: account, isAttached: { false }).dispose()
            })
        }
    }

    /// The recording as it is on disk NOW, re-checked after every prompt: it may have been deleted,
    /// its account removed, or its call may have become the live one meanwhile.
    func currentItem(_ id: String, privacy: SGCallRecordingPrivacy) -> SGCallRecordingItem? {
        guard !SGCallRecordingStore.shared.isActive(id: id), let item = SGCallRecordingStore.shared.item(id: id) else {
            return nil
        }
        // The verdict the authorization was obtained for must still be the verdict now (the chat may
        // have been vaulted or locked while the prompt was up); otherwise the proof is for nothing.
        return sgCallRecordingPrivacy(item) == privacy ? item : nil
    }

    func startPlayback(_ item: SGCallRecordingItem, privacy: SGCallRecordingPrivacy) {
        let lang = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        protectedPlayback.set(nil)
        // The audio session is taken through the app's arbiter, never from
        // `AVAudioSession.sharedInstance()`: this screen is reachable with a call minimised behind
        // the status-bar call bar, and reconfiguring the shared session there kills the live call's
        // microphone. See SGCallRecordingPlayer's header.
        SGCallRecordingPlayer.shared.play(item: item, acquireAudioSession: { activated, deactivate in
            return context.sharedContext.mediaManager.audioSession.push(audioSessionType: .play(mixWithOthers: false), activate: { _ in
                Queue.mainQueue().async {
                    activated()
                }
            }, deactivate: { _ in
                return Signal { subscriber in
                    Queue.mainQueue().async {
                        deactivate()
                        subscriber.putCompletion()
                    }
                    return EmptyDisposable
                }
            })
        }, onFinish: { end in
            protectedPlayback.set(nil)
            switch end {
            case .finished, .interrupted:
                break
            case .activationTimedOut, .failed:
                alert(i18n("CallRecording.List.Title", lang), i18n("CallRecording.Play.Failed", lang))
            }
            refreshPromise.set(true)
        })
        // Only for a playback that actually started: `play` reports an immediate failure through
        // `onFinish` before anything is playing, and a hold left behind then would keep nothing.
        if case let .protected(accountPeerId, peerId) = privacy, SGCallRecordingPlayer.shared.isPlaying(id: item.id) {
            let peer = EnginePeer.Id(peerId)
            let account = EnginePeer.Id(accountPeerId)
            let id = item.id
            let disposables = DisposableSet()
            // Keeps the grant alive while THIS recording plays on THIS screen, like an open chat.
            disposables.add(ChatLockSession.shared.hold(peerId: peer, accountPeerId: account, isAttached: {
                return (isOnScreenImpl?() ?? false) && SGCallRecordingPlayer.shared.isPlaying(id: id)
            }))
            // The chat locked again (background, device lock, inactivity, vault closed): stop.
            disposables.add((ChatLockSession.shared.contentVisibility(peerId: peer, accountPeerId: account)
            |> deliverOnMainQueue).start(next: { isVisible in
                if !isVisible && SGCallRecordingPlayer.shared.isPlaying(id: id) {
                    stopPlayback()
                    refreshPromise.set(true)
                }
            }))
            protectedPlayback.set(disposables)
        }
        refreshPromise.set(true)
    }

    func play(_ id: String, privacy: SGCallRecordingPrivacy) {
        let lang = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        // Refused during a call: the audio arbiter never evicts the call's session, so a Play here
        // would sit queued behind it and start out loud the moment the call ends.
        ongoingCallDisposable.set((context.sharedContext.hasOngoingCall.get()
        |> take(1)
        |> deliverOnMainQueue).start(next: { hasOngoingCall in
            if hasOngoingCall {
                alert(i18n("CallRecording.List.Title", lang), i18n("CallRecording.Play.DuringCall", lang))
                return
            }
            authorize(privacy, {
                guard let item = currentItem(id, privacy: privacy), isOnScreenImpl?() ?? false else {
                    refreshPromise.set(true)
                    return
                }
                if context.sharedContext.immediateHasOngoingCall {
                    alert(i18n("CallRecording.List.Title", lang), i18n("CallRecording.Play.DuringCall", lang))
                    return
                }
                startPlayback(item, privacy: privacy)
            })
        }))
    }

    func share(_ id: String, privacy: SGCallRecordingPrivacy) {
        authorize(privacy, {
            // The system share sheet, and only ever on this explicit tap. It hands the file to
            // whatever the user picks and this app never learns where it went — which is why it is
            // a separate action from "Send to Saved Messages", where the destination is known, the
            // upload is confirmed and the local copy is then removed. One URL for a recording made by
            // this build; a pre-mix recording still hands over its two, because mixing it here would
            // mean re-encoding an artefact that cannot be re-made (see SGCallRecordingMetadata).
            guard sgCallRecordingAvailable, let item = currentItem(id, privacy: privacy) else {
                refreshPromise.set(true)
                return
            }
            let urls = item.audioPaths.map { URL(fileURLWithPath: $0) }
            if urls.isEmpty {
                return
            }
            let activityController = UIActivityViewController(activityItems: urls, applicationActivities: nil)
            if let popover = activityController.popoverPresentationController, let sourceView = getSourceViewImpl?() {
                popover.sourceView = sourceView
                popover.sourceRect = CGRect(x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 1.0, height: 1.0)
                popover.permittedArrowDirections = []
            }
            if case let .protected(accountPeerId, peerId) = privacy {
                // The chat's grant lives exactly as long as the share sheet is on screen. When the chat
                // relocks (background, device lock) the grant is revoked and the existing relock
                // teardown dismisses the sheet, so an export cannot be finished later without the PIN.
                let sheetHold = ChatLockSession.shared.hold(peerId: EnginePeer.Id(peerId), accountPeerId: EnginePeer.Id(accountPeerId), isAttached: { [weak activityController] in
                    return activityController?.viewIfLoaded?.window != nil
                })
                activityController.completionWithItemsHandler = { _, _, _, _ in
                    sheetHold.dispose()
                }
            }
            presentNativeControllerImpl?(activityController)
        })
    }

    func send(_ id: String, privacy: SGCallRecordingPrivacy) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        presentControllerImpl?(textAlertController(context: context, title: i18n("CallRecording.SendToSaved.Confirm.Title", lang), text: i18n("CallRecording.SendToSaved.Confirm.Text", lang), actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: i18n("CallRecording.SendToSaved.Confirm.Send", lang), action: {
                authorize(privacy, {
                    guard sgCallRecordingAvailable, currentItem(id, privacy: privacy) != nil else {
                        refreshPromise.set(true)
                        return
                    }
                    // `authorize` runs this only after `requireUnlock` returned `.unlocked` for exactly
                    // this pair, so that is the only place a grant is ever made. The delivery rejects a
                    // grant for any other pair, uses a neutral caption and file name for a protected
                    // recording, and refuses one whose identity cannot be verified.
                    var grant: SGCallRecordingExportGrant?
                    if case let .protected(accountPeerId, peerId) = privacy {
                        grant = SGCallRecordingExportGrant(accountPeerId: accountPeerId, peerId: peerId)
                    }
                    // Every outcome that queued nothing is said out loud, never a silent no-op.
                    switch SGCallRecordingDelivery.shared.sendManually(context: context, id: id, grant: grant) {
                    case .queued, .alreadyInProgress:
                        break
                    case .accountUnavailable:
                        alert(i18n("CallRecording.SendToSaved.Confirm.Title", lang), i18n("CallRecording.SendToSaved.AccountUnavailable", lang))
                    case .refused:
                        alert(i18n("CallRecording.SendToSaved.Confirm.Title", lang), i18n("CallRecording.SendToSaved.Refused", lang))
                    case .requiresAuthorization, .failed:
                        alert(i18n("CallRecording.SendToSaved.Confirm.Title", lang), i18n("CallRecording.SendToSaved.NotQueued", lang))
                    }
                    refreshPromise.set(true)
                })
            })
        ]), nil)
    }

    func delete(_ id: String) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        // The alert has to say that the queued upload goes too — read NOW, not when the sheet opened.
        // Only `.waiting` is "waiting to be sent": a FAILED send is not waiting for anything.
        let isSending = SGCallRecordingStore.shared.item(id: id).map { SGCallRecordingDelivery.shared.status(item: $0) } == .waiting
        let deleteText = isSending ? i18n("CallRecording.Delete.Text.Sending", lang) : i18n("CallRecording.Delete.Text", lang)
        presentControllerImpl?(textAlertController(context: context, title: i18n("CallRecording.Delete.Title", lang), text: deleteText, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: i18n("CallRecording.Delete", lang), action: {
                if SGCallRecordingPlayer.shared.isPlaying(id: id) {
                    stopPlayback()
                }
                // CANCEL BEFORE UNLINKING, AND ONLY DELETE IF THE CANCEL SUCCEEDED. One that is NOT
                // cancelled would deliver to Saved Messages a recording the user just deleted. When
                // the upload cannot be cancelled right now the recording is kept and the user is told
                // — keeping the audio is always the safe side, and they can simply try again.
                guard SGCallRecordingDelivery.shared.cancelSend(id: id) else {
                    alert(i18n("CallRecording.Delete.Title", lang), i18n("CallRecording.Delete.CancelFailed", lang))
                    refreshPromise.set(true)
                    return
                }
                // `delete` reports success only when nothing can bring the recording back — the files
                // are gone, or (for the call being recorded) a durable tombstone is on disk.
                if !SGCallRecordingStore.shared.delete(id: id) {
                    alert(i18n("CallRecording.Delete.Title", lang), i18n("CallRecording.Delete.Failed", lang))
                }
                refreshPromise.set(true)
            })
        ]), nil)
    }

    let arguments = SGCallRecordingsArguments(openItem: { listedItem in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        // Everything is decided from the recording as it is NOW, not as it was when the row was built.
        let id = listedItem.id
        guard let item = SGCallRecordingStore.shared.item(id: id) else {
            refreshPromise.set(true)
            return
        }
        let privacy = sgCallRecordingPrivacy(item)
        let isLive = SGCallRecordingStore.shared.isActive(id: id)
        let sendStatus = SGCallRecordingDelivery.shared.status(item: item)
        let presentation = sgCallRecordingPresentation(item, privacy: privacy, playingId: SGCallRecordingPlayer.shared.currentIdValue, activeId: isLive ? id : nil)

        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []

        if isLive {
            items.append(ActionSheetTextItem(title: i18n("CallRecording.Live.Text", lang)))
        } else if privacy == .unverifiable {
            items.append(ActionSheetTextItem(title: i18n("CallRecording.Protected.Unverifiable.Text", lang)))
        }

        if SGCallRecordingPlayer.shared.isPlaying(id: id) {
            items.append(ActionSheetButtonItem(title: i18n("CallRecording.Stop", lang), color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                stopPlayback()
                refreshPromise.set(true)
            }))
        } else if presentation.canPlay {
            items.append(ActionSheetButtonItem(title: i18n("CallRecording.Play", lang), color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                play(id, privacy: privacy)
            }))
        }

        if presentation.canShare {
            items.append(ActionSheetButtonItem(title: i18n("CallRecording.Share", lang), color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                share(id, privacy: privacy)
            }))
        }

        // MARK: Zenlygram — Saved Messages, on this explicit tap, whether or not the automatic
        // setting is on. Offered only when nothing is already on its way for this recording (a
        // second tap would put a second copy in the chat), when the recording's own account is
        // signed in, and never for the call being recorded right now.
        //
        // A PRE-MIX PAIR IS SENT AS TWO MESSAGES, not refused and not mixed, and NEITHER file is
        // deleted until BOTH messages have been acknowledged (see SGCallRecordingDelivery).
        if presentation.canSend && SGCallRecordingDelivery.shared.canSendManually(item: item, tappedOn: context) {
            let sendTitle = sendStatus == .failed ? i18n("CallRecording.SendToSaved.Again", lang) : i18n("CallRecording.SendToSaved", lang)
            items.append(ActionSheetButtonItem(title: sendTitle, color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                send(id, privacy: privacy)
            }))
        }

        items.append(ActionSheetButtonItem(title: i18n("CallRecording.Delete", lang), color: .destructive, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            delete(id)
        }))

        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet, nil)
    }, openManagementOnly: { id in
        // A recording that cannot be opened or shown: nothing about it is read or displayed, and the
        // only thing offered is to delete it (the same cancel-first path as any other row).
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: i18n("CallRecording.Damaged.Text", lang)),
                ActionSheetButtonItem(title: i18n("CallRecording.Delete", lang), color: .destructive, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    delete(id)
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet, nil)
    }, deleteAll: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        let hasPendingSends = !SGCallRecordingStore.shared.pendingSends().isEmpty
        let text = hasPendingSends ? i18n("CallRecording.DeleteAll.Text.Sending", lang) : i18n("CallRecording.DeleteAll.Text", lang)
        presentControllerImpl?(textAlertController(context: context, title: i18n("CallRecording.DeleteAll.Title", lang), text: text, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: i18n("CallRecording.List.DeleteAll", lang), action: {
                stopPlayback()
                // Same order as the per-row delete, and for the same reason. If even one upload could
                // not be cancelled, nothing is deleted: a partial wipe here would be the worst of
                // both outcomes — some recordings gone, one still on its way to Saved Messages.
                guard SGCallRecordingDelivery.shared.cancelAllSends() else {
                    alert(i18n("CallRecording.DeleteAll.Title", lang), i18n("CallRecording.DeleteAll.CancelFailed", lang))
                    refreshPromise.set(true)
                    return
                }
                // Anything short of `.completed` is a wipe that has not finished; the copy asks the
                // user to unlock and try again rather than promising anything about later.
                if SGCallRecordingStore.shared.deleteAll() != .completed {
                    alert(i18n("CallRecording.DeleteAll.Title", lang), i18n("CallRecording.DeleteAll.Failed", lang))
                }
                refreshPromise.set(true)
            })
        ]), nil)
    })

    // Read, never written: whether iOS Call Integration is switched on decides what the empty list
    // tells the user (the call screen refuses to record without it). Changing it stays the user's
    // choice in Privacy & Security ▸ Calls.
    let isCallKitEnabled = context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.voiceCallSettings])
    |> map { sharedData -> Bool in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.voiceCallSettings]?.get(VoiceCallSettings.self) ?? .defaultSettings
        return settings.enableSystemIntegration
    }
    |> distinctUntilChanged

    // `stateVersion` replays on subscription (it is a promise, not a pipe), so the list renders at
    // once and then re-renders whenever a delivery moves — including from the automatic path, which
    // can queue a recording while this screen is open behind a minimised call. The live recording id
    // re-renders the row the moment the call it belongs to stops recording.
    let signal = combineLatest(context.sharedContext.presentationData, refreshPromise.get(), SGCallRecordingPlayer.shared.currentId, SGCallRecordingDelivery.shared.stateVersion, SGCallRecordingStore.shared.activeRecordingIdSignal, isCallKitEnabled)
    // `deliverOnMainQueue` BEFORE the map, not after. The map calls
    // `SGCallRecordingDelivery.status(item:)`, which reads a dictionary that is only ever written on
    // the main queue, and `presentationData` is delivered on the shared-data queue. It also moves
    // `list()`'s directory scan and its housekeeping off the shared-data queue.
    |> deliverOnMainQueue
    |> map { presentationData, _, playingId, _, activeId, isCallKitEnabled -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let startSupport = SGCallRecordingStartSupport(isFeatureAvailable: sgCallRecordingAvailable, isCallKitAvailable: CallKitIntegration.isAvailable, isCallKitEnabled: isCallKitEnabled)
        let items = SGCallRecordingStore.shared.list()
        let managementOnlyIds = SGCallRecordingStore.shared.managementOnlyRecordingIds()
        let hasAnyFiles = items.isEmpty && managementOnlyIds.isEmpty && SGCallRecordingStore.shared.hasAnyFiles()

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(i18n("CallRecording.List.Title", lang)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: sgCallRecordingsEntries(items: items, managementOnlyIds: managementOnlyIds, hasAnyFiles: hasAnyFiles, playingId: playingId, activeId: activeId, startSupport: startSupport, lang: lang),
            style: .blocks
        )
        return (controllerState, (listState, arguments))
    }

    // Opening this screen is one of the moments the app is certainly in the foreground with the
    // device unlocked, which is exactly what a delivery blocked on an unreadable (`.complete`) file
    // is waiting for. This screen starts no new export while recording is unavailable; the delivery
    // module itself decides what an earlier build already queued.
    if sgCallRecordingAvailable {
        SGCallRecordingDelivery.shared.resumeAll()
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    presentNativeControllerImpl = { [weak controller] c in
        controller?.view.window?.rootViewController?.present(c, animated: true)
    }
    getSourceViewImpl = { [weak controller] in
        return controller?.view
    }
    getHostImpl = { [weak controller] in
        return controller
    }
    isOnScreenImpl = { [weak controller] in
        guard let controller = controller, controller.isViewLoaded else {
            return false
        }
        return controller.view.window != nil
    }
    // Leaving the screen stops playback: there is no Stop button anywhere else, and a recording
    // left playing behind the user's back (or in the background) is exactly the surprise to avoid.
    controller.didDisappear = { _ in
        ongoingCallDisposable.set(nil)
        stopPlayback()
        refreshPromise.set(true)
    }
    // Zenlygram — analytics `screen.view calls.recordings` (design 40 §10.2), owned by this screen's
    // account; a no-op without the sink or the account's `recordEvents` clearance.
    let screenAccountPeerId = context.account.peerId.toInt64()
    controller.didAppear = { _ in
        SGAnalytics.screen(.callsRecordings, accountPeerId: screenAccountPeerId)
    }
    return controller
}
