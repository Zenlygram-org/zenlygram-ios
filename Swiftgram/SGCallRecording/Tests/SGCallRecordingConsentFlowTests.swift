import XCTest

@testable import SGCallRecording

/// Zenlygram — the call screen's Record tap: one prompt at a time, consent stored and a recording
/// started only for the prompt that is still current and only while the call can still record,
/// nothing after the call ended; and what an empty recordings list may point the user to. Pure
/// state: proves nothing about the alert UI, CallKit or a real call.
final class SGCallRecordingConsentFlowTests: XCTestCase {
    private let startable = SGCallRecordingCallStatus(isRecording: false, canStart: true, requiresCallKit: false)
    private let recording = SGCallRecordingCallStatus(isRecording: true, canStart: true, requiresCallKit: false)
    private let notStartable = SGCallRecordingCallStatus(isRecording: false, canStart: false, requiresCallKit: false)
    private let callKitOff = SGCallRecordingCallStatus(isRecording: false, canStart: false, requiresCallKit: true)

    private func askConsent(_ flow: SGCallRecordingConsentFlow, file: StaticString = #filePath, line: UInt = #line) -> SGCallRecordingPromptTicket? {
        guard case let .askConsent(ticket) = flow.tap(status: self.startable, consentAccepted: false) else {
            XCTFail("expected a consent prompt", file: file, line: line)
            return nil
        }
        return ticket
    }

    func testRapidSecondTapWhileConsentIsOpenPresentsNothing() throws {
        let flow = SGCallRecordingConsentFlow()
        _ = try XCTUnwrap(self.askConsent(flow))

        XCTAssertEqual(flow.tap(status: self.startable, consentAccepted: false), .ignore)
        XCTAssertEqual(flow.tap(status: self.startable, consentAccepted: false), .ignore)
        XCTAssertTrue(flow.isPromptPending)
    }

    func testAcceptOnStillStartableCallStartsExactlyOnce() throws {
        let flow = SGCallRecordingConsentFlow()
        let ticket = try XCTUnwrap(self.askConsent(flow))

        XCTAssertEqual(flow.accept(ticket, status: self.startable), .acceptAndStart)
        // A second delivery of the same answer is not a second start.
        XCTAssertEqual(flow.accept(ticket, status: self.startable), .discard)
        XCTAssertFalse(flow.isPromptPending)
    }

    func testAcceptAfterCallStoppedBeingRecordableStoresAndStartsNothing() throws {
        let flow = SGCallRecordingConsentFlow()
        let ticket = try XCTUnwrap(self.askConsent(flow))

        // Hung up, moved to a conference, dropped back to connecting: the recorder would refuse.
        XCTAssertEqual(flow.accept(ticket, status: self.notStartable), .discard)
        XCTAssertFalse(flow.isPromptPending)
    }

    func testAcceptAfterCallEndedIsDiscardedEvenIfStatusLooksStartable() throws {
        let flow = SGCallRecordingConsentFlow()
        let ticket = try XCTUnwrap(self.askConsent(flow))

        flow.callEnded()

        XCTAssertEqual(flow.accept(ticket, status: self.startable), .discard)
        XCTAssertEqual(flow.tap(status: self.startable, consentAccepted: true), .ignore)
        XCTAssertEqual(flow.tap(status: self.startable, consentAccepted: false), .ignore)
    }

    func testCancelStartsNothingAndAllowsANewExplicitTap() throws {
        let flow = SGCallRecordingConsentFlow()
        let first = try XCTUnwrap(self.askConsent(flow))

        flow.promptClosed(first)

        XCTAssertFalse(flow.isPromptPending)
        XCTAssertEqual(flow.accept(first, status: self.startable), .discard)
        let second = try XCTUnwrap(self.askConsent(flow))
        XCTAssertNotEqual(first, second)
    }

    func testStalePromptCannotBeAcceptedOrCloseTheCurrentOne() throws {
        let flow = SGCallRecordingConsentFlow()
        let stale = try XCTUnwrap(self.askConsent(flow))
        flow.abandonPendingPrompt()
        let current = try XCTUnwrap(self.askConsent(flow))

        flow.promptClosed(stale)
        XCTAssertTrue(flow.isPromptPending)
        XCTAssertEqual(flow.accept(stale, status: self.startable), .discard)
        XCTAssertEqual(flow.accept(current, status: self.startable), .acceptAndStart)
    }

    func testPriorConsentStartsOnlyOnAStartableCall() {
        let flow = SGCallRecordingConsentFlow()

        XCTAssertEqual(flow.tap(status: self.notStartable, consentAccepted: true), .ignore)
        XCTAssertEqual(flow.tap(status: self.startable, consentAccepted: true), .start)
        XCTAssertFalse(flow.isPromptPending)
    }

    func testStopIsHonouredEvenAfterTheCallEnded() {
        let flow = SGCallRecordingConsentFlow()
        XCTAssertEqual(flow.tap(status: self.recording, consentAccepted: false), .stop)

        flow.callEnded()

        XCTAssertEqual(flow.tap(status: self.recording, consentAccepted: true), .stop)
    }

    func testCallKitOffExplainsOnceAndNeverAsksConsent() {
        let flow = SGCallRecordingConsentFlow()

        guard case let .explainCallKitRequirement(ticket) = flow.tap(status: self.callKitOff, consentAccepted: false) else {
            return XCTFail("expected the iOS Call Integration explanation")
        }
        XCTAssertEqual(flow.tap(status: self.callKitOff, consentAccepted: false), .ignore)
        // The explanation is not a consent prompt: answering it can never start a recording.
        XCTAssertEqual(flow.accept(ticket, status: self.callKitOff), .discard)
        flow.promptClosed(ticket)
        guard case .explainCallKitRequirement = flow.tap(status: self.callKitOff, consentAccepted: true) else {
            return XCTFail("expected the explanation again, never a start")
        }
    }

    func testEmptyListGuidanceFollowsWhatTheCallScreenCanOffer() {
        XCTAssertEqual(SGCallRecordingStartSupport(isFeatureAvailable: false, isCallKitAvailable: true, isCallKitEnabled: true), .featureUnavailable)
        XCTAssertEqual(SGCallRecordingStartSupport(isFeatureAvailable: false, isCallKitAvailable: false, isCallKitEnabled: false), .featureUnavailable)
        XCTAssertEqual(SGCallRecordingStartSupport(isFeatureAvailable: true, isCallKitAvailable: false, isCallKitEnabled: true), .unsupportedOnDevice)
        XCTAssertEqual(SGCallRecordingStartSupport(isFeatureAvailable: true, isCallKitAvailable: true, isCallKitEnabled: false), .requiresCallKit)
        XCTAssertEqual(SGCallRecordingStartSupport(isFeatureAvailable: true, isCallKitAvailable: true, isCallKitEnabled: true), .available)
    }
}
