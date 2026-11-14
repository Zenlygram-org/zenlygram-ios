import Foundation
import SwiftUI
import UIKit
import Combine
import Display
import LegacyUI
import TelegramPresentationData
import SGConfig
import SGCustomerSyncCore
import SGEntitlement
import SGStrings
import SGSwiftUI

// MARK: Zenlygram — "Link Telegram Account" (design §3.2).
//
// The app knows the user's Telegram id but cannot prove it: the source is public, so a two-line
// patch would make it claim any id. The proof therefore comes from Telegram itself. First,
// automatically (bind-attest v1): the app, signed in AS this account, asks Telegram over MTProto
// for a Mini App launch of the bind bot with this bind's `start_param`, and hands the `initData`
// TELEGRAM signed to the server — no code, no bot chat, no other app. When that is not possible
// (no `attest` from the server, a resolve mismatch, a Telegram or server error) it falls back to
// the code: the app asks the server for an 8-character code, the user confirms it in the bot
// (opened inside this app, for this account), and the bot's callback carries a `tg_user_id`
// signed by Telegram rather than by us. Under `SGLinkAccountAttestationPolicy.required` (Lenta) there
// is no fallback: without Telegram's confirmed attestation the attempt fails, and no code is shown.
//
// Two things about this screen are load-bearing:
//   * It is a SIGN-IN, which guideline 3.1.3 explicitly permits. It must never carry a price, a
//     plan, a Mini App button or any other purchase call to action — that is what `src: "ios"` buys
//     us on the bot's side, and this screen must hold up its half of the bargain.
//   * Nothing here is on the path to the user's own data. The vault and the chat locks are local
//     and stay usable whether or not this screen is ever opened.

/// Where the bind flow is. Rendered identically for every failure; the reason picks the message.
/// `.starting` covers the whole automatic part ("Linking…"); `.waiting` is the code fallback.
private enum SGLinkAccountPhase: Equatable {
    case idle
    case starting
    case waiting
    case failed(SGEntitlementMessage)
    case linked(mergeConflict: Bool)
    /// The user just unlinked this device. Nothing starts again by itself — not even here: a new
    /// link is the user's own tap (design 40 §8.2, compliance C-13).
    case unlinked
}

/// One start's automatic Telegram attestation (bind-attest v1).
private enum SGLinkAccountAttestation {
    /// Not decided yet for the current start: try it (again after an interrupted attempt).
    case pending
    /// The server confirmed the bind: poll at once, show no code.
    case confirmed
    /// Not possible or refused: the code flow.
    case fellBack
}

/// Whether a link screen may fall back from Telegram's automatic attestation to the code.
public enum SGLinkAccountAttestationPolicy: Equatable, Sendable {
    /// The attestation when it works, else the code confirmed in the bot (Pro, Tasks).
    case preferred
    /// The attestation or nothing (Lenta): no code, no bot chat and no poll without the server's
    /// confirmation. Always a fresh proof that keeps the stored session and the install key.
    case required
}

@MainActor
final class SGLinkAccountModel: ObservableObject {
    @Published fileprivate var phase: SGLinkAccountPhase = .idle
    @Published fileprivate var start: SGEntitlementBindStart?
    /// A transient hint ("No connection") shown WITHOUT abandoning the bind: the code lives for five
    /// minutes and a lift ride should not cost the user those five minutes.
    @Published fileprivate var hint: SGEntitlementMessage?
    @Published fileprivate var remainingSeconds: Int = 0
    @Published fileprivate var didCopyCode: Bool = false
    /// The current attempt may run the automatic attestation (the account has a usable grant,
    /// `SGLinkAccountFunnel.mayAttest`): the screen then discloses what it asks Telegram for.
    @Published fileprivate var attestMayRun: Bool = false

