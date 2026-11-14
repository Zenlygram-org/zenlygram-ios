import SGAppGroupIdentifier
import SGProtectedStore
import Foundation
import UIKit
import CallKit
import Intents
import AVFoundation
import TelegramCore
import SwiftSignalKit
import AppBundle
import AccountContext
import TelegramAudio
import TelegramVoip

private let sharedProviderDelegate: CallKitProviderDelegate? = {
    return CallKitProviderDelegate()
}()

public final class CallKitIntegration {
    public static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
            return Locale.current.regionCode?.lowercased() != "cn" && !(UserDefaults(suiteName: sgAppGroupIdentifier())?.bool(forKey: "legacyNotificationsFix") ?? false)
        } else {
            return false
        }
        #endif
    }
    
    private let audioSessionActivePromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    var audioSessionActive: Signal<Bool, NoError> {
        return self.audioSessionActivePromise.get()
    }
    
    private let hasActiveCallsValue = ValuePromise<Bool>(false, ignoreRepeated: true)
    public var hasActiveCalls: Signal<Bool, NoError> {
        return self.hasActiveCallsValue.get()
    }

    private static let sharedInstance: CallKitIntegration? = CallKitIntegration()
    public static var shared: CallKitIntegration? {
        return self.sharedInstance
    }

    func setup(
        startCall: @escaping (AccountContext, UUID, EnginePeer.Id?, String, Bool) -> Signal<Bool, NoError>,
        answerCall: @escaping (UUID) -> Void,
        endCall: @escaping (UUID) -> Signal<Bool, NoError>,
        setCallMuted: @escaping (UUID, Bool) -> Void,
        audioSessionActivationChanged: @escaping (Bool) -> Void
    ) {
        sharedProviderDelegate?.setup(audioSessionActivePromise: self.audioSessionActivePromise, startCall: startCall, answerCall: answerCall, endCall: endCall, setCallMuted: setCallMuted, audioSessionActivationChanged: audioSessionActivationChanged, hasActiveCallsValue: hasActiveCallsValue)
    }
    
    private init?() {
        if !CallKitIntegration.isAvailable {
            return nil
        }
    }
    
    func startCall(context: AccountContext, peerId: EnginePeer.Id, phoneNumber: String?, localContactId: String?, isVideo: Bool, displayTitle: String) {
        sharedProviderDelegate?.startCall(context: context, peerId: peerId, phoneNumber: phoneNumber, isVideo: isVideo, displayTitle: displayTitle)
        self.donateIntent(peerId: peerId, displayTitle: displayTitle, localContactId: localContactId)
    }
    
    func answerCall(uuid: UUID) {
        #if DEBUG
        print("CallKitIntegration: Answer call \(uuid)")
        #endif
        sharedProviderDelegate?.answerCall(uuid: uuid)
    }
    
    public func dropCall(uuid: UUID) {
        #if DEBUG
        print("CallKitIntegration: Drop call \(uuid)")
        #endif
        sharedProviderDelegate?.dropCall(uuid: uuid)
    }
    
    public func reportIncomingCall(uuid: UUID, stableId: Int64, handle: String, phoneNumber: String?, isVideo: Bool, displayTitle: String, completion: ((NSError?) -> Void)?) {
        #if DEBUG
        print("CallKitIntegration: Report incoming call \(uuid)")
        #endif
        sharedProviderDelegate?.reportIncomingCall(uuid: uuid, stableId: stableId, handle: handle, phoneNumber: phoneNumber, isVideo: isVideo, displayTitle: displayTitle, completion: completion)
    }
    
    func reportOutgoingCallConnected(uuid: UUID, at date: Date) {
        sharedProviderDelegate?.reportOutgoingCallConnected(uuid: uuid, at: date)
    }
    
    private func donateIntent(peerId: EnginePeer.Id, displayTitle: String, localContactId: String?) {
        // SG: Secret Vault / Chat Lock — never donate a call to a chat that is vaulted in any account or Chat-Locked
        // (Siri suggestions, Contacts' "recent" row); nothing while that state is unreadable (#16).
        switch SGProtectedStore.shared.deviceProtection(peerId: peerId.toInt64()) {
        case .none:
            break
        case .locked, .vaulted, .unknown:
            return
        }
        let handle = INPersonHandle(value: "tg\(peerId.id._internalGetInt64Value())", type: .unknown)
        let contact = INPerson(personHandle: handle, nameComponents: nil, displayName: displayTitle, image: nil, contactIdentifier: localContactId, customIdentifier: "tg\(peerId.id._internalGetInt64Value())")
    
        let intent: INStartCallIntent
        if #available(iOS 14.0, *) {
            // This donation names a contact, not a specific recent call to redial.
            intent = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown, destinationType: .normal, contacts: [contact], callCapability: .audioCall)
        } else {
            intent = INStartCallIntent(audioRoute: .unknown, destinationType: .normal, contacts: [contact], recordTypeForRedialing: .unknown, callCapability: .audioCall)
        }
        
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        // SG: Secret Vault — same group as the chat donations (TelegramIntents), so deleteSendMessageIntents(peerId:),
        // run when the contact is vaulted or Chat-Locked, also removes the call donations made before that.
        interaction.groupIdentifier = "sendMessage_\(peerId.toInt64())"
        interaction.donate { _ in
        }
    }
    
    public func applyVoiceChatOutputMode(outputMode: AudioSessionOutputMode) {
        sharedProviderDelegate?.applyVoiceChatOutputMode(outputMode: outputMode)
    }
    
    public func updateCallIsConference(uuid: UUID, title: String) {
        sharedProviderDelegate?.updateCallIsConference(uuid: uuid, title: title)
    }

    // SG: Zenlygram — local call recording.
    //
    // While the app is backgrounded it cannot draw anything of its own: there is no ActivityKit /
    // Live Activity anywhere in this app and no widget extension that could host one, so the only
    // app-controlled surface left is CallKit's own call card. Marking `localizedCallerName` puts the
    // indicator on the system call banner and the lock screen, which is the honest maximum there.
    // The in-app indicators (call screen, minimised call bar) cover the foreground.
    // `recordingMarker` is the already-localized word for "recording" (SGStrings
    // `CallRecording.Indicator.Short`), resolved by the caller. It is passed in rather than
    // composed here because this module has no presentation data of its own, and the lock screen
    // is the one surface where the clarity of the indication is doing all the work — it must not
    // be the only English string in a Russian or Uzbek build.
    public func updateCallRecordingIndicator(uuid: UUID, displayTitle: String, recordingMarker: String, isRecording: Bool) {
        sharedProviderDelegate?.updateCallRecordingIndicator(uuid: uuid, displayTitle: displayTitle, recordingMarker: recordingMarker, isRecording: isRecording)
    }
}

