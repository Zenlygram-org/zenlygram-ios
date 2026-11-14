import Foundation
import LocalAuthentication

// Thin async wrapper around LAContext for ChatLock's biometric unlock step.
// We call evaluatePolicy directly (not via the shared LocalAuth module) because
// ChatLock only needs a simple prompt — no Secure Enclave key involved.
//
// Zenlygram — audit #40: before any prompt, the credential's enrolment BASELINE is compared against the
// device's current biometric domain state (ChatPincodeManager.biometricEnrollment(for:)). A new face or
// fingerprint enrolled on this iPhone must not inherit the power to open a chat or the vault, so that case
// returns `.enrollmentChanged` WITHOUT showing a sheet; the screen then asks for the PIN and offers an
// explicit "keep using Face ID" confirmation afterwards.

enum ChatLockBiometricResult {
    case success
    /// The sheet ended without a match: cancelled, or the presented face/finger was simply not recognised
    /// (Zenlygram — audit batch 4: a WRONG biometric belongs here, never in `.unavailable`).
    case cancelled
    /// No usable biometrics on this device at all (no hardware, nothing enrolled) — show PIN/text instead.
    case unavailable
    /// The biometric enrolment changed since this credential was set: no prompt was shown, ask for the PIN.
    case enrollmentChanged
}

public final class ChatLockBiometricHelper {

    // Returns the biometric type available on this device, or nil if none.
    // Zenlygram — Chat Lock Center: public, so the Chat Lock screens know whether to show the Face ID /
    // Touch ID rows and which of the two names to print. Nothing else of this helper is exposed.
    public static func availableType() -> ChatLockBiometricType? {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }
        switch ctx.biometryType {
        case .faceID:   return .faceID
        case .touchID:  return .touchID
        default:        return nil
        }
    }

    // Triggers a biometric prompt and calls completion on the main thread.
    // Never throws — all error paths map to .cancelled or .unavailable.
    // `slot`: the credential this unlock stands in for; nil keeps the pre-batch-4 behaviour (no enrolment
    // check), which is only for prompts that guard nothing on their own.
    static func evaluate(reason: String, slot: SGBiometricSlot?, completion: @escaping (ChatLockBiometricResult) -> Void) {
        if let slot, ChatPincodeManager.shared.biometricEnrollment(for: slot) == .changed {
            DispatchQueue.main.async { completion(.enrollmentChanged) }
            return
        }
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Not available (no hardware, not enrolled, locked out after too many failures).
            DispatchQueue.main.async { completion(.unavailable) }
            return
        }

        // Zenlygram — the Face ID / Touch ID sheet makes the app resign active; flag it so Chat Lock
        // neither raises its privacy shield nor treats the sheet as the user leaving the app.
        ChatLockSession.shared.isAuthenticating = true
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, evalError in
            DispatchQueue.main.async {
                ChatLockSession.shared.isAuthenticating = false
                if success {
                    completion(.success)
                    return
                }
                // Map LAError codes to our simplified result set.
                let code = (evalError as? LAError)?.code
                switch code {
                // Zenlygram — audit batch 4: `.authenticationFailed` (an unrecognised face/finger) and
                // `.biometryLockout` (too many of them in a row) are NOT "this iPhone has no biometrics".
                // Mapping them to `.unavailable` let an attacker fail the match two or three times and be
                // handed the next rung of a recovery ladder; `.cancelled` leaves the screen where it was.
                case .userCancel, .systemCancel, .appCancel, .userFallback, .authenticationFailed, .biometryLockout:
                    completion(.cancelled)
                default:
                    // biometryNotEnrolled, biometryNotAvailable, etc. — nothing here can prove anything.
                    completion(.unavailable)
                }
            }
        }
    }

    /// Pre-batch-4 entry point (no enrolment check). Kept for prompts that do not stand in for a credential.
    static func evaluate(reason: String, completion: @escaping (ChatLockBiometricResult) -> Void) {
        self.evaluate(reason: reason, slot: nil, completion: completion)
    }

    /// Device-owner proof by BIOMETRICS ONLY (never the iPhone passcode), used by the recovery ladder: the
    /// vault exists to hide chats from someone who knows that passcode, so it must not be the fallback here.
    /// Requires the enrolment to be the one the credential was set with.
    static func evaluateBiometricOwner(reason: String, slot: SGBiometricSlot, completion: @escaping (ChatLockBiometricResult) -> Void) {
        switch ChatPincodeManager.shared.biometricEnrollment(for: slot) {
        case .changed:
            DispatchQueue.main.async { completion(.enrollmentChanged) }
            return
        case .unavailable:
            DispatchQueue.main.async { completion(.unavailable) }
            return
        case .unchanged:
            break
        }
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            DispatchQueue.main.async { completion(.unavailable) }
            return
        }
        ChatLockSession.shared.isAuthenticating = true
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, evalError in
            DispatchQueue.main.async {
                ChatLockSession.shared.isAuthenticating = false
                if success {
                    completion(.success)
                    return
                }
                let code = (evalError as? LAError)?.code
                switch code {
                // Zenlygram — audit batch 4: see `evaluate(reason:slot:completion:)`. This entry point feeds
                // the recovery ladders, so a wrong face must never read as "biometrics unavailable" here.
                case .userCancel, .systemCancel, .appCancel, .userFallback, .authenticationFailed, .biometryLockout:
                    completion(.cancelled)
                default:
                    completion(.unavailable)
                }
            }
        }
    }
}