    let accountPeerId: Int64
    /// The linked Telegram account's own capabilities: attestation and in-app links.
    let telegram: SGLinkAccountTelegram
    /// Tasks proof mode: see `SGLinkAccountProofPolicy`. Always true under `.required`.
    let requiresTelegramProof: Bool
    let attestationPolicy: SGLinkAccountAttestationPolicy
    /// Called once, on the main actor, when THIS screen stored a binding from a confirmed Telegram
    /// proof for the current account and attempt. Never for an already-linked opening, a cancel or
    /// a failure.
    private let linked: (@MainActor @Sendable () -> Void)?
    private var didReportLinked = false
    private var task: Task<Void, Never>?
    private var lifecycle = SGLinkAccountLifecycle()
    private var pollBeganAt: TimeInterval = 0
    private var expiresAt: Date?
    private var attestation: SGLinkAccountAttestation = .pending
    private var startRequest = SGLinkAccountRequestSlot<Result<SGEntitlementBindStart, SGEntitlementRequestError>>()
    private var pollRequest = SGLinkAccountRequestSlot<Result<SGEntitlementBindPollResult, SGEntitlementRequestError>>()
    /// Restarts of `/bind/start` because the install key changed since the current start.
    private var keyRestarts = SGLinkAccountKeyRestartBudget()
    /// When the current attempt began (`begin()`, monotonic) until its one `link.attempt` is recorded.
    private var attemptBeganAt: TimeInterval?

    /// `nonisolated` so a controller factory can build it without being main-actor-isolated itself;
    /// everything it then touches is.
    nonisolated init(accountPeerId: Int64, telegram: SGLinkAccountTelegram, requiresTelegramProof: Bool = false, attestationPolicy: SGLinkAccountAttestationPolicy = .preferred, linked: (@MainActor @Sendable () -> Void)? = nil) {
        self.accountPeerId = accountPeerId
        self.telegram = telegram
        self.requiresTelegramProof = requiresTelegramProof || attestationPolicy == .required
        self.attestationPolicy = attestationPolicy
        self.linked = linked
    }

    deinit {
        self.task?.cancel()
    }

    var isCurrentAccount: Bool {
        SGEntitlement.shared.activeAccountPeerId == self.accountPeerId
    }

    func appear(isForeground: Bool) {
        self.lifecycle.setVisible(true)
        self.lifecycle.setForeground(isForeground)
        self.resumeIfNeeded()
    }

    func disappear() {
        self.lifecycle.setVisible(false)
        self.task?.cancel()
        self.task = nil
    }

    func setForeground(_ value: Bool) {
        self.lifecycle.setForeground(value)
        self.task?.cancel()
        self.task = nil
        if value {
            self.resumeIfNeeded()
        }
    }

    private func resumeIfNeeded() {
        guard self.lifecycle.isActive, self.isCurrentAccount, self.task == nil else { return }
        switch self.phase {
        case .idle:
            // A synchronous local read; opening this screen never waits for a refresh.
            if SGLinkAccountProofPolicy.opensAsLinked(hasStoredSession: SGEntitlement.shared.isLinked(accountPeerId: self.accountPeerId), requiresTelegramProof: self.requiresTelegramProof) {
                self.phase = .linked(mergeConflict: false)
            } else {
                self.begin()
            }
        case .starting, .waiting:
            self.launch()
        case .linked, .failed, .unlinked:
            break
        }
    }

    func begin() {
        guard self.isCurrentAccount else { return }
        self.task?.cancel()
        self.task = nil
        self.start = nil
        self.startRequest.reset()
        self.pollRequest.reset()
        self.expiresAt = nil
        self.attestation = .pending
        self.hint = nil
        self.didCopyCode = false
        self.keyRestarts.reset()
        self.attestMayRun = SGLinkAccountFunnel.mayAttest(permission: SGEntitlement.shared.bindPermission(accountPeerId: self.accountPeerId))
        self.attemptBeganAt = ProcessInfo.processInfo.systemUptime
        if self.attestationPolicy == .required, !self.attestMayRun {
            // Telegram's proof or nothing: without a usable grant nothing is started.
            self.fail(.linkingDidNotGoThrough, .didNotGoThrough)
            return
        }
        self.phase = .starting
        self.launch()
    }

    func unlink() {
        guard self.isCurrentAccount else { return }
        // First, synchronously: no automatic link for this account until a manual link or a new
        // grant (`suppressed: user_unlink`), so auto-link cannot re-link behind the logout.
        SGCustomerLinkEvents.userWillUnlink(accountPeerId: self.accountPeerId)
        // Local removal is synchronous. beginBind waits for the background revoke before starting
        // a replacement binding; neither operation cancels a subscription or deletes user data.
        SGEntitlement.shared.logout(accountPeerId: self.accountPeerId)
        // No new attempt here: with a grant it would attest and link the account straight back.
        self.task?.cancel()
        self.task = nil
        self.start = nil
        self.startRequest.reset()
        self.pollRequest.reset()
        self.expiresAt = nil
        self.hint = nil
        self.attemptBeganAt = nil
        self.phase = .unlinked
    }