@available(iOSApplicationExtension 10.0, iOS 10.0, *)
class CallKitProviderDelegate: NSObject, CXProviderDelegate {
    private let provider: CXProvider
    private let callController = CXCallController()
    
    private var currentStartCallAccount: (UUID, AccountContext)?

    private var alreadyReportedIncomingCalls = Set<UUID>()
    private var uuidToPeerIdMapping: [UUID: EnginePeer.Id] = [:]
    
    private var startCall: ((AccountContext, UUID, EnginePeer.Id?, String, Bool) -> Signal<Bool, NoError>)?
    private var answerCall: ((UUID) -> Void)?
    private var endCall: ((UUID) -> Signal<Bool, NoError>)?
    private var setCallMuted: ((UUID, Bool) -> Void)?
    private var audioSessionActivationChanged: ((Bool) -> Void)?
    private var hasActiveCallsValue: ValuePromise<Bool>?
    
    private var isAudioSessionActive: Bool = false
    private var pendingVoiceChatOutputMode: AudioSessionOutputMode?
    
    private let disposableSet = DisposableSet()
    
    fileprivate var audioSessionActivePromise: ValuePromise<Bool>?
    
    private var activeCalls = Set<UUID>() {
        didSet {
            self.hasActiveCallsValue?.set(!self.activeCalls.isEmpty)
        }
    }
    
    // SG: Secret Vault — observers that keep includesCallsInRecents in step with the vault state.
    private var sgVaultObservers: [NSObjectProtocol] = []

    // SG: Zenlygram — call recording. The name each call was reported to CallKit with, and the
    // calls whose name currently carries the recording marker. The marker is undone from the
    // remembered name — never from whatever the caller happens to pass, which is empty for an
    // outgoing call whose peer has not been resolved yet (audit #11) — and it is undone before the
    // call is reported ended on every path this delegate sees, so the ended call does not carry
    // "● REC" into the Phone app's Recents (audit #60).
    private var sgReportedCallerNames: [UUID: String] = [:]
    private var sgRecordingMarkedCalls = Set<UUID>()
    
