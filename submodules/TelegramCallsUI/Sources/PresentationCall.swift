// MARK: Swiftgram
import SGCallRecording
import SGCallRecordingDelivery
import SGStrings

import Foundation
import UIKit
import TelegramCore
import SwiftSignalKit
import Display
import AVFoundation
import TelegramVoip
import TelegramAudio
import TelegramUIPreferences
import TelegramPresentationData
import DeviceAccess
import UniversalMediaPlayer
import AccountContext
import DeviceProximity
import PhoneNumberFormat
import PresentationDataUtils

// Zenlygram — how long the optional "I am recording" notice is followed before the user is told it
// is still unconfirmed (audit #117). Long enough for an upload over a poor mobile link to finish.
private let sgCallRecordingNoticeObservationTimeout: Double = 120.0

/// The alert text for a recording outcome. One mapping, shared by the call screen and the
/// main-window fallback below.
func sgCallRecordingOutcomeText(_ outcome: SGCallRecordingOutcome, lang: String) -> String {
    switch outcome {
    case .lost:
        return i18n("CallRecording.Problem.Lost", lang)
    case .truncated:
        return i18n("CallRecording.Problem.Truncated", lang)
    case .noSpace:
        return i18n("CallRecording.Problem.NoSpace", lang)
    case .noticeNotDelivered:
        return i18n("CallRecording.Problem.NoticeNotSent", lang)
    case .noticeUnconfirmed:
        return i18n("CallRecording.Problem.NoticeUnconfirmed", lang)
    case .cannotStartCleanupPending:
        return i18n("CallRecording.Problem.CleanupPending", lang)
    }
}

/// For an outcome that arrives once the call screen is gone or going (the call ended, became a
/// conference, or the call object was released): the main window outlives all of those.
private func sgPresentCallRecordingOutcomeInMainWindow(sharedContext: SharedAccountContext, outcome: SGCallRecordingOutcome) {
    guard let mainWindow = sharedContext.mainWindow else {
        return
    }
    let presentationData = sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode
    let controller = textAlertController(sharedContext: sharedContext, title: i18n("CallRecording.Problem.Title", lang), text: sgCallRecordingOutcomeText(outcome, lang: lang), actions: [
        TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
    ])
    mainWindow.present(controller, on: .root)
}

public final class PresentationCallImpl: PresentationCall {
    public let context: AccountContext
    private let audioSession: ManagedAudioSession
    private let callSessionManager: CallSessionManager
    private let callKitIntegration: CallKitIntegration?
    public var isIntegratedWithCallKit: Bool {
        return self.callKitIntegration != nil
    }
    
    private let getDeviceAccessData: () -> (presentationData: PresentationData, present: (ViewController, Any?) -> Void, openSettings: () -> Void)
    
    public let internalId: CallSessionInternalId
    public let peerId: EnginePeer.Id
    public let isOutgoing: Bool
    private let incomingConferenceSource: EngineMessage.Id?
    private let conferenceStableId: Int64?
    private var conferenceTitle: String?
    public var isVideo: Bool
    public var isVideoPossible: Bool
    private let enableStunMarking: Bool
    private let enableTCP: Bool
    public let preferredVideoCodec: String?
    public let peer: EnginePeer?
    
    private let serializedData: String?
    private let dataSaving: VoiceCallDataSaving
    private let proxyServer: ProxyServerSettings?
    private let auxiliaryServers: [OngoingCallContext.AuxiliaryServer]
    private let currentNetworkType: NetworkType
    private let updatedNetworkType: Signal<NetworkType, NoError>
    
    public private(set) var sharedAudioContext: SharedCallAudioContext?
    
    private var sessionState: CallSession?
    private var callContextState: OngoingCallContextState?
    private var ongoingContext: OngoingCallContext?
    private var conferenceCallContext: PresentationGroupCallImpl?
    private var ongoingContextStateDisposable: Disposable?
    private var ongoingContextIsFailedDisposable: Disposable?
    private var ongoingContextIsDroppedDisposable: Disposable?
    private var didDropCall = false
    private var requestedVideoAspect: Float?
    private var reception: Int32?
    private var receptionDisposable: Disposable?
    private var audioLevelDisposable: Disposable?
    private var reportedIncomingCall = false
    
    private var batteryLevelDisposable: Disposable?
    
    private var callWasActive = false
    private var shouldPresentCallRating = false

    private var supportsConferenceCalls: Bool = false
    
    private var previousVideoState: PresentationCallState.VideoState?
    private var previousRemoteVideoState: PresentationCallState.RemoteVideoState?
    private var previousRemoteAudioState: PresentationCallState.RemoteAudioState?
    private var previousRemoteBatteryLevel: PresentationCallState.RemoteBatteryLevel?
    
    private var sessionStateDisposable: Disposable?
    
    private let statePromise = ValuePromise<PresentationCallState>()
    public var state: Signal<PresentationCallState, NoError> {
        return self.statePromise.get()
    }
    
    private let audioLevelPromise = ValuePromise<Float>(0.0)
    public var audioLevel: Signal<Float, NoError> {
        return self.audioLevelPromise.get()
    }
    
    private let isMutedPromise = ValuePromise<Bool>(false)
    private var isMutedValue = false
    public var isMuted: Signal<Bool, NoError> {
        return self.isMutedPromise.get()
    }

    // MARK: Zenlygram — local call recording. See `startRecording()` below for the gates.
    private var callRecordingSession: SGCallRecordingSession?
    private var callRecordingStateDisposable: Disposable?
    private let isRecordingPromise = ValuePromise<Bool>(false)
    public private(set) var isRecordingValue: Bool = false
    public var isRecording: Signal<Bool, NoError> {
        return self.isRecordingPromise.get()
    }
    // Zenlygram — a recording that ends badly has to reach a screen. `.failed` used to be folded
    // into the same branch as `.idle` (both just cleared the indicator), so a recording deleted for
    // lack of space, or cut short by a write error, was indistinguishable from a clean stop: the
    // user watched the badge for the whole call and then found nothing, with no explanation
    // anywhere. This pipe carries the outcome to the call screen, which alerts on it.
    private let callRecordingOutcomePipe = ValuePipe<SGCallRecordingOutcome>()
    public var callRecordingOutcome: Signal<SGCallRecordingOutcome, NoError> {
        return self.callRecordingOutcomePipe.signal()
    }
    // Zenlygram — the other party for the recording's title and the CallKit marker. Outgoing calls
    // are created with `peer: nil` (PresentationCallManager), so it is resolved once from `peerId`
    // instead of every outgoing recording being titled "Unknown" (audit #11).
    private var callRecordingResolvedPeer: EnginePeer?
    private var callRecordingPeerDisposable: Disposable?
    // Zenlygram — set once the 1:1 call screen is leaving (the call ended, or became a
    // conference). From then on a recording outcome is shown in the main window instead of being
    // handed to a call screen that may already be gone (audit #67, #117).
    private var callRecordingOutcomesUseMainWindow = false
    
    private let audioOutputStatePromise = Promise<([AudioSessionOutput], AudioSessionOutput?)>(([], nil))
    private var audioOutputStateValue: ([AudioSessionOutput], AudioSessionOutput?) = ([], nil)
    private var currentAudioOutputValue: AudioSessionOutput = .builtin
    private var didSetCurrentAudioOutputValue: Bool = false
    public var audioOutputState: Signal<([AudioSessionOutput], AudioSessionOutput?), NoError> {
        if let sharedAudioContext = self.sharedAudioContext {
            return sharedAudioContext.audioOutputState
        }
        
        return self.audioOutputStatePromise.get()
    }
    
    private let debugInfoValue = Promise<(String, String)>(("", ""))
    
    private let canBeRemovedPromise = Promise<Bool>(false)
    private var didSetCanBeRemoved = false
    public var canBeRemoved: Signal<Bool, NoError> {
        return self.canBeRemovedPromise.get()
    }
    
    private let hungUpPromise = ValuePromise<Bool>()
    
    private var activeTimestamp: Double?
    
    private var audioSessionControl: ManagedAudioSessionControl?
    private var audioSessionDisposable: Disposable?
    private let audioSessionShouldBeActive = ValuePromise<Bool>(false, ignoreRepeated: true)
    private var audioSessionShouldBeActiveDisposable: Disposable?
    private let audioSessionActive = Promise<Bool>(false)
    private var audioSessionActiveDisposable: Disposable?
    private var isAudioSessionActive = false
    
    private var currentTone: PresentationCallTone?
    
    private var droppedCall = false
    private var dropCallKitCallTimer: SwiftSignalKit.Timer?
    
    private var useFrontCamera: Bool = true
    private var videoCapturer: OngoingCallVideoCapturer?
    public var hasVideo: Bool {
        return self.videoCapturer != nil
    }

    private var screencastBufferServerContext: IpcGroupCallBufferAppContext?
    private var screencastCapturer: OngoingCallVideoCapturer?
    private var isScreencastActive: Bool = false
    public var hasScreencast: Bool {
        return self.screencastCapturer != nil
    }
    
    private var proximityManagerIndex: Int?

    private let screencastFramesDisposable = MetaDisposable()
    private let screencastAudioDataDisposable = MetaDisposable()
    private let screencastStateDisposable = MetaDisposable()
    
    private var conferenceCallImpl: PresentationGroupCallImpl?
    public var conferenceCall: PresentationGroupCall? {
        return self.conferenceCallImpl
    }
    private var conferenceCallDisposable: Disposable?
    private var upgradedToConferenceCompletions = Bag<(PresentationGroupCall) -> Void>()
    
    private var isAcceptingIncomingConference: Bool = false
    private var waitForConferenceCallReadyDisposable: Disposable?
    private let conferenceStatePromise = ValuePromise<PresentationCallConferenceState?>(nil)
    public private(set) var conferenceStateValue: PresentationCallConferenceState? {
        didSet {
            if self.conferenceStateValue != oldValue {
                self.conferenceStatePromise.set(self.conferenceStateValue)
            }
            // Zenlygram — a recording never follows a call into a conference (audit #8). Stopping
            // at `.preparing` rather than at `resetAsMovedToConference` matters: the group call
            // shares the tapped audio device from the moment it is created, the 1:1 call screen
            // (and its REC badge) is dismissed as soon as this becomes non-nil, and the group UI's
            // mute never reaches the recorder's mute gate.
            if self.conferenceStateValue != nil {
                self.callRecordingOutcomesUseMainWindow = true
                self.stopRecording()
            }
        }
    }
    public var conferenceState: Signal<PresentationCallConferenceState?, NoError> {
        return self.conferenceStatePromise.get()
    }
    
    public private(set) var pendingInviteToConferencePeerIds: [(id: EnginePeer.Id, isVideo: Bool)] = []
    
    private var remoteVideoEndpointId: String?
    
    private var isMovedToConference: Bool = false
    