    /// The attempt's terminal failure: the screen's message and its one `link.attempt{manual}`.
    private func fail(_ message: SGEntitlementMessage, _ reason: SGLinkAccountFunnel.FailureReason) {
        self.phase = .failed(message)
        self.recordAttempt(failure: reason)
    }

    /// One `link.attempt{trigger: manual}` per `begin()`.
    private func recordAttempt(failure: SGLinkAccountFunnel.FailureReason?) {
        guard let beganAt = self.attemptBeganAt else {
            return
        }
        self.attemptBeganAt = nil
        let attested: Bool
        if case .confirmed = self.attestation {
            attested = true
        } else {
            attested = false
        }
        let event = SGLinkAccountFunnel.attemptEvent(attested: attested, failure: failure, duration: ProcessInfo.processInfo.systemUptime - beganAt)
        SGAnalytics.record(event, accountPeerId: self.accountPeerId)
    }

    private func launch() {
        guard self.lifecycle.isActive, self.isCurrentAccount else { return }
        self.task?.cancel()
        let generation = self.lifecycle.beginRun()
        self.task = Task { [weak self] in
            guard let self else { return }
            if let start = self.start {
                await self.proceed(with: start, generation: generation)
            } else {
                // Proof mode never regenerates the install key (a stored session may be bound to it).
                await self.run(allowKeyRegeneration: SGLinkAccountProofPolicy.mayRegenerateKeyAndRestart(requiresTelegramProof: self.requiresTelegramProof), generation: generation)
            }
            if self.lifecycle.accepts(generation) {
                self.task = nil
            }
        }
    }

    private func accepts(_ generation: UUID) -> Bool {
        return !Task.isCancelled && self.lifecycle.accepts(generation) && self.isCurrentAccount
    }

    private func run(allowKeyRegeneration: Bool, generation: UUID) async {
        guard self.accepts(generation) else { return }
        if self.startRequest.current == nil {
            guard await self.waitForRequest(generation: generation, isPoll: false) else { return }
        }
        let accountPeerId = self.accountPeerId
        let request = self.startRequest.request {
            await SGEntitlement.shared.beginBind(accountPeerId: accountPeerId)
        }
        let response = await request.task.value
        let result = response.value
        if case let .failure(error) = result, case let .rateLimited(retryAfter) = error.failure {
            self.lifecycle.deferStart(seconds: Double(max(retryAfter, 1)), now: response.receivedAt)
        }
        guard self.accepts(generation) else { return }
        self.startRequest.consume(request.id)
        switch result {
        case let .success(value):
            self.start = value
            self.expiresAt = value.expiresAtDate ?? Date().addingTimeInterval(300.0)
            self.pollBeganAt = ProcessInfo.processInfo.systemUptime
            self.attestation = .pending
            await self.proceed(with: value, generation: generation)
        case let .failure(error):
            // A late invalid_pubkey response must not regenerate the key of a newer attempt.
            guard SGLinkAccountProofPolicy.appliesBindStartFailure(error.failure, requiresTelegramProof: self.requiresTelegramProof) else {
                // Proof mode: keep the key and any stored session untouched; show the failure and stop.
                self.fail(self.message(for: error), .request(error))
                return
            }
            SGEntitlement.shared.apply(error, credential: nil)
            if allowKeyRegeneration, case .refused(.invalidPubkey) = error.failure {
                await self.run(allowKeyRegeneration: false, generation: generation)
                return
            }
            self.fail(self.message(for: error), .request(error))
        }
    }