    override init() {
        self.provider = CXProvider(configuration: CallKitProviderDelegate.providerConfiguration())
        
        super.init()
        
        self.provider.setDelegate(self, queue: nil)
        
        // SG: Secret Vault — re-apply the configuration when the vault is turned on / off, its PIN is set / removed or
        // the shared state changes, so includesCallsInRecents follows it without a relaunch. By name
        // ("FenixSecretVaultChanged" == Notification.Name.fenixSecretVaultChanged in SGSecretVault) to keep this
        // module free of an SGSecretVault dependency.
        let center = NotificationCenter.default
        for name in [SGProtectedStore.didChangeNotification, Notification.Name("FenixSecretVaultChanged")] {
            self.sgVaultObservers.append(center.addObserver(forName: name, object: nil, queue: .main, using: { [weak self] _ in
                self?.sgUpdateIncludesCallsInRecents()
            }))
        }
    }
    
    deinit {
        for observer in self.sgVaultObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // SG: Secret Vault — replaces the provider configuration only when the Recents flag no longer matches the vault.
    private func sgUpdateIncludesCallsInRecents() {
        if self.provider.configuration.includesCallsInRecents != !SGProtectedStore.shared.isVaultActive {
            self.provider.configuration = CallKitProviderDelegate.providerConfiguration()
        }
    }
    
    func setup(audioSessionActivePromise: ValuePromise<Bool>, startCall: @escaping (AccountContext, UUID, EnginePeer.Id?, String, Bool) -> Signal<Bool, NoError>, answerCall: @escaping (UUID) -> Void, endCall: @escaping (UUID) -> Signal<Bool, NoError>, setCallMuted: @escaping (UUID, Bool) -> Void, audioSessionActivationChanged: @escaping (Bool) -> Void, hasActiveCallsValue: ValuePromise<Bool>) {
        self.audioSessionActivePromise = audioSessionActivePromise
        self.startCall = startCall
        self.answerCall = answerCall
        self.endCall = endCall
        self.setCallMuted = setCallMuted
        self.audioSessionActivationChanged = audioSessionActivationChanged
        self.hasActiveCallsValue = hasActiveCallsValue
    }
    
    private static func providerConfiguration() -> CXProviderConfiguration {
        // MARK: Swiftgram
        let providerConfiguration: CXProviderConfiguration
        if #available(iOS 14.0, *) {
            // iOS 14 no longer supports a custom provider name. The app's bundle name and display
            // name are already Zenlygram, so the system's app identity retains the branding.
            providerConfiguration = CXProviderConfiguration()
        } else {
            providerConfiguration = CXProviderConfiguration(localizedName: "Zenlygram")
        }
        
        providerConfiguration.supportsVideo = true
        providerConfiguration.maximumCallsPerCallGroup = 1
        providerConfiguration.maximumCallGroups = 1
        providerConfiguration.supportedHandleTypes = [.phoneNumber, .generic]
        // SG: Secret Vault (D5) — while the vault is in use, no call is written to the Phone app's Recents, where a
        // call with a vault contact would show outside the vault. Tracks the vault state live: the provider's
        // configuration is rebuilt whenever this flag no longer matches it (sgUpdateIncludesCallsInRecents). Entries
        // already in Recents cannot be removed.
        providerConfiguration.includesCallsInRecents = !SGProtectedStore.shared.isVaultActive
        if let image = UIImage(named: "Call/CallKitLogo", in: getAppBundle(), compatibleWith: nil) {
            providerConfiguration.iconTemplateImageData = image.pngData()
        }
        
        return providerConfiguration
    }
    
    private func requestTransaction(_ transaction: CXTransaction, completion: ((Bool) -> Void)? = nil) {
        Logger.shared.log("CallKitIntegration", "requestTransaction \(transaction)")
        self.callController.request(transaction) { error in
            if let error = error {
                Logger.shared.log("CallKitIntegration", "error in requestTransaction \(transaction): \(error)")
            }
            completion?(error == nil)
        }
    }
    
    func endCall(uuid: UUID) {
        Logger.shared.log("CallKitIntegration", "endCall \(uuid)")
        
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)
        self.requestTransaction(transaction)
        