    init(
        context: AccountContext,
        audioSession: ManagedAudioSession,
        callSessionManager: CallSessionManager,
        callKitIntegration: CallKitIntegration?,
        serializedData: String?,
        dataSaving: VoiceCallDataSaving,
        getDeviceAccessData: @escaping () -> (presentationData: PresentationData, present: (ViewController, Any?) -> Void, openSettings: () -> Void),
        initialState: CallSession?,
        internalId: CallSessionInternalId,
        peerId: EnginePeer.Id,
        isOutgoing: Bool,
        incomingConferenceSource: EngineMessage.Id?,
        peer: EnginePeer?,
        proxyServer: ProxyServerSettings?,
        auxiliaryServers: [CallAuxiliaryServer],
        currentNetworkType: NetworkType,
        updatedNetworkType: Signal<NetworkType, NoError>,
        startWithVideo: Bool,
        isVideoPossible: Bool,
        enableStunMarking: Bool,
        enableTCP: Bool,
        preferredVideoCodec: String?
    ) {
        self.context = context
        self.audioSession = audioSession
        self.callSessionManager = callSessionManager
        self.callKitIntegration = callKitIntegration
        self.getDeviceAccessData = getDeviceAccessData
        self.auxiliaryServers = auxiliaryServers.map { server -> OngoingCallContext.AuxiliaryServer in
            let mappedConnection: OngoingCallContext.AuxiliaryServer.Connection
            switch server.connection {
            case .stun:
                mappedConnection = .stun
            case let .turn(username, password):
                mappedConnection = .turn(username: username, password: password)
            }
            return OngoingCallContext.AuxiliaryServer(
                host: server.host,
                port: server.port,
                connection: mappedConnection
            )
        }
        
        self.internalId = internalId
        self.peerId = peerId
        self.isOutgoing = isOutgoing
        self.incomingConferenceSource = incomingConferenceSource
        if let _ = incomingConferenceSource {
            self.conferenceStableId = Int64.random(in: Int64.min ..< Int64.max)
        } else {
            self.conferenceStableId = nil
        }
        self.isVideo = initialState?.type == .video
        self.isVideoPossible = isVideoPossible
        self.enableStunMarking = enableStunMarking
        self.enableTCP = enableTCP
        self.preferredVideoCodec = preferredVideoCodec
        self.peer = peer
        self.isVideo = startWithVideo
        if self.isVideo {
            self.videoCapturer = OngoingCallVideoCapturer()
            self.statePromise.set(PresentationCallState(state: isOutgoing ? .waiting : .ringing, videoState: .active(isScreencast: self.isScreencastActive, endpointId: ""), remoteVideoState: .inactive, remoteAudioState: .active, remoteBatteryLevel: .normal, supportsConferenceCalls: self.supportsConferenceCalls))
        } else {
            self.statePromise.set(PresentationCallState(state: isOutgoing ? .waiting : .ringing, videoState: self.isVideoPossible ? .inactive : .notAvailable, remoteVideoState: .inactive, remoteAudioState: .active, remoteBatteryLevel: .normal, supportsConferenceCalls: self.supportsConferenceCalls))
        }
        
        self.serializedData = serializedData
        self.dataSaving = dataSaving
        self.proxyServer = proxyServer
        self.currentNetworkType = currentNetworkType
        self.updatedNetworkType = updatedNetworkType
        
        var didReceiveAudioOutputs = false
        
        if let incomingConferenceSource {
            let isRinging = context.account.callSessionManager.ringingStates()
            |> map { ringingStates -> Bool in
                for ringingState in ringingStates {
                    if ringingState.id == internalId {
                        return true
                    }
                }
                return false
            }
            |> distinctUntilChanged
            |> take(1)
            self.sessionStateDisposable = (combineLatest(queue: .mainQueue(),
                isRinging,
                context.engine.data.subscribe(
                    TelegramEngine.EngineData.Item.Messages.Message(id: incomingConferenceSource)
                )
            )
            |> deliverOnMainQueue).startStrict(next: { [weak self] isRinging, message in
                guard let self else {
                    return
                }

                let state: CallSessionState
                if let message {
                    var foundAction: TelegramMediaAction?
                    for media in message.media {
                        if let action = media as? TelegramMediaAction {
                            foundAction = action
                            break
                        }
                    }

                    if let action = foundAction, case let .conferenceCall(conferenceCall) = action.action {
                        if conferenceCall.flags.contains(.isMissed) || conferenceCall.duration != nil {
                            state = .terminated(id: nil, reason: .ended(.hungUp), options: CallTerminationOptions())
                        } else {
                            state = .ringing
                        }
                        
                        var conferenceTitle = "Group Call"
                        if let peer = message.peers[message.id.peerId].flatMap(EnginePeer.init) {
                            conferenceTitle = peer.compactDisplayTitle

                            let otherCount = conferenceCall.otherParticipants.filter({ $0 != peer.id }).count
                            if otherCount != 0 {
                                if otherCount == 1 {
                                    conferenceTitle.append(" and 1 other")
                                } else {
                                    conferenceTitle.append(" and \(otherCount) others")
                                }
                            }
                        }
                        self.conferenceTitle = conferenceTitle
                    } else {
                        state = .terminated(id: nil, reason: .ended(.hungUp), options: CallTerminationOptions())
                    }
                } else if isRinging {
                    state = .ringing
                } else {
                    state = .terminated(id: nil, reason: .ended(.hungUp), options: CallTerminationOptions())
                }
                
                self.updateSessionState(
                    sessionState: CallSession(
                        id: self.internalId,
                        stableId: self.conferenceStableId,
                        isOutgoing: false,
                        type: self.isVideo ? .video : .audio,
                        state: state,
                        isVideoPossible: true
                    ),
                    callContextState: nil,
                    reception: nil,
                    audioSessionControl: self.audioSessionControl
                )
            })
        } else {
            var callSessionState: Signal<CallSession, NoError> = .complete()
            if let initialState = initialState {
                callSessionState = .single(initialState)
            }
            callSessionState = callSessionState
            |> then(callSessionManager.callState(internalId: internalId))
            
            self.sessionStateDisposable = (callSessionState
            |> deliverOnMainQueue).start(next: { [weak self] sessionState in
                if let strongSelf = self {
                    strongSelf.updateSessionState(sessionState: sessionState, callContextState: strongSelf.callContextState, reception: strongSelf.reception, audioSessionControl: strongSelf.audioSessionControl)
                }
            })
        }
        
        if let data = context.currentAppConfiguration.with({ $0 }).data, let _ = data["ios_killswitch_disable_call_device"] {
            self.sharedAudioContext = nil
        } else {
            self.sharedAudioContext = SharedCallAudioContext.get(audioSession: audioSession, callKitIntegration: callKitIntegration, defaultToSpeaker: startWithVideo || initialState?.type == .video)
        }
        
        if let _ = self.sharedAudioContext {
        } else {
            self.audioSessionDisposable = audioSession.push(audioSessionType: .voiceCall, manualActivate: { [weak self] control in
                Queue.mainQueue().async {
                    if let strongSelf = self {
                        if let sessionState = strongSelf.sessionState {
                            strongSelf.updateSessionState(sessionState: sessionState, callContextState: strongSelf.callContextState, reception: strongSelf.reception, audioSessionControl: control)
                        } else {
                            strongSelf.audioSessionControl = control
                        }
                    }
                }
            }, deactivate: { [weak self] _ in
                return Signal { subscriber in
                    Queue.mainQueue().async {
                        if let strongSelf = self {
                            strongSelf.updateIsAudioSessionActive(false)
                            if let sessionState = strongSelf.sessionState {
                                strongSelf.updateSessionState(sessionState: sessionState, callContextState: strongSelf.callContextState, reception: strongSelf.reception, audioSessionControl: nil)
                            } else {
                                strongSelf.audioSessionControl = nil
                            }
                        }
                        subscriber.putCompletion()
                    }
                    return EmptyDisposable
                }
            }, availableOutputsChanged: { [weak self] availableOutputs, currentOutput in
                Queue.mainQueue().async {
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.audioOutputStateValue = (availableOutputs, currentOutput)
                    if let currentOutput = currentOutput {
                        strongSelf.currentAudioOutputValue = currentOutput
                        strongSelf.didSetCurrentAudioOutputValue = true
                    }
                    
                    var signal: Signal<([AudioSessionOutput], AudioSessionOutput?), NoError> = .single((availableOutputs, currentOutput))
                    if !didReceiveAudioOutputs {
                        didReceiveAudioOutputs = true
                        if currentOutput == .speaker {
                            signal = .single((availableOutputs, .builtin))
                            |> then(
                                signal
                                |> delay(1.0, queue: Queue.mainQueue())
                            )
                        }
                    }
                    strongSelf.audioOutputStatePromise.set(signal)
                }
            })
            
            self.audioSessionShouldBeActiveDisposable = (self.audioSessionShouldBeActive.get()
            |> deliverOnMainQueue).start(next: { [weak self] value in
                if let strongSelf = self {
                    if value {
                        if let audioSessionControl = strongSelf.audioSessionControl {
                            let audioSessionActive: Signal<Bool, NoError>
                            if let callKitIntegration = strongSelf.callKitIntegration {
                                audioSessionActive = callKitIntegration.audioSessionActive
                            } else {
                                audioSessionControl.activate({ _ in })
                                audioSessionActive = .single(true)
                            }
                            strongSelf.audioSessionActive.set(audioSessionActive)
                        } else {
                            strongSelf.audioSessionActive.set(.single(false))
                        }
                    } else {
                        strongSelf.audioSessionActive.set(.single(false))
                    }
                }
            })
            
            self.audioSessionActiveDisposable = (self.audioSessionActive.get()
            |> deliverOnMainQueue).start(next: { [weak self] value in
                if let strongSelf = self {
                    strongSelf.updateIsAudioSessionActive(value)
                }
            })
        }

        let screencastCapturer = OngoingCallVideoCapturer(isCustom: true)
        self.screencastCapturer = screencastCapturer

        self.resetScreencastContext()
        
        if callKitIntegration == nil {
            self.proximityManagerIndex = DeviceProximityManager.shared().add { _ in
            }
        }

        if self.peer == nil {
            self.callRecordingPeerDisposable = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.peerId))
            |> deliverOnMainQueue).startStrict(next: { [weak self] peer in
                self?.callRecordingResolvedPeer = peer
            })
        }
    }
    
    deinit {
        self.audioSessionShouldBeActiveDisposable?.dispose()
        self.audioSessionActiveDisposable?.dispose()
        self.sessionStateDisposable?.dispose()
        self.ongoingContextStateDisposable?.dispose()
        self.receptionDisposable?.dispose()
        self.audioLevelDisposable?.dispose()
        self.batteryLevelDisposable?.dispose()
        self.audioSessionDisposable?.dispose()
        self.screencastFramesDisposable.dispose()
        self.screencastAudioDataDisposable.dispose()
        self.screencastStateDisposable.dispose()
        self.conferenceCallDisposable?.dispose()
        self.ongoingContextStateDisposable?.dispose()
        self.ongoingContextIsFailedDisposable?.dispose()
        self.ongoingContextIsDroppedDisposable?.dispose()
        self.waitForConferenceCallReadyDisposable?.dispose()
        // Zenlygram — a recording must never outlive the call object silently. The terminating
        // state has normally stopped it already; if it has not, stop and seal it here. The call's
        // own state subscription dies with it, so the finished file is handed to the (default-off)
        // Saved Messages delivery from a subscription that lives exactly until the file is sealed.
        self.callRecordingStateDisposable?.dispose()
        self.callRecordingPeerDisposable?.dispose()
        if let session = self.callRecordingSession {
            session.stop()
            let context = self.context
            let _ = (session.state
            |> filter { state in
                return !state.isActive
            }
            |> take(1)
            |> deliverOnMainQueue).start(next: { _ in
                if let recordingId = session.savedRecordingId {
                    SGCallRecordingDelivery.shared.recordingFinished(context: context, id: recordingId)
                }
            })
        }
        
        if let dropCallKitCallTimer = self.dropCallKitCallTimer {
            dropCallKitCallTimer.invalidate()
            if !self.droppedCall {
                self.callKitIntegration?.dropCall(uuid: self.internalId)
            }
        }
        
        if let proximityManagerIndex = self.proximityManagerIndex {
            DeviceProximityManager.shared().remove(proximityManagerIndex)
        }
    }
    
    public func resetAsMovedToConference() {
        if self.isMovedToConference {
            return
        }
        self.isMovedToConference = true
        
        // Zenlygram — v1 records 1:1 calls only. A call being upgraded to a conference stops
        // recording here rather than quietly following N people into a group whose participants
        // never saw the consent screen this user accepted.
        self.callRecordingOutcomesUseMainWindow = true
        self.stopRecording()
        
        self.sharedAudioContext = nil
        self.sessionState = nil
        self.callContextState = nil
        let debugLogValue = Promise<String?>()
        if let conferenceCallContext = self.conferenceCallContext {
            let _ = conferenceCallContext.leave(terminateIfPossible: false).startStandalone()
            self.conferenceCallContext = nil
        } else {
            self.ongoingContext?.stop(sendDebugLogs: false, debugLogValue: debugLogValue)
        }
        self.ongoingContext = nil
        self.ongoingContextStateDisposable?.dispose()
        self.ongoingContextStateDisposable = nil
        self.ongoingContextIsFailedDisposable?.dispose()
        self.ongoingContextIsFailedDisposable = nil
        self.ongoingContextIsDroppedDisposable?.dispose()
        self.ongoingContextIsDroppedDisposable = nil
        self.didDropCall = false
        self.requestedVideoAspect = nil
        self.reception = nil
        self.receptionDisposable?.dispose()
        self.receptionDisposable = nil
        self.audioLevelDisposable?.dispose()
        self.audioLevelDisposable = nil
        self.reportedIncomingCall = false
        self.batteryLevelDisposable?.dispose()
        self.batteryLevelDisposable = nil
        self.callWasActive = false
        self.shouldPresentCallRating = false
        self.previousVideoState = nil
        self.previousRemoteVideoState = nil
        self.previousRemoteAudioState = nil
        self.previousRemoteBatteryLevel = nil
        self.sessionStateDisposable?.dispose()
        self.sessionStateDisposable = nil
        self.activeTimestamp = nil
        self.audioSessionControl = nil
        self.audioSessionDisposable?.dispose()
        self.audioSessionDisposable = nil
        self.audioSessionShouldBeActiveDisposable?.dispose()
        self.audioSessionShouldBeActiveDisposable = nil
        self.audioSessionActiveDisposable?.dispose()
        self.audioSessionActiveDisposable = nil
        self.isAudioSessionActive = false
        self.currentTone = nil
        
        self.dropCallKitCallTimer?.invalidate()
        self.dropCallKitCallTimer = nil
        
        self.droppedCall = true
        
        self.videoCapturer = nil

        self.screencastBufferServerContext = nil
        self.screencastCapturer = nil
        self.isScreencastActive = false
        
        if let proximityManagerIndex = self.proximityManagerIndex {
            DeviceProximityManager.shared().remove(proximityManagerIndex)
            self.proximityManagerIndex = nil
        }

        self.screencastFramesDisposable.set(nil)
        self.screencastAudioDataDisposable.set(nil)
        self.screencastStateDisposable.set(nil)
        
        self.conferenceCallImpl = nil
        
        self.conferenceCallDisposable?.dispose()
        self.conferenceCallDisposable = nil
        
        self.upgradedToConferenceCompletions.removeAll()
        
        self.waitForConferenceCallReadyDisposable?.dispose()
        self.waitForConferenceCallReadyDisposable = nil
        
        self.pendingInviteToConferencePeerIds.removeAll()
        
        self.remoteVideoEndpointId = nil
        
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        self.callKitIntegration?.updateCallIsConference(uuid: self.internalId, title: self.conferenceTitle ?? presentationData.strings.Call_GenericGroupCallTitle)
    }
    
    func internal_markAsCanBeRemoved() {
        if !self.didSetCanBeRemoved {
            self.didSetCanBeRemoved = true
            self.canBeRemovedPromise.set(.single(true))
        }
    }
    
    private func updateSessionState(sessionState: CallSession, callContextState: OngoingCallContextState?, reception: Int32?, audioSessionControl: ManagedAudioSessionControl?) {
        if self.isMovedToConference {
            return
        }
        self.reception = reception
        
        if let ongoingContext = self.ongoingContext {
            if self.receptionDisposable == nil, case .active = sessionState.state {
                self.reception = 4
                
                if self.isOutgoing {
                    self.callKitIntegration?.reportOutgoingCallConnected(uuid: sessionState.id, at: Date())
                }
                
                var canUpdate = false
                self.receptionDisposable = (ongoingContext.reception
                |> delay(1.0, queue: .mainQueue())
                |> deliverOnMainQueue).start(next: { [weak self] reception in
                    if let strongSelf = self {
                        if let sessionState = strongSelf.sessionState {
                            if canUpdate {
                                strongSelf.updateSessionState(sessionState: sessionState, callContextState: strongSelf.callContextState, reception: reception, audioSessionControl: strongSelf.audioSessionControl)
                            } else {
                                strongSelf.reception = reception
                            }
                        } else {
                            strongSelf.reception = reception
                        }
                    }
                })
                canUpdate = true
            }
        } else if let conferenceCallContext = self.conferenceCallContext {
            if self.receptionDisposable == nil, case .active = sessionState.state {
                self.reception = 4
                
                if self.isOutgoing {
                    self.callKitIntegration?.reportOutgoingCallConnected(uuid: sessionState.id, at: Date())
                }
                
                var canUpdate = false
                self.receptionDisposable = (conferenceCallContext.signalBars
                |> delay(1.0, queue: .mainQueue())
                |> deliverOnMainQueue).start(next: { [weak self] reception in
                    if let strongSelf = self {
                        if let sessionState = strongSelf.sessionState {
                            if canUpdate {
                                strongSelf.updateSessionState(sessionState: sessionState, callContextState: strongSelf.callContextState, reception: reception, audioSessionControl: strongSelf.audioSessionControl)
                            } else {
                                strongSelf.reception = reception
                            }
                        } else {
                            strongSelf.reception = reception
                        }
                    }
                })
                canUpdate = true
            }
        }
        
        if case .video = sessionState.type {
            self.isVideo = true
        }
        let previous = self.sessionState
        let previousRemoteVideoState = self.previousRemoteVideoState
        let previousControl = self.audioSessionControl
        self.sessionState = sessionState
        self.callContextState = callContextState
        self.audioSessionControl = audioSessionControl
        
        let reception = self.reception
        
        /*if previousControl != nil && audioSessionControl == nil {
            print("updateSessionState \(sessionState.state) \(audioSessionControl != nil)")
        }*/
        
        var presentationState: PresentationCallState?
        
        var wasActive = false
        var wasTerminated = false
        if let previous = previous {
            switch previous.state {
            case .active:
                wasActive = true
            case let .terminated(_, reason, _):
                if case .ended(.switchedToConference) = reason {
                } else {
                    wasTerminated = true
                }
            default:
                break
            }
        }
        
        if self.sharedAudioContext == nil {
            if let audioSessionControl = audioSessionControl, previous == nil || previousControl == nil {
                if let callKitIntegration = self.callKitIntegration {
                    if self.didSetCurrentAudioOutputValue {
                        callKitIntegration.applyVoiceChatOutputMode(outputMode: .custom(self.currentAudioOutputValue))
                    }
                } else {
                    audioSessionControl.setOutputMode(.custom(self.currentAudioOutputValue))
                    audioSessionControl.setup(synchronous: true)
                }
            }
        }

        if case let .active(_, _, _, _, _, _, _, _, supportsConferenceCallsValue) = sessionState.state {
            self.supportsConferenceCalls = supportsConferenceCallsValue
        }
        
        let mappedVideoState: PresentationCallState.VideoState
        let mappedRemoteVideoState: PresentationCallState.RemoteVideoState
        let mappedRemoteAudioState: PresentationCallState.RemoteAudioState
        let mappedRemoteBatteryLevel: PresentationCallState.RemoteBatteryLevel
        if let callContextState = callContextState {
            switch callContextState.videoState {
            case .notAvailable:
                mappedVideoState = .notAvailable
            case .active:
                mappedVideoState = .active(isScreencast: self.isScreencastActive, endpointId: "")
            case .inactive:
                mappedVideoState = .inactive
            case .paused:
                mappedVideoState = .paused(isScreencast: self.isScreencastActive, endpointId: "")
            }
            switch callContextState.remoteVideoState {
            case .inactive:
                mappedRemoteVideoState = .inactive
            case .active:
                mappedRemoteVideoState = .active(endpointId: "")
            case .paused:
                mappedRemoteVideoState = .paused(endpointId: "")
            }
            switch callContextState.remoteAudioState {
            case .active:
                mappedRemoteAudioState = .active
            case .muted:
                mappedRemoteAudioState = .muted
            }
            switch callContextState.remoteBatteryLevel {
            case .normal:
                mappedRemoteBatteryLevel = .normal
            case .low:
                mappedRemoteBatteryLevel = .low
            }
            self.previousVideoState = mappedVideoState
            self.previousRemoteVideoState = mappedRemoteVideoState
            self.previousRemoteAudioState = mappedRemoteAudioState
            self.previousRemoteBatteryLevel = mappedRemoteBatteryLevel
        } else {
            if let previousVideoState = self.previousVideoState {
                mappedVideoState = previousVideoState
            } else {
                if self.isVideo {
                    mappedVideoState = .active(isScreencast: self.isScreencastActive, endpointId: "")
                } else if self.isVideoPossible && sessionState.isVideoPossible {
                    mappedVideoState = .inactive
                } else {
                    mappedVideoState = .notAvailable
                }
            }
            mappedRemoteVideoState = .inactive
            if let previousRemoteAudioState = self.previousRemoteAudioState {
                mappedRemoteAudioState = previousRemoteAudioState
            } else {
                mappedRemoteAudioState = .active
            }
            if let previousRemoteBatteryLevel = self.previousRemoteBatteryLevel {
                mappedRemoteBatteryLevel = previousRemoteBatteryLevel
            } else {
                mappedRemoteBatteryLevel = .normal
            }
        }
        
        switch sessionState.state {
            case .ringing:
                presentationState = PresentationCallState(state: .ringing, videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel, supportsConferenceCalls: self.supportsConferenceCalls)
                if previous == nil || previousControl == nil {
                    if !self.reportedIncomingCall, let stableId = sessionState.stableId {
                        self.reportedIncomingCall = true
                        var phoneNumber: String?
                        if case let .user(peer) = self.peer, let phone = peer.phone {
                            phoneNumber = formatPhoneNumber(context: self.context, number: phone)
                        }
                        self.callKitIntegration?.reportIncomingCall(
                            uuid: self.internalId,
                            stableId: stableId,
                            handle: "\(self.peerId.id._internalGetInt64Value())",
                            phoneNumber: phoneNumber,
                            isVideo: sessionState.type == .video,
                            displayTitle: self.peer?.debugDisplayTitle ?? "Unknown",
                            completion: { [weak self] error in
                                if let error = error {
                                    if error.domain == "com.apple.CallKit.error.incomingcall" && (error.code == -3 || error.code == 3) {
                                        Logger.shared.log("PresentationCall", "reportIncomingCall device in DND mode")
                                        Queue.mainQueue().async {
                                            /*if let strongSelf = self {
                                                strongSelf.callSessionManager.drop(internalId: strongSelf.internalId, reason: .busy, debugLog: .single(nil))
                                            }*/
                                        }
                                    } else {
                                        Logger.shared.log("PresentationCall", "reportIncomingCall error \(error)")
                                        Queue.mainQueue().async {
                                            if let strongSelf = self {
                                                strongSelf.callSessionManager.drop(internalId: strongSelf.internalId, reason: .hangUp, debugLog: .single(nil))
                                            }
                                        }
                                    }
                                }
                            }
                        )
                    }
                }
            case .accepting:
                self.callWasActive = true
                presentationState = PresentationCallState(state: .connecting(nil), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel, supportsConferenceCalls: self.supportsConferenceCalls)
            case let .dropping(reason):
                if case .ended(.switchedToConference) = reason {
                } else {
                    presentationState = PresentationCallState(state: .terminating(reason), videoState: mappedVideoState, remoteVideoState: .inactive, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel, supportsConferenceCalls: self.supportsConferenceCalls)
                }
            case let .terminated(id, reason, options):
                presentationState = PresentationCallState(state: .terminated(id, reason, self.callWasActive && (options.contains(.reportRating) || self.shouldPresentCallRating)), videoState: mappedVideoState, remoteVideoState: .inactive, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel, supportsConferenceCalls: self.supportsConferenceCalls)
            case let .requesting(ringing):
                presentationState = PresentationCallState(state: .requesting(ringing), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel, supportsConferenceCalls: self.supportsConferenceCalls)
            case .active(_, _, _, _, _, _, _, _, _), .switchedToConference:
                self.callWasActive = true
            
                var isConference = false
                if case .switchedToConference = sessionState.state {
                    isConference = true
                }
            
                if let callContextState, !isConference, case let .active(_, _, keyVisualHash, _, _, _, _, _, _) = sessionState.state {
                    switch callContextState.state {
                    case .initializing:
                        presentationState = PresentationCallState(state: .connecting(keyVisualHash), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel, supportsConferenceCalls: self.supportsConferenceCalls)
                    case .failed:
                        presentationState = PresentationCallState(state: .terminating(.error(.disconnected)), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel, supportsConferenceCalls: self.supportsConferenceCalls)
                        self.callSessionManager.drop(internalId: self.internalId, reason: .disconnect, debugLog: .single(nil))
                    case .connected:
                        let timestamp: Double
                        if let activeTimestamp = self.activeTimestamp {
                            timestamp = activeTimestamp
                        } else {
                            timestamp = CFAbsoluteTimeGetCurrent()
                            self.activeTimestamp = timestamp
                        }
                        presentationState = PresentationCallState(state: .active(timestamp, reception, keyVisualHash), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel, supportsConferenceCalls: self.supportsConferenceCalls)
                    case .reconnecting:
                        let timestamp: Double
                        if let activeTimestamp = self.activeTimestamp {
                            timestamp = activeTimestamp
                        } else {
                            timestamp = CFAbsoluteTimeGetCurrent()
                            self.activeTimestamp = timestamp
                        }
                        presentationState = PresentationCallState(state: .reconnecting(timestamp, reception, keyVisualHash), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel, supportsConferenceCalls: self.supportsConferenceCalls)
                    }
                } else if !isConference, case let .active(_, _, keyVisualHash, _, _, _, _, _, _) = sessionState.state {
                    presentationState = PresentationCallState(state: .connecting(keyVisualHash), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel, supportsConferenceCalls: self.supportsConferenceCalls)
                }
        }
        
        var conferenceCallData: InternalGroupCallReference?
        if let incomingConferenceSource = self.incomingConferenceSource {
            if self.isAcceptingIncomingConference {
                conferenceCallData = .message(id: incomingConferenceSource)
            }
        } else {
            switch sessionState.state {
            case let .switchedToConference(slug):
                conferenceCallData = .link(slug: slug)
            default:
                break
            }
        }
        
        if let conferenceCallData {
            // Zenlygram — stop before the group call is even created on the shared audio device
            // (audit #8); `conferenceStateValue`'s didSet covers the paths that only set `.preparing`.
            self.callRecordingOutcomesUseMainWindow = true
            self.stopRecording()
            if self.conferenceCallDisposable == nil {
                let conferenceCallSignal = self.context.engine.calls.getCurrentGroupCall(reference: conferenceCallData)
                self.conferenceCallDisposable = (conferenceCallSignal
                |> deliverOnMainQueue).startStrict(next: { [weak self] groupCall in
                    guard let self else {
                        return
                    }
                    let keyPair: TelegramKeyPair? = TelegramE2EEncryptionProviderImpl.shared.generateKeyPair()
                    guard let keyPair, let groupCall else {
                        self.sessionStateDisposable?.dispose()
                        self.updateSessionState(
                            sessionState: CallSession(
                                id: self.internalId,
                                stableId: self.conferenceStableId,
                                isOutgoing: false,
                                type: self.isVideo ? .video : .audio,
                                state: .terminated(id: nil, reason: .error(.generic), options: CallTerminationOptions()),
                                isVideoPossible: true
                            ),
                            callContextState: nil,
                            reception: nil,
                            audioSessionControl: self.audioSessionControl
                        )
                        return
                    }
                    
                    let conferenceCall = PresentationGroupCallImpl(
                        accountContext: self.context,
                        audioSession: self.audioSession,
                        callKitIntegration: self.callKitIntegration,
                        getDeviceAccessData: self.getDeviceAccessData,
                        initialCall: (EngineGroupCallDescription(
                            id: groupCall.info.id,
                            accessHash: groupCall.info.accessHash,
                            title: nil,
                            scheduleTimestamp: nil,
                            subscribedToScheduled: false,
                            isStream: false
                        ), conferenceCallData),
                        internalId: self.internalId,
                        peerId: nil,
                        isChannel: false,
                        invite: nil,
                        joinAsPeerId: nil,
                        isStream: false,
                        streamPeerId: nil,
                        keyPair: keyPair,
                        conferenceSourceId: self.internalId,
                        isConference: true,
                        beginWithVideo: false,
                        sharedAudioContext: self.sharedAudioContext
                    )
                    self.conferenceCallImpl = conferenceCall
                    conferenceCall.upgradedConferenceCall = self
                    
                    self.sharedAudioContext?.switchToSpeakerIfBuiltin()
                    
                    for (peerId, isVideo) in self.pendingInviteToConferencePeerIds {
                        let _ = conferenceCall.invitePeer(peerId, isVideo: isVideo)
                    }
                    
                    conferenceCall.setIsMuted(action: self.isMutedValue ? .muted(isPushToTalkActive: false) : .unmuted)
                    if let videoCapturer = self.videoCapturer {
                        conferenceCall.requestVideo(capturer: videoCapturer)
                    }
                    
                    let waitForLocalVideo = self.videoCapturer != nil
                    
                    let waitForRemotePeerId: EnginePeer.Id? = self.peerId
                    var waitForRemoteVideo: EnginePeer.Id?
                    if let callContextState = self.callContextState {
                        switch callContextState.remoteVideoState {
                        case .active, .paused:
                            waitForRemoteVideo = self.peerId
                        case .inactive:
                            break
                        }
                    }
                    
                    self.conferenceStateValue = .preparing
                    
                    self.waitForConferenceCallReadyDisposable?.dispose()
                    self.waitForConferenceCallReadyDisposable = (combineLatest(queue: .mainQueue(),
                        conferenceCall.state,
                        conferenceCall.members
                    )
                    |> filter { state, members in
                        if state.networkState != .connected {
                            return false
                        }
                        if let waitForRemotePeerId {
                            var found = false
                            if let members {
                                for participant in members.participants {
                                    if participant.id == .peer(waitForRemotePeerId) {
                                        found = true
                                        break
                                    }
                                }
                            }
                            if !found {
                                return false
                            }
                        }
                        if waitForLocalVideo {
                            if let members {
                                for participant in members.participants {
                                    if participant.id == .peer(state.myPeerId) {
                                        if participant.videoDescription == nil {
                                            return false
                                        }
                                    }
                                }
                            }
                        }
                        if let waitForRemoteVideo {
                            if let members {
                                for participant in members.participants {
                                    if participant.id == .peer(waitForRemoteVideo) {
                                        if participant.videoDescription == nil {
                                            return false
                                        }
                                    }
                                }
                            }
                        }
                        return true
                    }
                    |> map { _, _ -> Void in
                        return Void()
                    }
                    |> take(1)
                    |> timeout(10.0, queue: .mainQueue(), alternate: .single(Void()))).start(next: { [weak self] _ in
                        guard let self else {
                            return
                        }
                        
                        self.ongoingContextStateDisposable?.dispose()
                        
                        self.conferenceStateValue = .ready
                        
                        let upgradedToConferenceCompletions = self.upgradedToConferenceCompletions.copyItems()
                        self.upgradedToConferenceCompletions.removeAll()
                        for f in upgradedToConferenceCompletions {
                            f(conferenceCall)
                        }
                    })
                }, error: { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.sessionStateDisposable?.dispose()
                    self.updateSessionState(sessionState: CallSession(
                        id: self.internalId,
                        stableId: self.conferenceStableId,
                        isOutgoing: false,
                        type: .audio,
                        state: .terminated(id: nil, reason: .error(.generic), options: CallTerminationOptions()),
                        isVideoPossible: true
                    ),
                    callContextState: nil, reception: nil, audioSessionControl: self.audioSessionControl)
                })
            }
        }
        
        switch sessionState.state {
            case .requesting:
                if let _ = audioSessionControl {
                    self.audioSessionShouldBeActive.set(true)
                }
            case let .active(id, key, _, connections, maxLayer, version, customParameters, allowsP2P, _):
                self.audioSessionShouldBeActive.set(true)
            
                if conferenceCallData != nil {
                    if sessionState.isOutgoing {
                        self.callKitIntegration?.reportOutgoingCallConnected(uuid: sessionState.id, at: Date())
                    }
                } else {
                    if (self.sharedAudioContext != nil || audioSessionControl != nil), !wasActive || (self.sharedAudioContext == nil && previousControl == nil) {
                        let logName = "\(id.id)_\(id.accessHash)"
                        
                        var inlineConferenceSlug: String?
                        if let dict = try? JSONSerialization.jsonObject(with: (customParameters ?? "{}").data(using: .utf8)!) as? [String: Any] {
                            inlineConferenceSlug = dict["inline_conference"] as? String
                        }
                        
                        if let inlineConferenceSlug {
                            if self.conferenceCallDisposable == nil {
                                let conferenceCallSignal = self.context.engine.calls.getCurrentGroupCall(reference: .link(slug: inlineConferenceSlug))
                                self.conferenceCallDisposable = (conferenceCallSignal
                                |> deliverOnMainQueue).startStrict(next: { [weak self] groupCall in
                                    guard let self else {
                                        return
                                    }
                                    let keyPair: TelegramKeyPair? = TelegramE2EEncryptionProviderImpl.shared.generateKeyPair()
                                    guard let keyPair, let groupCall else {
                                        self.sessionStateDisposable?.dispose()
                                        self.updateSessionState(
                                            sessionState: CallSession(
                                                id: self.internalId,
                                                stableId: self.conferenceStableId,
                                                isOutgoing: false,
                                                type: self.isVideo ? .video : .audio,
                                                state: .terminated(id: nil, reason: .error(.generic), options: CallTerminationOptions()),
                                                isVideoPossible: true
                                            ),
                                            callContextState: nil,
                                            reception: nil,
                                            audioSessionControl: self.audioSessionControl
                                        )
                                        return
                                    }
                                    
                                    let conferenceCallContext = PresentationGroupCallImpl(
                                        accountContext: self.context,
                                        audioSession: self.audioSession,
                                        callKitIntegration: self.callKitIntegration,
                                        getDeviceAccessData: self.getDeviceAccessData,
                                        initialCall: (EngineGroupCallDescription(
                                            id: groupCall.info.id,
                                            accessHash: groupCall.info.accessHash,
                                            title: nil,
                                            scheduleTimestamp: nil,
                                            subscribedToScheduled: false,
                                            isStream: false
                                        ), .link(slug: inlineConferenceSlug)),
                                        internalId: self.internalId,
                                        peerId: nil,
                                        isChannel: false,
                                        invite: nil,
                                        joinAsPeerId: nil,
                                        isStream: false,
                                        streamPeerId: nil,
                                        keyPair: keyPair,
                                        conferenceSourceId: self.internalId,
                                        isConference: true,
                                        beginWithVideo: false,
                                        sharedAudioContext: self.sharedAudioContext
                                    )
                                    self.conferenceCallContext = conferenceCallContext
                                    
                                    conferenceCallContext.setIsMuted(action: self.isMutedValue ? .muted(isPushToTalkActive: false) : .unmuted)
                                    if let videoCapturer = self.videoCapturer {
                                        conferenceCallContext.requestVideo(capturer: videoCapturer)
                                    }
                                    
                                    self.ongoingContextStateDisposable = (combineLatest(queue: .mainQueue(),
                                        conferenceCallContext.state,
                                        conferenceCallContext.members
                                    ) |> deliverOnMainQueue).start(next: { [weak self] contextState, contextMembers in
                                        guard let self else {
                                            return
                                        }
                                        
                                        let mappedState: OngoingCallContextState.State
                                        if contextState.networkState == .connected {
                                            mappedState = .connected
                                        } else {
                                            mappedState = .reconnecting
                                        }
                                        
                                        var localVideoState: OngoingCallContextState.VideoState = .inactive
                                        var remoteVideoState: OngoingCallContextState.RemoteVideoState = .inactive
                                        var remoteVideoEndpointId: String?
                                        var remoteVideoDescription: PresentationGroupCallRequestedVideo?
                                        var remoteAudioState: OngoingCallContextState.RemoteAudioState = .active
                                        
                                        if let contextMembers {
                                            for participant in contextMembers.participants {
                                                if participant.peer?.id == self.context.account.peerId {
                                                    if participant.videoDescription != nil {
                                                        localVideoState = .active
                                                    }
                                                } else if participant.peer?.id == self.peerId {
                                                    remoteVideoDescription = participant.requestedVideoChannel(minQuality: .thumbnail, maxQuality: .full)
                                                    if remoteVideoDescription != nil {
                                                        remoteVideoState = .active
                                                        remoteVideoEndpointId = remoteVideoDescription?.endpointId
                                                    }
                                                    remoteAudioState = participant.muteState == nil ? .active : .muted
                                                }
                                            }
                                        }
                                        self.remoteVideoEndpointId = remoteVideoEndpointId
                                        var requestedVideoList: [PresentationGroupCallRequestedVideo] = []
                                        if let remoteVideoDescription {
                                            requestedVideoList.append(remoteVideoDescription)
                                        }
                                        self.conferenceCallContext?.setRequestedVideoList(items: requestedVideoList)
                                        
                                        let mappedContextState = OngoingCallContextState(
                                            state: mappedState,
                                            videoState: localVideoState,
                                            remoteVideoState: remoteVideoState,
                                            remoteAudioState: remoteAudioState,
                                            remoteBatteryLevel: .normal
                                        )
                                        
                                        if let sessionState = self.sessionState {
                                            self.updateSessionState(sessionState: sessionState, callContextState: mappedContextState, reception: self.reception, audioSessionControl: self.audioSessionControl)
                                        } else {
                                            self.callContextState = mappedContextState
                                        }
                                    })
                                    
                                    self.audioLevelDisposable = (conferenceCallContext.audioLevels
                                    |> deliverOnMainQueue).start(next: { [weak self] levels in
                                        guard let self else {
                                            return
                                        }
                                        var level: Float = 0.0
                                        for (peerId, _, levelValue, _) in levels {
                                            if peerId == self.peerId {
                                                level = levelValue
                                                break
                                            }
                                        }
                                        self.audioLevelPromise.set(level)
                                    })
                                    
                                    func batteryLevelIsLowSignal() -> Signal<Bool, NoError> {
                                        return Signal { subscriber in
                                            let device = UIDevice.current
                                            device.isBatteryMonitoringEnabled = true
                                            
                                            var previousBatteryLevelIsLow = false
                                            let timer = SwiftSignalKit.Timer(timeout: 30.0, repeat: true, completion: {
                                                let batteryLevelIsLow = device.batteryLevel >= 0.0 && device.batteryLevel < 0.1 && device.batteryState != .charging
                                                if batteryLevelIsLow != previousBatteryLevelIsLow {
                                                    previousBatteryLevelIsLow = batteryLevelIsLow
                                                    subscriber.putNext(batteryLevelIsLow)
                                                }
                                            }, queue: Queue.mainQueue())
                                            timer.start()
                                            
                                            return ActionDisposable {
                                                device.isBatteryMonitoringEnabled = false
                                                timer.invalidate()
                                            }
                                        }
                                    }
                                }, error: { [weak self] _ in
                                    guard let self else {
                                        return
                                    }
                                    self.sessionStateDisposable?.dispose()
                                    self.updateSessionState(sessionState: CallSession(
                                        id: self.internalId,
                                        stableId: self.conferenceStableId,
                                        isOutgoing: false,
                                        type: .audio,
                                        state: .terminated(id: nil, reason: .error(.generic), options: CallTerminationOptions()),
                                        isVideoPossible: true
                                    ),
                                    callContextState: nil, reception: nil, audioSessionControl: self.audioSessionControl)
                                })
                            }
                        } else {
                            let updatedConnections = connections
                            
                            let contextAudioSessionActive: Signal<Bool, NoError>
                            if self.sharedAudioContext != nil {
                                contextAudioSessionActive = .single(true)
                            } else {
                                contextAudioSessionActive = self.audioSessionActive.get()
                            }
                            
                            let ongoingContext = OngoingCallContext(account: self.context.account, callSessionManager: self.callSessionManager, callId: id, internalId: self.internalId, proxyServer: proxyServer, initialNetworkType: self.currentNetworkType, updatedNetworkType: self.updatedNetworkType, serializedData: self.serializedData, dataSaving: dataSaving, key: key, isOutgoing: sessionState.isOutgoing, video: self.videoCapturer, connections: updatedConnections, maxLayer: maxLayer, version: version, customParameters: customParameters, allowP2P: allowsP2P, enableTCP: self.enableTCP, enableStunMarking: self.enableStunMarking, audioSessionActive: contextAudioSessionActive, logName: logName, preferredVideoCodec: self.preferredVideoCodec, audioDevice: self.sharedAudioContext?.audioDevice)
                            self.ongoingContext = ongoingContext
                            ongoingContext.setIsMuted(self.isMutedValue)
                            if let requestedVideoAspect = self.requestedVideoAspect {
                                ongoingContext.setRequestedVideoAspect(requestedVideoAspect)
                            }
                            
                            self.debugInfoValue.set(ongoingContext.debugInfo())
                            
                            self.ongoingContextStateDisposable = (ongoingContext.state
                            |> deliverOnMainQueue).start(next: { [weak self] contextState in
                                if let strongSelf = self {
                                    if let sessionState = strongSelf.sessionState {
                                        strongSelf.updateSessionState(sessionState: sessionState, callContextState: contextState, reception: strongSelf.reception, audioSessionControl: strongSelf.audioSessionControl)
                                    } else {
                                        strongSelf.callContextState = contextState
                                    }
                                }
                            })
                            
                            self.audioLevelDisposable = (ongoingContext.audioLevel
                            |> deliverOnMainQueue).start(next: { [weak self] level in
                                if let strongSelf = self {
                                    strongSelf.audioLevelPromise.set(level)
                                }
                            })
                            
                            func batteryLevelIsLowSignal() -> Signal<Bool, NoError> {
                                return Signal { subscriber in
                                    let device = UIDevice.current
                                    device.isBatteryMonitoringEnabled = true
                                    
                                    var previousBatteryLevelIsLow = false
                                    let timer = SwiftSignalKit.Timer(timeout: 30.0, repeat: true, completion: {
                                        let batteryLevelIsLow = device.batteryLevel >= 0.0 && device.batteryLevel < 0.1 && device.batteryState != .charging
                                        if batteryLevelIsLow != previousBatteryLevelIsLow {
                                            previousBatteryLevelIsLow = batteryLevelIsLow
                                            subscriber.putNext(batteryLevelIsLow)
                                        }
                                    }, queue: Queue.mainQueue())
                                    timer.start()
                                    
                                    return ActionDisposable {
                                        device.isBatteryMonitoringEnabled = false
                                        timer.invalidate()
                                    }
                                }
                            }
                            
                            self.batteryLevelDisposable = (batteryLevelIsLowSignal()
                            |> deliverOnMainQueue).start(next: { [weak self] batteryLevelIsLow in
                                if let strongSelf = self, let ongoingContext = strongSelf.ongoingContext {
                                    ongoingContext.setIsLowBatteryLevel(batteryLevelIsLow)
                                }
                            })
                        }
                    }
                }
            case .switchedToConference:
                self.audioSessionShouldBeActive.set(true)
            case let .terminated(_, _, options):
                self.audioSessionShouldBeActive.set(true)
                if wasActive {
                    let debugLogValue = Promise<String?>()
                    if let conferenceCallContext = self.conferenceCallContext {
                        debugLogValue.set(conferenceCallContext.debugLog.get())
                        let _ = conferenceCallContext.leave(terminateIfPossible: false).startStandalone()
                    } else {
                        self.ongoingContext?.stop(sendDebugLogs: options.contains(.sendDebugLogs), debugLogValue: debugLogValue)
                    }
                }
            case .dropping:
                break
            default:
                self.audioSessionShouldBeActive.set(false)
                if wasActive {
                    let debugLogValue = Promise<String?>()
                    if let conferenceCallContext = self.conferenceCallContext {
                        debugLogValue.set(conferenceCallContext.debugLog.get())
                        let _ = conferenceCallContext.leave(terminateIfPossible: false).startStandalone()
                    } else {
                        self.ongoingContext?.stop(debugLogValue: debugLogValue)
                    }
                }
        }
        var terminating = false
        if case .terminated = sessionState.state {
            terminating = true
        } else if case let .dropping(reason) = sessionState.state {
            switch reason {
            case .ended(.switchedToConference):
                break
            default:
                terminating = true
            }
        }
        
        if terminating, !wasTerminated {
            // Zenlygram — the call is over: finish the recording and seal both files. Doing it here
            // rather than in deinit means the files are complete before the call UI goes away.
            self.callRecordingOutcomesUseMainWindow = true
            self.stopRecording()
            if !self.didSetCanBeRemoved {
                self.didSetCanBeRemoved = true
                self.canBeRemovedPromise.set(.single(true) |> delay(2.0, queue: Queue.mainQueue()))
            }
            self.hungUpPromise.set(true)
            if sessionState.isOutgoing {
                if !self.droppedCall && self.dropCallKitCallTimer == nil {
                    let dropCallKitCallTimer = SwiftSignalKit.Timer(timeout: 2.0, repeat: false, completion: { [weak self] in
                        if let strongSelf = self {
                            strongSelf.dropCallKitCallTimer = nil
                            if !strongSelf.droppedCall {
                                strongSelf.droppedCall = true
                                strongSelf.callKitIntegration?.dropCall(uuid: strongSelf.internalId)
                            }
                        }
                    }, queue: Queue.mainQueue())
                    self.dropCallKitCallTimer = dropCallKitCallTimer
                    dropCallKitCallTimer.start()
                }
            } else {
                self.callKitIntegration?.dropCall(uuid: self.internalId)
            }
        }
        
        var isConference = false
        if case .switchedToConference = sessionState.state {
            isConference = true
        }
        if self.conferenceCallImpl != nil {
            isConference = true
        }
        if self.conferenceStateValue != nil {
            isConference = true
        }
        if self.incomingConferenceSource != nil {
            isConference = true
        }
        
        if isConference {
            if self.currentTone != nil {
                self.currentTone = nil
                self.sharedAudioContext?.audioDevice?.setTone(tone: nil)
            }
        } else {
            if let presentationState {
                self.statePromise.set(presentationState)
                self.updateTone(presentationState, callContextState: callContextState, previous: previous, previousRemoteVideoState: previousRemoteVideoState)
            }
        }
    }
    
    private func updateTone(_ state: PresentationCallState, callContextState: OngoingCallContextState?, previous: CallSession?, previousRemoteVideoState: PresentationCallState.RemoteVideoState?) {
        if self.isMovedToConference {
            return
        }
        var tone: PresentationCallTone?
        if let callContextState = callContextState, case .reconnecting = callContextState.state {
            if !self.isVideo {
                tone = .connecting
            }
        } else if let previous = previous {
            switch previous.state {
            case .accepting, .active, .dropping, .requesting:
                switch state.state {
                case .connecting:
                    if case .requesting = previous.state {
                        tone = .ringing
                    } else {
                        if !self.isVideo {
                            tone = .connecting
                        }
                    }
                case .requesting(true):
                    tone = .ringing
                case let .terminated(_, reason, _):
                    if let reason = reason {
                        switch reason {
                        case let .ended(type):
                            switch type {
                            case .busy:
                                tone = .busy
                            case .hungUp, .missed:
                                tone = .ended
                            case .switchedToConference:
                                tone = nil
                            }
                        case .error:
                            tone = .failed
                        }
                    }
                default:
                    break
                }
            default:
                break
            }
        }
        if tone != self.currentTone {
            self.currentTone = tone
            self.sharedAudioContext?.audioDevice?.setTone(tone: tone.flatMap(presentationCallToneData).flatMap { data in
                return OngoingCallContext.Tone(samples: data, sampleRate: 48000, loopCount: tone?.loopCount ?? 1000000)
            })
        }
    }
    
    private func updateIsAudioSessionActive(_ value: Bool) {
        if self.isMovedToConference {
            return
        }
        if self.isAudioSessionActive != value {
            self.isAudioSessionActive = value
        }
    }
    
    public func answer() {
        if self.isMovedToConference {
            return
        }
        self.answer(fromCallKitAction: false)
    }
        
    func answer(fromCallKitAction: Bool) {
        if self.isMovedToConference {
            return
        }
        let (presentationData, present, openSettings) = self.getDeviceAccessData()
        
        DeviceAccess.authorizeAccess(to: .microphone(.voiceCall), presentationData: presentationData, present: { c, a in
            present(c, a)
        }, openSettings: {
            openSettings()
        }, { [weak self] value in
            guard let strongSelf = self else {
                return
            }
            if value {
                if strongSelf.isVideo {
                    DeviceAccess.authorizeAccess(to: .camera(.videoCall), presentationData: presentationData, present: { c, a in
                        present(c, a)
                    }, openSettings: {
                        openSettings()
                    }, { [weak strongSelf] value in
                        guard let strongSelf else {
                            return
                        }
                        if value {
                            if strongSelf.incomingConferenceSource != nil {
                                strongSelf.conferenceStateValue = .preparing
                                strongSelf.isAcceptingIncomingConference = true
                                strongSelf.sessionStateDisposable?.dispose()
                                strongSelf.updateSessionState(sessionState: CallSession(
                                    id: strongSelf.internalId,
                                    stableId: strongSelf.conferenceStableId,
                                    isOutgoing: false,
                                    type: strongSelf.isVideo ? .video : .audio,
                                    state: .ringing,
                                    isVideoPossible: true
                                ),
                                callContextState: nil, reception: nil, audioSessionControl: strongSelf.audioSessionControl)
                            } else {
                                strongSelf.callSessionManager.accept(internalId: strongSelf.internalId)
                            }
                            
                            if !fromCallKitAction {
                                strongSelf.callKitIntegration?.answerCall(uuid: strongSelf.internalId)
                            }
                        } else {
                            let _ = strongSelf.hangUp().start()
                        }
                    })
                } else {
                    if strongSelf.incomingConferenceSource != nil {
                        strongSelf.conferenceStateValue = .preparing
                        strongSelf.isAcceptingIncomingConference = true
                        strongSelf.sessionStateDisposable?.dispose()
                        strongSelf.updateSessionState(sessionState: CallSession(
                            id: strongSelf.internalId,
                            stableId: strongSelf.conferenceStableId,
                            isOutgoing: false,
                            type: .audio,
                            state: .ringing,
                            isVideoPossible: true
                        ),
                        callContextState: nil, reception: nil, audioSessionControl: strongSelf.audioSessionControl)
                    } else {
                        strongSelf.callSessionManager.accept(internalId: strongSelf.internalId)
                    }
                    
                    if !fromCallKitAction {
                        strongSelf.callKitIntegration?.answerCall(uuid: strongSelf.internalId)
                    }
                }
            } else {
                let _ = strongSelf.hangUp().start()
            }
        })
    }
    
    public func hangUp() -> Signal<Bool, NoError> {
        if self.isMovedToConference {
            return .single(true)
        }
        // Zenlygram — the user is ending the call: the recording ends with it, now, rather than
        // after the session state reaches `.terminated` (audit #59).
        self.callRecordingOutcomesUseMainWindow = true
        self.stopRecording()
        let debugLogValue = Promise<String?>()

        self.callSessionManager.drop(internalId: self.internalId, reason: .hangUp, debugLog: debugLogValue.get())
        if let conferenceCallContext = self.conferenceCallContext {
            debugLogValue.set(conferenceCallContext.debugLog.get())
            let _ = conferenceCallContext.leave(terminateIfPossible: false).startStandalone()
        } else {
            self.ongoingContext?.stop(debugLogValue: debugLogValue)
        }
        
        return self.hungUpPromise.get()
    }
    
    public func rejectBusy() {
        if self.isMovedToConference {
            return
        }
        self.callSessionManager.drop(internalId: self.internalId, reason: .busy, debugLog: .single(nil))
        let debugLog = Promise<String?>()
        if let conferenceCallContext = self.conferenceCallContext {
            debugLog.set(conferenceCallContext.debugLog.get())
            let _ = conferenceCallContext.leave(terminateIfPossible: false).startStandalone()
        } else {
            self.ongoingContext?.stop(debugLogValue: debugLog)
        }
    }
    
    public func toggleIsMuted() {
        if self.isMovedToConference {
            return
        }
        self.setIsMuted(!self.isMutedValue)
    }
    
    public func setIsMuted(_ value: Bool) {
        if self.isMovedToConference {
            return
        }
        self.isMutedValue = value
        self.isMutedPromise.set(self.isMutedValue)
        // Zenlygram — mute is applied DOWNSTREAM of the recording tap (the tap sits on the audio
        // device; `setMuteMicrophone` reaches the outgoing audio channel), so the recorder has to be
        // told explicitly or it would capture speech the other party never heard.
        self.callRecordingSession?.setIsMicrophoneMuted(value)
        if let conferenceCallContext = self.conferenceCallContext {
            conferenceCallContext.setIsMuted(action: value ? .muted(isPushToTalkActive: false) : .unmuted)
        } else {
            self.ongoingContext?.setIsMuted(self.isMutedValue)
        }
    }
    
    // MARK: Zenlygram — local call recording.
    //
    // THREE GATES, all of which must pass before a single sample is written:
    //   1. `sgCallRecordingAvailable`, the compile-time flag (checked here and again inside the
    //      session, so no entry point can forget it);
    //   2. the one-time consent, stored in SGSimpleSettings and checked inside the session — the UI
    //      presents the screen first, but the recorder refuses on its own if it was not accepted;
    //   3. the tap has to exist: when the `ios_killswitch_disable_call_device` app-config switch is
    //      set, `sharedAudioContext` is nil and the 1:1 bridge builds a raw AudioDeviceModuleIOS
    //      with no wrapper around it, so the tap would never fire and the recording would be an
    //      empty file with no error at all. The button is disabled instead.
    //
    // v1 is 1:1 only: a conference records N people who never saw this user's consent screen, and
    // the tap hands back an opaque mix with no per-speaker separation anyway.
    public var canStartRecording: Bool {
        if !self.canStartRecordingIgnoringCallKit {
            return false
        }
        // GATE 4, and it is an Apple 2.5.14 gate rather than a technical one. CallKit is the only
        // surface this app can draw on while it is backgrounded — there is no ActivityKit / Live
        // Activity and no widget extension anywhere in it — so with `callKitIntegration == nil` the
        // badge, the toast and the minimised call bar all leave with the app and NOTHING says the
        // call is being recorded. That is precisely the configuration the guideline is about, and
        // it is one toggle away (Settings > Privacy & Security > Calls > iOS Call Integration; see
        // `callKitIntegrationIfEnabled` in PresentationCallManager.swift). The system call/mic
        // indicator does not close the gap: it is present on every call, recording or not.
        //
        // So recording is refused there rather than run without an indication. The call screen
        // still offers the button and explains why it cannot start — see
        // `callRecordingRequiresCallKit`.
        if self.callKitIntegration == nil {
            return false
        }
        return true
    }

    /// Everything except the CallKit requirement. Used only to decide whether the button is worth
    /// showing at all.
    private var canStartRecordingIgnoringCallKit: Bool {
        if !sgCallRecordingAvailable {
            return false
        }
        if self.isMovedToConference {
            return false
        }
        // Audit #8: refused from the moment a conference upgrade begins, not only once it is done.
        if self.conferenceCallContext != nil || self.conferenceCallImpl != nil || self.conferenceStateValue != nil {
            return false
        }
        if self.sharedAudioContext?.audioDevice == nil {
            return false
        }
        // Audit #59: only a connected, unfinished 1:1 call. Before it connects the far side has not
        // answered (a notice would go to someone who never heard the call), and after hang-up the
        // audio session stays up for the end tone, so the tap would record the room.
        if !self.isCallConnectedForRecording {
            return false
        }
        return true
    }

    private var isCallConnectedForRecording: Bool {
        guard let sessionState = self.sessionState, case .active = sessionState.state else {
            return false
        }
        guard let callContextState = self.callContextState else {
            return false
        }
        switch callContextState.state {
        case .connected, .reconnecting:
            return true
        case .initializing, .failed:
            return false
        }
    }

    /// True when the ONLY thing standing between this call and a recording is iOS Call Integration
    /// being switched off. The call screen keeps the button visible in that case and explains the
    /// requirement on tap, rather than making the feature silently disappear.
    ///
    /// Audit #116: false where CallKit cannot exist at all (China region, the legacy notifications
    /// fix, the simulator) — there is no switch to send the user to, so the button is not offered.
    public var callRecordingRequiresCallKit: Bool {
        return CallKitIntegration.isAvailable && self.canStartRecordingIgnoringCallKit && self.callKitIntegration == nil
    }

    /// The other party's display name for the recording's title and the CallKit marker: the peer
    /// the call was created with, or the one resolved from `peerId` for outgoing calls. Empty only
    /// while that lookup has not answered yet.
    private func callRecordingPeerTitle() -> String {
        guard let peer = self.peer ?? self.callRecordingResolvedPeer else {
            return ""
        }
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        return peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
    }

    /// Only ever called from an explicit user action on the call screen. Nothing in this app starts
    /// a recording by itself, under any setting.
    public func startRecording() {
        if self.callRecordingSession != nil {
            return
        }
        guard self.canStartRecording, let audioDevice = self.sharedAudioContext?.audioDevice else {
            return
        }

        let session = SGCallRecordingSession(peerTitle: self.callRecordingPeerTitle(), accountPeerId: self.context.account.peerId.toInt64(), peerId: self.peerId.toInt64())
        let started = session.start(isMicrophoneMuted: self.isMutedValue, attachSink: { sink in
            let disposable = audioDevice.addAudioTap(sink)
            return {
                disposable.dispose()
            }
        })
        if !started {
            self.updateIsRecording(false)
            // The session refused before a single sample was written. `.unavailable` / `.noConsent`
            // are already visible to the user (no button, or the consent screen they just
            // declined); a storage refusal is not, so it is reported.
            switch session.stateValue {
            case .failed(.noSpace):
                self.reportCallRecordingOutcome(.noSpace)
            case .failed(.storage):
                self.reportCallRecordingOutcome(.lost)
            case .failed(.accountCleanupPending):
                // The user tapped Record and accepted consent: a silent no-op would read as a
                // broken button. Say why, without implying anything was recorded.
                self.reportCallRecordingOutcome(.cannotStartCleanupPending)
            default:
                break
            }
            return
        }

        // Subscribed only once the session is actually recording: the state promise replays its
        // current value on subscription, so subscribing before `start()` would deliver the initial
        // `.idle` synchronously and immediately tear the session down again.
        self.callRecordingSession = session
        self.callRecordingStateDisposable?.dispose()
        self.callRecordingStateDisposable = (session.state
        |> deliverOnMainQueue).start(next: { [weak self, weak session] state in
            guard let self else {
                return
            }
            switch state {
            case .recording:
                self.updateIsRecording(true)
            case .idle:
                self.updateIsRecording(false)
                if self.callRecordingSession === session {
                    self.callRecordingSession = nil
                }
                self.offerSavedCallRecording(session: session)
            case let .finished(problem):
                self.updateIsRecording(false)
                if self.callRecordingSession === session {
                    self.callRecordingSession = nil
                }
                switch problem {
                case .truncated:
                    self.reportCallRecordingOutcome(.truncated)
                }
                // A truncated recording is still a recording: it plays, it is listed, and the user
                // was told it stops early. Withholding it from a delivery they switched on would be
                // a second, silent loss on top of the first one.
                self.offerSavedCallRecording(session: session)
            case let .failed(reason):
                self.updateIsRecording(false)
                if self.callRecordingSession === session {
                    self.callRecordingSession = nil
                }
                switch reason {
                case .storage:
                    self.reportCallRecordingOutcome(.lost)
                case .noSpace:
                    self.reportCallRecordingOutcome(.noSpace)
                case .unavailable, .noConsent, .accountCleanupPending:
                    break
                }
            case .finishing:
                break
            }
        })

        self.updateIsRecording(true)

        if SGCallRecordingGate.notifyOtherParty {
            self.sendCallRecordingNotice()
        }
    }

    /// Every recording outcome goes through here. While the 1:1 call screen is up it is handed to
    /// that screen (which also falls back to the main window when minimised); once the screen is
    /// leaving it goes straight to the main window, which outlives the call screen and the call.
    private func reportCallRecordingOutcome(_ outcome: SGCallRecordingOutcome) {
        if self.callRecordingOutcomesUseMainWindow {
            sgPresentCallRecordingOutcomeInMainWindow(sharedContext: self.context.sharedContext, outcome: outcome)
        } else {
            self.callRecordingOutcomePipe.putNext(outcome)
        }
    }

    /// Hands a recording that has just finished being written to the Saved Messages delivery.
    ///
    /// It does nothing unless the "Send to Saved Messages" setting is on — the gate lives in
    /// `SGCallRecordingDelivery.recordingFinished`, in one place, rather than being re-derived at
    /// every call site. `savedRecordingId` is nil when nothing was saved (nothing was written, or
    /// the user deleted the recording while the call was still running), so a failed or discarded
    /// recording never reaches it.
    private func offerSavedCallRecording(session: SGCallRecordingSession?) {
        guard let recordingId = session?.savedRecordingId else {
            return
        }
        SGCallRecordingDelivery.shared.recordingFinished(context: self.context, id: recordingId)
    }

    public func stopRecording() {
        guard let session = self.callRecordingSession else {
            return
        }
        session.stop()
        // THE INDICATOR IS NOT CLEARED HERE. `stop()` only REQUESTS the native tap detach: the
        // disposable hops through `_audioDeviceModule->perform(...)` onto the tgcalls worker thread
        // and both OngoingCallThreadLocalContext.mm and OngoingCallContext.swift say outright that
        // "removal is asynchronous, so the block can still fire for a short while afterwards".
        // Clearing every indication in this same runloop turn meant microphone buffers captured
        // after the user was told recording had ended could still be encoded into the file.
        // `.idle` / `.finished` / `.failed` are published only after `finalizeStream()`, i.e. once
        // further writes are impossible, and `.finishing` keeps the indicator up in between.
        //
        // If the session was not actually recording, nothing will be published, so clear now.
        if !session.stateValue.isActive {
            self.updateIsRecording(false)
        }
    }

    private func updateIsRecording(_ value: Bool) {
        if self.isRecordingValue == value {
            return
        }
        self.isRecordingValue = value
        self.isRecordingPromise.set(value)

        // The only app-controlled pixels while the app is backgrounded belong to CallKit: there is
        // no ActivityKit / Live Activity anywhere in this app and no widget extension that could
        // host one. So the lock screen and the system call banner carry the marker, and the in-app
        // indicators (call screen + minimised call bar) cover everything else.
        // `CallKitProviderDelegate` remembers the name each call was reported with and restores it
        // itself before the call is reported ended (dropCall, CXEndCallAction), so the marker is
        // not what the ended call carries into Recents (audit #60), and a stop never blanks the
        // caller name (audit #11).
        if let callKitIntegration = self.callKitIntegration {
            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            let title = self.callRecordingPeerTitle()
            // The marker word is resolved here, where the presentation data already is, and uses the
            // same SGStrings key as the on-screen badge (CallControllerNodeV2) so the lock screen
            // and the call screen never disagree — and never fall back to English.
            let recordingMarker = i18n("CallRecording.Indicator.Short", presentationData.strings.baseLanguageCode)
            callKitIntegration.updateCallRecordingIndicator(uuid: self.internalId, displayTitle: title, recordingMarker: recordingMarker, isRecording: value)
        }
    }

    /// The optional "tell the other party" notice, default OFF.
    ///
    /// It sends a real message into the chat and plays a tone in the USER'S OWN ear. It cannot put
    /// audio into the outgoing stream: `addExternalAudioSamples` is an empty default on every
    /// tgcalls implementation this app negotiates (tgcalls/Instance.h:199), and `setTone:` mixes
    /// into the local playout buffer only. The setting's description says exactly this — a switch
    /// called "notify the other party" that only beeped into the user's own ear would be the worst
    /// possible outcome here.
    private func sendCallRecordingNotice() {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        let text = i18n("CallRecording.Notice.Message", lang)
        let engine = self.context.engine
        // Audit #117: the notice is the whole point of the setting, so its fate is followed instead
        // of fired and forgotten. A peer that needs Stars or Premium to be messaged, a block, a
        // privacy refusal — each leaves a `.Failed` message in a chat the user is not looking at,
        // while they go on believing the other person was told. A message that disappears was
        // replaced by its sent cloud copy. Still pending after the bound: the user is told it is
        // NOT confirmed — a slow network is not called a failure, but it is not called a success
        // either.
        //
        // The subscription is deliberately not owned by the call: it is bounded by the timeout,
        // and it has to report even when the call (and its screen) is gone by then — through the
        // call while it exists, through the main window after.
        //
        // "The local message is gone" is NOT proof of sending: the user can delete or cancel it.
        // The only proof is the correlation id `PendingMessageManager` maps to the server's id when
        // the server accepts the message (registered before the local copy is removed) — and only a
        // Cloud-namespace id in this same chat counts (the pattern
        // `SGCallRecordingDelivery.confirmedCloudMessageId` uses).
        let sharedContext = self.context.sharedContext
        let chatPeerId = self.peerId
        let correlationId = Int64.random(in: Int64.min ... Int64.max)
        let confirmedSent: () -> Bool = {
            guard let sentId = engine.messages.synchronouslyLookupCorrelationId(correlationId: correlationId) else {
                return false
            }
            return sentId.namespace == Namespaces.Message.Cloud && sentId.peerId == chatPeerId
        }
        let _ = (enqueueMessages(account: self.context.account, peerId: self.peerId, messages: [
            .message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: correlationId, bubbleUpEmojiOrStickersets: [])
        ])
        |> mapToSignal { messageIds -> Signal<SGCallRecordingOutcome?, NoError> in
            guard let messageId = messageIds.first.flatMap({ $0 }) else {
                // Not even enqueued.
                return .single(.noticeNotDelivered)
            }
            return engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
            |> mapToSignal { message -> Signal<SGCallRecordingOutcome?, NoError> in
                if let message, message.flags.contains(.Failed) {
                    return .single(.noticeNotDelivered)
                }
                if let message, message.flags.contains(.Unsent) {
                    // Still on its way.
                    return .complete()
                }
                // Gone, or no longer pending: sent only if the server's id says so.
                return .single(confirmedSent() ? nil : .noticeUnconfirmed)
            }
            |> take(1)
        }
        |> timeout(sgCallRecordingNoticeObservationTimeout, queue: Queue.mainQueue(), alternate: .single(.noticeUnconfirmed))
        |> deliverOnMainQueue).start(next: { [weak self] outcome in
            guard let outcome else {
                return
            }
            if let self {
                self.reportCallRecordingOutcome(outcome)
            } else {
                sgPresentCallRecordingOutcomeInMainWindow(sharedContext: sharedContext, outcome: outcome)
            }
        })

        // `setTone:` is a single-slot channel owned by this call's tone state machine, and
        // `updateTone` only re-issues a tone when it differs from `self.currentTone`. Writing the
        // beeps straight into the slot while ringback (loopCount 1000000) or the reconnect tone is
        // playing would replace it, end after ~0.33 s, and leave `currentTone` still reading
        // `.ringing` — so nothing would ever restore it and the user would hear silence for the
        // rest of the ring. The chat message is what the setting is actually for; the local beeps
        // are a courtesy and are skipped when the slot is in use.
        if self.currentTone == nil {
            self.sharedAudioContext?.audioDevice?.setTone(tone: OngoingCallContext.Tone(samples: sgCallRecordingNoticeToneData(), sampleRate: 48000, loopCount: 1))
        }
    }

    public func requestVideo() {
        if self.isMovedToConference {
            return
        }
        if self.videoCapturer == nil {
            let videoCapturer = OngoingCallVideoCapturer()
            self.videoCapturer = videoCapturer
        }
        if let videoCapturer = self.videoCapturer {
            if let conferenceCallContext = self.conferenceCallContext {
                conferenceCallContext.requestVideo(capturer: videoCapturer)
            } else if let ongoingContext = self.ongoingContext {
                ongoingContext.requestVideo(videoCapturer)
            }
        }
    }
    
    public func requestVideo(capturer: OngoingCallVideoCapturer) {
        if self.isMovedToConference {
            return
        }
        if self.videoCapturer == nil {
            self.videoCapturer = capturer
        }
        if let videoCapturer = self.videoCapturer {
            if let conferenceCallContext = self.conferenceCallContext {
                conferenceCallContext.requestVideo(capturer: videoCapturer)
            } else if let ongoingContext = self.ongoingContext {
                ongoingContext.requestVideo(videoCapturer)
            }
        }
    }
    
    public func setRequestedVideoAspect(_ aspect: Float) {
        if self.isMovedToConference {
            return
        }
        self.requestedVideoAspect = aspect
        self.ongoingContext?.setRequestedVideoAspect(aspect)
    }
    
    public func disableVideo() {
        if self.isMovedToConference {
            return
        }
        if let _ = self.videoCapturer {
            self.videoCapturer = nil
            if let conferenceCallContext = self.conferenceCallContext {
                conferenceCallContext.disableVideo()
            } else if let ongoingContext = self.ongoingContext {
                ongoingContext.disableVideo()
            }
        }
    }

    private func resetScreencastContext() {
        if self.isMovedToConference {
            return
        }
        let basePath = self.context.sharedContext.basePath + "/broadcast-coordination"
        let screencastBufferServerContext = IpcGroupCallBufferAppContext(basePath: basePath)
        self.screencastBufferServerContext = screencastBufferServerContext

        self.screencastFramesDisposable.set((screencastBufferServerContext.frames
        |> deliverOnMainQueue).start(next: { [weak screencastCapturer] screencastFrame in
            guard let screencastCapturer = screencastCapturer else {
                return
            }
            guard let sampleBuffer = sampleBufferFromPixelBuffer(pixelBuffer: screencastFrame.0) else {
                return
            }
            
            screencastCapturer.injectSampleBuffer(sampleBuffer, rotation: screencastFrame.1, completion: {})
        }))
        self.screencastAudioDataDisposable.set((screencastBufferServerContext.audioData
        |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let strongSelf = self else {
                return
            }
            if let conferenceCallContext = strongSelf.conferenceCallContext {
                conferenceCallContext.genericCallContext?.addExternalAudioData(data: data)
            } else {
                strongSelf.ongoingContext?.addExternalAudioData(data: data)
            }
        }))
        self.screencastStateDisposable.set((screencastBufferServerContext.isActive
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak self] isActive in
            guard let strongSelf = self else {
                return
            }
            if isActive {
                strongSelf.requestScreencast()
            } else {
                strongSelf.disableScreencast(reset: false)
            }
        }))
    }

    private func requestScreencast() {
        if self.isMovedToConference {
            return
        }
        self.disableVideo()

        if let screencastCapturer = self.screencastCapturer {
            self.isScreencastActive = true
            if let conferenceCallContext = self.conferenceCallContext {
                conferenceCallContext.requestVideo(capturer: screencastCapturer)
            } else if let ongoingContext = self.ongoingContext {
                ongoingContext.requestVideo(screencastCapturer)
            }
        }
    }

    func disableScreencast(reset: Bool = true) {
        if self.isMovedToConference {
            return
        }
        if self.isScreencastActive {
            if let _ = self.videoCapturer {
                self.videoCapturer = nil
            }
            self.isScreencastActive = false
            self.conferenceCallContext?.disableVideo()
            self.ongoingContext?.disableVideo()
            self.conferenceCallImpl?.disableVideo()
            if reset {
                self.resetScreencastContext()
            }
        }
    }
    
    public func setOutgoingVideoIsPaused(_ isPaused: Bool) {
        if self.isMovedToConference {
            return
        }
        self.videoCapturer?.setIsVideoEnabled(!isPaused)
    }
    
    public func upgradeToConference(invitePeers: [(id: EnginePeer.Id, isVideo: Bool)], completion: @escaping (PresentationGroupCall) -> Void) -> Disposable {
        if self.isMovedToConference {
            return EmptyDisposable
        }
        if let conferenceCall = self.conferenceCall {
            completion(conferenceCall)
            return EmptyDisposable
        }
        
        self.pendingInviteToConferencePeerIds = invitePeers
        let index = self.upgradedToConferenceCompletions.add({ call in
            completion(call)
        })
        
        self.conferenceStateValue = .preparing
        self.callSessionManager.createConferenceIfNecessary(internalId: self.internalId)
        
        return ActionDisposable { [weak self] in
            Queue.mainQueue().async {
                guard let self else {
                    return
                }
                self.upgradedToConferenceCompletions.remove(index)
            }
        }
    }
    
    public func setCurrentAudioOutput(_ output: AudioSessionOutput) {
        if self.isMovedToConference {
            return
        }
        if let sharedAudioContext = self.sharedAudioContext {
            sharedAudioContext.setCurrentAudioOutput(output)
            return
        }
        
        guard self.currentAudioOutputValue != output else {
            return
        }
        self.currentAudioOutputValue = output
        self.didSetCurrentAudioOutputValue = true
        
        self.audioOutputStatePromise.set(.single((self.audioOutputStateValue.0, output))
        |> then(
            .single(self.audioOutputStateValue)
            |> delay(1.0, queue: Queue.mainQueue())
        ))
        
        if let audioSessionControl = self.audioSessionControl {
            if let callKitIntegration = self.callKitIntegration {
                callKitIntegration.applyVoiceChatOutputMode(outputMode: .custom(self.currentAudioOutputValue))
            } else {
                audioSessionControl.setOutputMode(.custom(output))
            }
        }
    }
    
    public func debugInfo() -> Signal<(String, String), NoError> {
        return self.debugInfoValue.get()
    }
    
    func video(isIncoming: Bool) -> Signal<OngoingGroupCallContext.VideoFrameData, NoError>? {
        if self.isMovedToConference {
            return nil
        }
        if isIncoming {
            if let conferenceCallContext = self.conferenceCallContext {
                return conferenceCallContext.video(endpointId: self.remoteVideoEndpointId ?? "any_remote")
            } else if let ongoingContext = self.ongoingContext {
                return ongoingContext.video(isIncoming: isIncoming)
            } else {
                return nil
            }
        } else if let videoCapturer = self.videoCapturer {
            return videoCapturer.video()
        } else {
            return nil
        }
    }
    
    public func makeOutgoingVideoView(completion: @escaping (PresentationCallVideoView?) -> Void) {
        if self.isMovedToConference {
            completion(nil)
            return
        }
        if self.videoCapturer == nil {
            let videoCapturer = OngoingCallVideoCapturer()
            self.videoCapturer = videoCapturer
        }
        
        self.videoCapturer?.makeOutgoingVideoView(requestClone: false, completion: { view, _ in
            if let view = view {
                let setOnFirstFrameReceived = view.setOnFirstFrameReceived
                let setOnOrientationUpdated = view.setOnOrientationUpdated
                let setOnIsMirroredUpdated = view.setOnIsMirroredUpdated
                let updateIsEnabled = view.updateIsEnabled
                completion(PresentationCallVideoView(
                    holder: view,
                    view: view.view,
                    setOnFirstFrameReceived: { f in
                        setOnFirstFrameReceived(f)
                    },
                    getOrientation: { [weak view] in
                        if let view = view {
                            let mappedValue: PresentationCallVideoView.Orientation
                            switch view.getOrientation() {
                            case .rotation0:
                                mappedValue = .rotation0
                            case .rotation90:
                                mappedValue = .rotation90
                            case .rotation180:
                                mappedValue = .rotation180
                            case .rotation270:
                                mappedValue = .rotation270
                            }
                            return mappedValue
                        } else {
                            return .rotation0
                        }
                    },
                    getAspect: { [weak view] in
                        if let view = view {
                            return view.getAspect()
                        } else {
                            return 0.0
                        }
                    },
                    setOnOrientationUpdated: { f in
                        setOnOrientationUpdated { value, aspect in
                            let mappedValue: PresentationCallVideoView.Orientation
                            switch value {
                            case .rotation0:
                                mappedValue = .rotation0
                            case .rotation90:
                                mappedValue = .rotation90
                            case .rotation180:
                                mappedValue = .rotation180
                            case .rotation270:
                                mappedValue = .rotation270
                            }
                            f?(mappedValue, aspect)
                        }
                    },
                    setOnIsMirroredUpdated: { f in
                        setOnIsMirroredUpdated { value in
                            f?(value)
                        }
                    },
                    updateIsEnabled: { value in
                        updateIsEnabled(value)
                    }
                ))
            } else {
                completion(nil)
            }
        })
    }
    
    public func switchVideoCamera() {
        if self.isMovedToConference {
            return
        }
        self.useFrontCamera = !self.useFrontCamera
        self.videoCapturer?.switchVideoInput(isFront: self.useFrontCamera)
    }
    
    public func playRemoteCameraTone() {
        let name: String
        name = "voip_group_recording_started.mp3"

        self.beginTone(tone: .custom(name: name, loopCount: 1))
    }
    
    private func beginTone(tone: PresentationCallTone?) {
        if let tone, let toneData = presentationCallToneData(tone) {
            if let sharedAudioContext = self.sharedAudioContext {
                sharedAudioContext.audioDevice?.setTone(tone: OngoingCallContext.Tone(
                    samples: toneData,
                    sampleRate: 48000,
                    loopCount: tone.loopCount ?? 100000
                ))
            }
        } else {
            if let sharedAudioContext = self.sharedAudioContext {
                sharedAudioContext.audioDevice?.setTone(tone: nil)
            }
        }
    }
    
    func deactivateIncomingAudio() {
        if let conferenceCallContext = self.conferenceCallContext {
            let _ = conferenceCallContext
            //TODO:release
        } else {
            self.ongoingContext?.deactivateIncomingAudio()
        }
    }
}

func sampleBufferFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    var maybeFormat: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &maybeFormat)
    if status != noErr {
        return nil
    }
    guard let format = maybeFormat else {
        return nil
    }

    var timingInfo = CMSampleTimingInfo(
        duration: CMTimeMake(value: 1, timescale: 30),
        presentationTimeStamp: CMTimeMake(value: 0, timescale: 30),
        decodeTimeStamp: CMTimeMake(value: 0, timescale: 30)
    )

    var maybeSampleBuffer: CMSampleBuffer?
    let bufferStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timingInfo, sampleBufferOut: &maybeSampleBuffer)

    if (bufferStatus != noErr) {
        return nil
    }
    guard let sampleBuffer = maybeSampleBuffer else {
        return nil
    }

    let attachments: NSArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)! as NSArray
    let dict: NSMutableDictionary = attachments[0] as! NSMutableDictionary
    dict[kCMSampleAttachmentKey_DisplayImmediately as NSString] = true as NSNumber

    return sampleBuffer
}