    /// The automatic attestation first (once per start), then the poll: at once after a confirmed
    /// attestation, with the code on screen after a fallback. `.required` has no fallback.
    private func proceed(with start: SGEntitlementBindStart, generation: UUID) async {
        if case .pending = self.attestation {
            let confirmed = await self.attest(start, generation: generation)
            // An interrupted attempt stays `.pending` and is tried again on resume.
            guard self.accepts(generation) else { return }
            guard confirmed || self.attestationPolicy == .preferred else {
                // Telegram's proof or nothing: no code, no bot chat, no poll. The user may try again.
                self.fail(.linkingDidNotGoThrough, .didNotGoThrough)
                return
            }
            self.attestation = confirmed ? .confirmed : .fellBack
        }
        if case .fellBack = self.attestation {
            self.phase = .waiting
            self.updateCountdown()
        }
        let confirmed: Bool
        if case .confirmed = self.attestation {
            confirmed = true
        } else {
            confirmed = false
        }
        await self.poll(start, generation: generation, pollNow: confirmed)
    }

    /// bind-attest v1. True only when the server confirmed THIS start from `initData` Telegram signed
    /// for this account. Any failure — no or malformed `attest`, the Telegram side, a key change, a
    /// server refusal — is false, which shows the code (under `.required` it fails the attempt).
    /// Neither `initData` nor the poll token is logged.
    ///
    /// Only for an account with a usable grant (`bindPermission == .allowed`, re-read here): without
    /// one this never asks Telegram for anything (`requestMainWebView`), the code is all there is.
    /// Under `.required` the `initData` is sent only while the account, the attempt and the grant are
    /// still the ones it was asked for.
    private func attest(_ start: SGEntitlementBindStart, generation: UUID) async -> Bool {
        guard SGLinkAccountFunnel.mayAttest(permission: SGEntitlement.shared.bindPermission(accountPeerId: self.accountPeerId)) else {
            self.attestMayRun = false
            return false
        }
        guard let attest = start.validatedAttest, let client = SGEntitlement.shared.client else {
            return false
        }
        guard let initData = await self.telegram.attest(attest), !Task.isCancelled else {
            return false
        }
        if self.attestationPolicy == .required {
            guard self.accepts(generation), SGLinkAccountFunnel.mayAttest(permission: SGEntitlement.shared.bindPermission(accountPeerId: self.accountPeerId)) else {
                return false
            }
        }
        let result = await client.bindAttest(pollToken: start.pollToken, registeredPublicKey: start.registeredPublicKey, initData: initData)
        if case .success(true) = result {
            return true
        }
        return false
    }