        self.activeCalls.remove(uuid)
    }
    
    func dropCall(uuid: UUID) {
        self.alreadyReportedIncomingCalls.insert(uuid)
        
        Logger.shared.log("CallKitIntegration", "report call ended \(uuid)")
        
        self.sgRestoreCallerNameBeforeEnd(uuid: uuid)
        self.provider.reportCall(with: uuid, endedAt: nil, reason: CXCallEndedReason.remoteEnded)
        
        self.activeCalls.remove(uuid)
    }
    
    func answerCall(uuid: UUID) {
        Logger.shared.log("CallKitIntegration", "answer call \(uuid)")
        
        let answerCallAction = CXAnswerCallAction(call: uuid)
        let transaction = CXTransaction(action: answerCallAction)
        self.requestTransaction(transaction)
    }
    
    func startCall(context: AccountContext, peerId: EnginePeer.Id, phoneNumber: String?, isVideo: Bool, displayTitle: String) {
        let uuid = UUID()
        self.currentStartCallAccount = (uuid, context)
        let handle: CXHandle
        if let phoneNumber = phoneNumber {
            handle = CXHandle(type: .phoneNumber, value: phoneNumber)
        } else {
            handle = CXHandle(type: .generic, value: "\(peerId.id._internalGetInt64Value())")
        }
        
        self.uuidToPeerIdMapping[uuid] = peerId
        self.sgReportedCallerNames[uuid] = displayTitle
        
        let startCallAction = CXStartCallAction(call: uuid, handle: handle)
        startCallAction.contactIdentifier = displayTitle

        startCallAction.isVideo = isVideo
        let transaction = CXTransaction(action: startCallAction)
        
        Logger.shared.log("CallKitIntegration", "initiate call \(uuid)")
        
        self.requestTransaction(transaction, completion: { _ in
            let update = CXCallUpdate()
            update.remoteHandle = handle
            update.localizedCallerName = displayTitle
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            
            self.provider.reportCall(with: uuid, updated: update)
            
            self.activeCalls.insert(uuid)
        })
    }
    
    func reportIncomingCall(uuid: UUID, stableId: Int64, handle: String, phoneNumber: String?, isVideo: Bool, displayTitle: String, completion: ((NSError?) -> Void)?) {
        if self.alreadyReportedIncomingCalls.contains(uuid) {
            completion?(nil)
            return
        }
        self.alreadyReportedIncomingCalls.insert(uuid)
        self.sgReportedCallerNames[uuid] = displayTitle

        let update = CXCallUpdate()
        let nativeHandle: CXHandle
        if let phoneNumber = phoneNumber {
            nativeHandle = CXHandle(type: .phoneNumber, value: phoneNumber)
        } else {
            nativeHandle = CXHandle(type: .generic, value: handle)
        }
        update.remoteHandle = nativeHandle
        update.localizedCallerName = displayTitle
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        update.hasVideo = isVideo
        
        Logger.shared.log("CallKitIntegration", "report incoming call \(uuid)")
        
        OngoingCallContext.setupAudioSession()
        
        self.provider.reportNewIncomingCall(with: uuid, update: update, completion: { error in
            if error == nil {
                self.activeCalls.insert(uuid)
            }
            
            completion?(error as NSError?)
        })
    }
    
    func reportOutgoingCallConnecting(uuid: UUID, at date: Date) {
        Logger.shared.log("CallKitIntegration", "report outgoing call connecting \(uuid)")
        
        self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: date)
    }
    
    func reportOutgoingCallConnected(uuid: UUID, at date: Date) {
        Logger.shared.log("CallKitIntegration", "report call connected \(uuid)")
        
        self.provider.reportOutgoingCall(with: uuid, connectedAt: date)
    }
    
    func updateCallIsConference(uuid: UUID, title: String) {
        let update = CXCallUpdate()
        let handle = CXHandle(type: .generic, value: "\(uuid)")
        update.remoteHandle = handle
        update.localizedCallerName = title
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        self.provider.reportCall(with: uuid, updated: update)
        // The conference title replaced the name, marker included; the card is the conference's now.
        self.sgReportedCallerNames[uuid] = title
        self.sgRecordingMarkedCalls.remove(uuid)
    }

    // SG: Zenlygram — see CallKitIntegration.updateCallRecordingIndicator.
    func updateCallRecordingIndicator(uuid: UUID, displayTitle: String, recordingMarker: String, isRecording: Bool) {
        if !isRecording {
            // Nothing to undo (never marked, or the call already ended / became a conference and
            // the name was put back then).
            guard self.sgRecordingMarkedCalls.contains(uuid) else {
                return
            }
            self.sgRecordingMarkedCalls.remove(uuid)
            self.sgReportCallerName(uuid: uuid, name: self.sgOriginalCallerName(uuid: uuid, fallback: displayTitle))
            return
        }
        // Only the glyphs are composed here; the word itself arrives localized from the caller
        // so this reads the same as the in-app badge (en "REC" / ru "ЗАПИСЬ" / uz "YOZUV").
        // The dot leads so the marker survives even when the system truncates a long name.
        var marker = "\u{25CF}"
        if !recordingMarker.isEmpty {
            marker += " \(recordingMarker)"
        }
        let name = self.sgOriginalCallerName(uuid: uuid, fallback: displayTitle)
        self.sgRecordingMarkedCalls.insert(uuid)
        self.sgReportCallerName(uuid: uuid, name: name.isEmpty ? marker : "\(marker) \u{00B7} \(name)")
    }

    private func sgOriginalCallerName(uuid: UUID, fallback: String) -> String {
        if let name = self.sgReportedCallerNames[uuid], !name.isEmpty {
            return name
        }
        return fallback
    }

    /// Only the caller name is touched: every other field is left nil so CallKit keeps whatever
    /// the call was reported with.
    private func sgReportCallerName(uuid: UUID, name: String) {
        let update = CXCallUpdate()
        update.localizedCallerName = name
        self.provider.reportCall(with: uuid, updated: update)
    }

    /// Puts the reported name back while the call is still live, then forgets the call.
    private func sgRestoreCallerNameBeforeEnd(uuid: UUID) {
        if self.sgRecordingMarkedCalls.contains(uuid) {
            self.sgRecordingMarkedCalls.remove(uuid)
            self.sgReportCallerName(uuid: uuid, name: self.sgOriginalCallerName(uuid: uuid, fallback: ""))
        }
        self.sgReportedCallerNames.removeValue(forKey: uuid)
    }
    
    func providerDidReset(_ provider: CXProvider) {
        Logger.shared.log("CallKitIntegration", "providerDidReset")
        
        self.activeCalls.removeAll()
        self.sgReportedCallerNames.removeAll()
        self.sgRecordingMarkedCalls.removeAll()
    }
    
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Logger.shared.log("CallKitIntegration", "provider perform start call action \(action)")
        
        guard let startCall = self.startCall, let (uuid, context) = self.currentStartCallAccount, uuid == action.callUUID else {
            action.fail()
            return
        }
        self.currentStartCallAccount = nil
        let disposable = MetaDisposable()
        self.disposableSet.add(disposable)
        
        let peerId = self.uuidToPeerIdMapping[action.callUUID]
        
        disposable.set((startCall(context, action.callUUID, peerId, action.handle.value, action.isVideo)
        |> deliverOnMainQueue
        |> afterDisposed { [weak self, weak disposable] in
            if let strongSelf = self, let disposable = disposable {
                strongSelf.disposableSet.remove(disposable)
            }
        }).start(next: { result in
            if result {
                action.fulfill()
            } else {
                action.fail()
            }
        }))
    }
    
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Logger.shared.log("CallKitIntegration", "provider perform answer call action \(action)")
        
        guard let answerCall = self.answerCall else {
            action.fail()
            return
        }
        answerCall(action.callUUID)
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Logger.shared.log("CallKitIntegration", "provider perform end call action \(action)")
        
        guard let endCall = self.endCall else {
            action.fail()
            return
        }
        // SG: Zenlygram — the end may come from the system UI (lock screen, Dynamic Island), before
        // the app knows: undo the recording marker while the call is still live (audit #60).
        self.sgRestoreCallerNameBeforeEnd(uuid: action.callUUID)
        let disposable = MetaDisposable()
        self.disposableSet.add(disposable)
        disposable.set((endCall(action.callUUID)
        |> deliverOnMainQueue
        |> afterDisposed { [weak self, weak disposable] in
            if let strongSelf = self, let disposable = disposable {
                strongSelf.disposableSet.remove(disposable)
            }
        }).start(next: { result in
            if result {
                action.fulfill(withDateEnded: Date())
            } else {
                action.fail()
            }
        }))
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Logger.shared.log("CallKitIntegration", "provider perform mute call action \(action)")
        
        guard let setCallMuted = self.setCallMuted else {
            action.fail()
            return
        }
        setCallMuted(action.uuid, action.isMuted)
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Logger.shared.log("CallKitIntegration", "provider didActivate audio session")
        self.isAudioSessionActive = true
        self.audioSessionActivationChanged?(true)
        self.audioSessionActivePromise?.set(true)
        
        if let outputMode = self.pendingVoiceChatOutputMode {
            self.pendingVoiceChatOutputMode = nil
            sharedManagedAudioSession?.applyVoiceChatOutputModeInCurrentAudioSession(outputMode: outputMode)
        }
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Logger.shared.log("CallKitIntegration", "provider didDeactivate audio session")
        self.isAudioSessionActive = false
        self.audioSessionActivationChanged?(false)
        self.audioSessionActivePromise?.set(false)
    }
    
    func applyVoiceChatOutputMode(outputMode: AudioSessionOutputMode) {
        if self.isAudioSessionActive {
            sharedManagedAudioSession?.applyVoiceChatOutputModeInCurrentAudioSession(outputMode: outputMode)
        } else {
            self.pendingVoiceChatOutputMode = outputMode
        }
    }
}