    private func poll(_ start: SGEntitlementBindStart, generation: UUID, pollNow: Bool) async {
        guard self.accepts(generation) else { return }
        guard let client = SGEntitlement.shared.client else {
            self.fail(.temporarilyUnavailable, .temporarilyUnavailable)
            return
        }
        // After a confirmed attestation the first poll goes out at once (still within any
        // Retry-After the IP budget asked for).
        var pollNow = pollNow
        while self.accepts(generation) {
            self.updateCountdown()
            if self.pollRequest.current == nil {
                guard let expiresAt = self.expiresAt, Date() < expiresAt else {
                    self.fail(.linkingCodeExpired, .codeExpired)
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                if !pollNow {
                    let base: Double = now - self.pollBeganAt < 60.0 ? 3.0 : 5.0
                    self.lifecycle.deferPoll(seconds: base + Double.random(in: -0.4 ... 0.8), now: now)
                }
                pollNow = false
                guard await self.waitForRequest(generation: generation, isPoll: true) else { return }
                self.updateCountdown()
                guard Date() < expiresAt else {
                    self.fail(.linkingCodeExpired, .codeExpired)
                    return
                }
            }
            // An already-issued poll can hold a valid confirmation even after the code expires.
            // Expiry gates new requests; it must not throw away a response received while hidden.
            let request = self.pollRequest.request { await client.bindPoll(pollToken: start.pollToken, registeredPublicKey: start.registeredPublicKey) }
            let response = await request.task.value
            let result = response.value
            // Even a stale response can carry the IP's poll budget. Keep it on resume or restart,
            // but do not apply its one-shot confirmation or other effects.
            if case let .failure(error) = result, case let .rateLimited(retryAfter) = error.failure {
                self.lifecycle.deferPoll(seconds: Double(max(retryAfter, 1)), now: response.receivedAt)
            }
            guard self.accepts(generation) else { return }
            self.pollRequest.consume(request.id)
            let answer: SGLinkAccountPollAnswer<SGEntitlementRequestError>
            var confirmation: SGEntitlementBindConfirmation?
            switch result {
            case let .success(.confirmed(value)):
                confirmation = value
                answer = .confirmed
            case .success(.pending):
                answer = .pending
            case .success(.denied):
                answer = .denied
            case .success(.expired):
                answer = .expired
            case .success(.consumed):
                answer = .consumed
            case .success(.restartBind):
                answer = .restartBind
            case let .failure(error):
                switch error.failure {
                case .rateLimited:
                    answer = .rateLimited
                case .offline:
                    answer = .offline
                case .refused(.bindNotFound):
                    answer = .bindNotFound
                default:
                    answer = .failed(error)
                }
            }
            // Every decision is the reducer's (`SGLinkAccountKeyRestartBudget.reaction`); this only
            // applies it to the screen.
            switch self.keyRestarts.reaction(to: answer) {
            case let .keepPolling(hint):
                switch hint {
                case .clear:
                    self.hint = nil
                case .keep:
                    break
                case .noConnection:
                    self.hint = .noConnection
                }
            case let .fail(reason):
                switch reason {
                case .declined:
                    self.fail(.linkingDeclined, .declined)
                case .codeExpired:
                    self.fail(.linkingCodeExpired, .codeExpired)
                case .didNotGoThrough:
                    self.fail(.linkingDidNotGoThrough, .didNotGoThrough)
                case .temporarilyUnavailable:
                    self.fail(.temporarilyUnavailable, .temporarilyUnavailable)
                case let .failed(error):
                    self.fail(self.message(for: error), .request(error))
                }
                return
            case .restartWithCurrentKey:
                // The install key changed since this code was issued. Nothing was sent, so the old
                // code is untouched; a session issued for it would be unusable here. Issue a fresh
                // code under the current key, and the user confirms that one.
                self.start = nil
                self.startRequest.reset()
                self.pollRequest.reset()
                self.expiresAt = nil
                self.attestation = .pending
                self.hint = nil
                self.didCopyCode = false
                self.phase = .starting
                await self.run(allowKeyRegeneration: false, generation: generation)
                return
            case .complete:
                guard let confirmation else {
                    self.fail(.temporarilyUnavailable, .temporarilyUnavailable)
                    return
                }
                // No suspension between the lifetime check and the atomic account-bound write.
                let stored = SGEntitlement.shared.completeBind(confirmation, start: start, accountPeerId: self.accountPeerId)
                if stored {
                    self.hint = nil
                    self.phase = .linked(mergeConflict: confirmation.mergeConflict ?? false)
                    // A manual link lifts an earlier Unlink's suppression of the automatic link.
                    SGCustomerLinkEvents.userDidLink(accountPeerId: self.accountPeerId)
                    self.recordAttempt(failure: nil)
                    // Bound in this screen, for this account and attempt (`accepts` above).
                    if !self.didReportLinked {
                        self.didReportLinked = true
                        self.linked?()
                    }
                } else {
                    self.fail(.temporarilyUnavailable, .temporarilyUnavailable)
                }
                return
            }
        }
    }

    private func waitForRequest(generation: UUID, isPoll: Bool) async -> Bool {
        while self.accepts(generation) {
            let now = ProcessInfo.processInfo.systemUptime
            let delay = isPoll ? self.lifecycle.pollDelay(now: now) : self.lifecycle.startDelay(now: now)
            guard delay > 0 else { return true }
            // Bounded conversion also handles very large Retry-After values without UInt64 traps.
            let untilExpiry = isPoll ? (self.expiresAt?.timeIntervalSinceNow ?? 0) : 30.0
            guard untilExpiry > 0 else { return true }
            do {
                try await Task.sleep(nanoseconds: UInt64(min(delay, untilExpiry, 30.0) * 1_000_000_000.0))
            } catch {
                return false
            }
        }
        return false
    }

    private func message(for error: SGEntitlementRequestError) -> SGEntitlementMessage {
        if case .offline = error.failure {
            return .noConnection
        }
        return error.recovery.message ?? .temporarilyUnavailable
    }

    fileprivate func updateCountdown() {
        guard let expiry = self.expiresAt else {
            self.remainingSeconds = 0
            return
        }
        self.remainingSeconds = max(0, Int(expiry.timeIntervalSinceNow.rounded(.down)))
    }

    fileprivate func copyCode() {
        guard let code = self.start?.code else {
            return
        }
        UIPasteboard.general.string = code
        self.didCopyCode = true
    }
}

struct SGLinkAccountView: View {
    @Environment(\.lang) var lang: String

    @ObservedObject var model: SGLinkAccountModel
    weak var wrapperController: LegacyController?
    /// True when the screen was presented on top of the paywall instead of pushed from Settings: it
    /// then draws its own close button, because there is no navigation bar to go back to.
    let isModal: Bool
    /// The app's own strings, resolved by the factory.
    let strings: PresentationStrings
    /// Whether a Pro surface may be shown right now (`sgProSurfacesVisible`, D1 2026-11-11). Linking
    /// is an IDENTITY step — it is the one Zenlygram row a non-holder still sees while the policy is
    /// free — so while false the intro, the success line and the unlink note describe it as identity
    /// for the data consent and Cloud Tasks, with no subscription, Pro or paid period in the copy.
    let showsProSurfaces: Bool

    private let ticker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var introKey: String {
        return showsProSurfaces ? "LinkAccount.Intro" : "LinkAccount.Intro.Free"
    }

    private var successTextKey: String {
        return showsProSurfaces ? "LinkAccount.Success.Text" : "LinkAccount.Success.Text.Free"
    }

    private var unlinkTextKey: String {
        return showsProSurfaces ? "LinkAccount.Unlink.Text" : "LinkAccount.Unlink.Text.Free"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch model.phase {
                case .idle, .starting:
                    preparingSection
                case .waiting:
                    codeSection
                case let .failed(message):
                    failureSection(message)
                case let .linked(mergeConflict):
                    linkedSection(mergeConflict: mergeConflict)
                case .unlinked:
                    unlinkedSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, isModal ? 44 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(closeButtonView)
        .onAppear {
            guard model.isCurrentAccount else {
                model.disappear()
                wrapperController?.dismiss(animated: true)
                return
            }
            SGAnalytics.screen(.zgLinkAccount, accountPeerId: model.accountPeerId)
            model.appear(isForeground: UIApplication.shared.applicationState != .background)
        }
        .onDisappear {
            model.disappear()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            model.setForeground(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            model.setForeground(true)
        }
        .onReceive(ticker) { _ in
            guard model.isCurrentAccount else {
                model.disappear()
                wrapperController?.dismiss(animated: true)
                return
            }
            if case .waiting = model.phase {
                model.updateCountdown()
            }
        }
    }

    @ViewBuilder
    private var closeButtonView: some View {
        if isModal {
            Button(action: {
                model.disappear()
                wrapperController?.dismiss(animated: true)
            }) {
                SGPayWallCloseGlyph()
            }
            .accessibility(label: Text("Common.Close".i18n(lang)))
            .padding([.top, .trailing], 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Pushed from Settings the navigation bar already carries the title; presented over the
            // paywall there is no bar, so the screen names itself. The trailing inset keeps a long
            // or enlarged title clear of the close button's 44 pt target.
            if isModal {
                Text("LinkAccount.Title".i18n(lang))
                    .font(.title)
                    .fontWeight(.bold)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 44)
                    .accessibility(addTraits: .isHeader)
            }
            Text(introKey.i18n(lang))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Work in progress: a spinner AND the words for what is being waited on, on the same neutral
    /// surface the notices use, so it is not mistaken for an error or a result.
    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 12) {
            SGPayWallSpinner()
                .accessibility(hidden: true)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .sgPayWallGrouped()
        .accessibilityElement(children: .combine)
    }

    private var preparingSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            progressRow("LinkAccount.Linking".i18n(lang))
            // Whenever the automatic attestation may run, the user is told what it asks Telegram
            // for, as this account, while it does (compliance; design 40 §8).
            if model.attestMayRun {
                Text("LinkAccount.AttestDisclosure".i18n(lang, args: "@" + SG_CONFIG.botUsername))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibility(identifier: "zg.link_account.attest_disclosure")
            }
        }
    }

    /// After Unlink: not linked, and nothing starts until the user asks for it.
    private var unlinkedSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            SGPayWallNoticeView(notice: SGPayWallNotice(text: "Settings.Pro.LinkAccount.NotLinked".i18n(lang), tone: .info))

            Button(action: {
                model.begin()
            }) {
                SGPayWallPrimaryButtonLabel(title: "LinkAccount.Title".i18n(lang))
            }
        }
    }

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(alignment: .leading, spacing: 8) {
                SGPayWallSectionHeader(title: "LinkAccount.Step.Code".i18n(lang), font: .footnote, color: .secondary)

                codeButton

                if model.didCopyCode {
                    codeStatusLine(symbol: "checkmark.circle.fill", tint: Color(.systemGreen), text: "LinkAccount.Code.Copied".i18n(lang))
                }

                if model.remainingSeconds > 0 {
                    codeStatusLine(symbol: "clock", tint: .secondary, text: "LinkAccount.Expires".i18n(lang, args: SGLinkAccountView.formatRemaining(model.remainingSeconds)))
                }
            }

            // `validatedDeeplink`, never the raw field: the button says "Open Telegram", so it opens
            // t.me or nothing at all — and inside THIS app, for the account being linked
            // (`SGLinkAccountTelegram.openLink`), never another app. Anything else falls through to
            // the code-plus-bot-name hint below, which needs no URL.
            if let deeplink = model.start?.validatedDeeplink {
                Button(action: {
                    model.telegram.openLink(deeplink, wrapperController?.navigationController as? NavigationController)
                }) {
                    SGPayWallPrimaryButtonLabel(title: "Common.OpenTelegram".i18n(lang))
                }
            } else {
                Text("LinkAccount.Code.Hint".i18n(lang, args: SG_CONFIG.botUsername))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Still waiting, and — when the connection drops — why, WITHOUT abandoning the bind: the
            // code stays valid, so the spinner stays and the hint is added under it.
            progressRow("LinkAccount.Waiting".i18n(lang))
            if let hint = model.hint {
                SGPayWallNoticeView(notice: SGPayWallNotice(text: hint.localizationKey.i18n(lang), tone: .warning))
            }

            // The phishing defence the bot's prompt mirrors. One line, and it has to be this one.
            SGPayWallNoticeView(notice: SGPayWallNotice(text: "LinkAccount.Warning".i18n(lang), tone: .info))
        }
    }

    /// The code itself: one large monospaced token that copies on tap. VoiceOver spells it out
    /// character by character, which is how the user has to compare it with the bot's.
    private var codeButton: some View {
        let code = model.start?.code ?? ""
        return Button(action: {
            model.copyCode()
        }) {
            HStack(spacing: 12) {
                Text(code)
                    .font(Font.system(.title, design: .monospaced).weight(.bold))
                    .foregroundColor(.primary)
                    // A code is one token: shrink it rather than break it mid-code.
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 8)
                Image(systemName: model.didCopyCode ? "checkmark" : "doc.on.doc")
                    .font(Font.body.weight(.semibold))
                    .foregroundColor(sgPayWallAccentText)
                    .accessibility(hidden: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .sgPayWallGrouped()
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibility(label: Text(code.map { String($0) }.joined(separator: " ")))
        .accessibility(hint: Text("LinkAccount.Code.CopyHint".i18n(lang)))
    }

    private func codeStatusLine(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundColor(tint)
                .accessibility(hidden: true)
            Text(text)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func failureSection(_ message: SGEntitlementMessage) -> some View {
        // `.required` shows no code, so neither the message nor the retry may promise one.
        let isRequired = model.attestationPolicy == .required
        let text: String
        if isRequired, message == .linkingDidNotGoThrough || message == .linkingCodeExpired {
            text = strings.Login_UnknownError
        } else {
            text = message.localizationKey.i18n(lang)
        }
        return VStack(alignment: .leading, spacing: 20) {
            header

            SGPayWallNoticeView(notice: SGPayWallNotice(text: text, tone: .warning))

            Button(action: {
                model.begin()
            }) {
                SGPayWallPrimaryButtonLabel(title: (isRequired ? "LinkAccount.Title" : "LinkAccount.GetNewCode").i18n(lang))
            }
        }
    }

    private func linkedSection(mergeConflict: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title)
                    .foregroundColor(Color(.systemGreen))
                    .accessibility(hidden: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LinkAccount.Success.Title".i18n(lang))
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibility(addTraits: .isHeader)
                    Text(successTextKey.i18n(lang))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .sgPayWallGrouped()
            // A modal has no title above this card: reserve the whole close-button band (8 pt inset
            // plus its 44 pt target) so no content sits under the close target.
            .padding(.top, isModal ? 32 : 0)

            if mergeConflict {
                // The sign-in SUCCEEDED. This notice never blocks the session.
                SGPayWallNoticeView(notice: SGPayWallNotice(text: SGEntitlementMessage.linkingMergeConflict.localizationKey.i18n(lang), tone: .info))
            }

            VStack(alignment: .leading, spacing: 8) {
                SGPayWallActionRow(
                    symbol: "minus.circle",
                    title: "LinkAccount.Unlink".i18n(lang),
                    trailing: .none,
                    isDestructive: true,
                    action: {
                        presentUnlinkConfirmation()
                    }
                )
                .sgPayWallGrouped()

                Text(unlinkTextKey.i18n(lang))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
    }

    private func presentUnlinkConfirmation() {
        let alert = UIAlertController(
            title: "LinkAccount.Unlink".i18n(lang),
            message: unlinkTextKey.i18n(lang),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Common.Cancel".i18n(lang), style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "LinkAccount.Unlink.Action".i18n(lang), style: .destructive, handler: { _ in
            model.unlink()
        }))
        wrapperController?.present(alert, animated: true)
    }

    private static func formatRemaining(_ seconds: Int) -> String {
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// - Parameters:
///   - requiresTelegramProof: Zenlygram Tasks — start a fresh Telegram proof even when a session is
///     stored (see `SGLinkAccountProofPolicy`). Existing callers keep the default `false`.
///   - attestationPolicy: `.required` (Lenta) refuses every code fallback and implies
///     `requiresTelegramProof`. Existing callers keep the default `.preferred`.
///   - linked: called once on the main actor when this screen stores a binding from a confirmed
///     Telegram proof for this account; never for an already-linked opening, a cancel or a failure.
///   - telegram: the account `accountPeerId` itself — its automatic attestation and its in-app
///     links (`SGLinkAccountTelegram`).
///   - showsProSurfaces: `sgProSurfacesVisible` for this account (D1 2026-11-11). Settings and the
///     status screen pass `sgProEntryIsVisible`; false picks the identity-only copy (data consent,
///     Cloud Tasks — no subscription, Pro or paid period) a non-holder sees while the policy is
///     free. Callers that are themselves Pro surfaces (the paywall) or not about Pro at all (Tasks,
///     Lenta) keep the default.
public func sgLinkTelegramAccountController(
    accountPeerId: Int64,
    presentationData: PresentationData? = nil,
    asModal: Bool = false,
    requiresTelegramProof: Bool = false,
    attestationPolicy: SGLinkAccountAttestationPolicy = .preferred,
    linked: (@MainActor @Sendable () -> Void)? = nil,
    telegram: SGLinkAccountTelegram,
    showsProSurfaces: Bool = true
) -> ViewController {
    let theme = presentationData?.theme ?? (UITraitCollection.current.userInterfaceStyle == .dark ? defaultDarkColorPresentationTheme : defaultPresentationTheme)
    let strings = presentationData?.strings ?? defaultPresentationStrings

    let legacyController = LegacySwiftUIController(
        presentation: asModal ? .modal(animateIn: true) : .navigation,
        theme: theme,
        strings: strings
    )
    legacyController.statusBar.statusBarStyle = theme.rootController.statusBarStyle.style
    legacyController.title = "LinkAccount.Title".i18n(strings.baseLanguageCode)

    // Owned here, not by the SwiftUI view: a body re-evaluation must not restart the bind, and the
    // poll loop must die with the screen rather than with a redraw.
    let model = SGLinkAccountModel(accountPeerId: accountPeerId, telegram: telegram, requiresTelegramProof: requiresTelegramProof, attestationPolicy: attestationPolicy, linked: linked)

    let swiftUIView = SGSwiftUIView<SGLinkAccountView>(
        legacyController: legacyController,
        manageSafeArea: true,
        content: {
            SGLinkAccountView(model: model, wrapperController: legacyController, isModal: asModal, strings: strings, showsProSurfaces: showsProSurfaces)
        }
    )
    let controller = UIHostingController(rootView: swiftUIView, ignoreSafeArea: true)
    legacyController.bind(controller: controller)

    return legacyController
}
