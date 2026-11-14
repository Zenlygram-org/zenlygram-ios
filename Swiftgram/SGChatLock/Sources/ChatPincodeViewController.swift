import Foundation
import UIKit
import Display
import Postbox
import TelegramPresentationData
import LocalAuthentication
import SGCustomerSyncCore

// MARK: - Public mode enum

/// Describes what the ChatPincodeViewController should do.
public enum ChatPincodeMode {
    /// First-time setup: let the user choose PIN vs text-password, enter it twice,
    /// then optionally enable biometrics. `onSuccess` receives (credential, type, biometricEnabled).
    case set(onSuccess: (String, ChatLockPasswordType, Bool) -> Void)

    /// Unlock an already-locked chat.
    /// `passwordType`     — which entry UI to show (dots vs text field).
    /// `biometricEnabled` — whether to attempt Face/Touch ID on appear.
    /// `onVerify`         — returns true when the entered credential is correct.
    /// `onSuccess`        — called after a successful unlock.
    /// `onForgot`         — optional; when non-nil a "Forgot pincode?" button is
    ///                      shown that invokes this (master-pincode recovery).
    case verify(
        passwordType: ChatLockPasswordType,
        biometricEnabled: Bool,
        onVerify: (String) -> Bool,
        onSuccess: () -> Void,
        onForgot: (() -> Void)? = nil
    )

    // Zenlygram — Chat Lock Center (wf14-chatlock spec §6 C7): the former `.remove` mode (verify the chat's
    // code, then remove its lock — no "Forgot pincode?", no paired legacy-group removal) is retired. Removing
    // a lock is a `.verify` with `purpose: .manage` built by `SGChatLockFlows`, like every other management
    // screen.
}

// MARK: - Success method

/// Zenlygram — which rung of a verify screen succeeded (design 40 §10.2): what `vault.unlocked` /
/// `chat_lock.unlocked` report as `method`.
public enum ChatPincodeSuccessMethod: Equatable {
    /// Face ID / Touch ID.
    case biometric
    /// The entered credential, of this type.
    case code(ChatLockPasswordType)
    /// "Reset Chat Lock" after device-owner authentication: Chat Lock was turned off, nothing was
    /// unlocked by a credential.
    case reset

    /// The `method` of an unlock event; nil for a reset, which unlocks nothing.
    public var unlockMethod: SGAnalyticsUnlockMethod? {
        switch self {
        case .biometric:
            return .biometric
        case let .code(type):
            return type == .text ? .password : .pin
        case .reset:
            return nil
        }
    }
}

// MARK: - Recovery

/// What "Forgot pincode?" / "Reset Chat Lock" does on this screen (Zenlygram — Chat Lock central gate).
public enum ChatPincodeRecovery {
    /// Original behaviour: `onForgot` runs the device-owner (vault) flow; `isMasterRecovery` shows Reset.
    case legacy
    /// A chat's PIN screen: "Forgot pincode?" pushes the master-pincode screen on the SAME UIKit
    /// navigation controller (no dismiss, no LocalAuthentication).
    case masterPin(makeMasterController: () -> ChatPincodeViewController)
    /// The master-pincode screen: "Reset Chat Lock" (after 4 wrong entries or during a lockout) runs the
    /// device-owner reset, turns Chat Lock off, then dismisses and calls `onReset`.
    case resetChatLock(onReset: () -> Void)
    /// Zenlygram — audit #70 / #71: the credential this screen would ask for is GONE from this iPhone (the
    /// protected state did not come along with a device migration), so there is nothing any entry could
    /// satisfy. The screen shows the situation and the way out instead of a keypad nobody can answer.
    /// `mode` must still be `.verify` with a no-op `onVerify` — nothing is ever entered here.
    case credentialLost(
        title: String,
        text: String,
        primaryTitle: String,
        onPrimary: () -> Void,
        secondaryTitle: String?,
        onSecondary: (() -> Void)?
    )
}

// MARK: - Purpose

/// Zenlygram — Chat Lock Center (spec §2.4): why a `.verify` screen asks for the credential.
public enum ChatPincodePurpose {
    /// Original behaviour: the screen opens something (a locked chat, the vault); Face ID / Touch ID may
    /// stand in for the code and is attempted on the first appearance when enabled.
    case unlock
    /// A management screen (change the code, remove the lock, turn biometrics on): the code itself is the
    /// proof, like iOS's own passcode change. No biometric button, no auto-attempt, and the screen counts as
    /// `chat_lock.settings` rather than an unlock. Meaningful with `.verify` only.
    case manage
}

// MARK: - ViewController

public final class ChatPincodeViewController: ViewController {

    private let mode: ChatPincodeMode
    // Called when the user dismisses the screen without completing (e.g. cancels PIN setup),
    // so callers can revert optimistic UI such as a toggle that was flipped on.
    public var onCancel: (() -> Void)?
    private let presentationData: PresentationData
    // When true this is the master-pincode recovery screen ("Forgot pincode?"), which shows a
    // distinct title/subtitle so the user isn't faced with an identical-looking lock screen.
    private let isMasterRecovery: Bool
    // Zenlygram — what the recovery button does, and which brute-force throttle this screen counts against.
    private let recovery: ChatPincodeRecovery
    private let throttleScope: ChatLockThrottle.Scope
    // Called synchronously the moment a verify succeeds (credential, biometrics or reset), BEFORE the
    // dismissal whose completion runs `onSuccess`. The Chat Lock prompt presenter uses it to issue the
    // unlock grant even if that dismissal is interrupted (e.g. by the app passcode locking).
    var onWillSucceed: (() -> Void)?
    /// Zenlygram — the rung that succeeded, set right before each `onWillSucceed` (design 40 §10.2).
    private(set) var lastSuccessMethod: ChatPincodeSuccessMethod?
    /// Zenlygram — called synchronously when a "Forgot pincode?" recovery rung succeeded (Face ID /
    /// Touch ID, or the master pincode), right before its `onForgot` runs.
    var onRecoveryWillSucceed: ((ChatPincodeSuccessMethod) -> Void)?
    private var didRecordScreenView = false
    // Zenlygram — Chat Lock Center (spec §2.4): see `ChatPincodePurpose`. `.unlock` keeps every existing
    // caller's behaviour.
    private let purpose: ChatPincodePurpose
    // Zenlygram — the locked chat's display title (title only, never content). On a chat's own verify
    // screen it replaces the generic "Chat is locked" subtitle, so a prompt the user did not start by
    // tapping that chat's row (resume after relock, notification / link, comments keyed on the discussion
    // group) still says whose PIN it wants. May be set after the screen is shown (resolved asynchronously).
    // Zenlygram — Chat Lock Center: public, so the management flows can name the chat the same way.
    public var chatTitle: String? {
        didSet {
            if self.subtitleLabel != nil, oldValue != self.chatTitle {
                self.updateLabels()
            }
        }
    }
    /// Zenlygram — Chat Lock Center (spec §2.4): an explicit caption for this screen. Replaces the subtitle
    /// on the `.verify`, `.verifyMaster`, `.disableChatLock`, `.enterNew` steps and on the type picker
    /// (today ""); never on `.confirmNew` ("Re-enter the same code" stays). Precedence:
    /// `subtitleOverride ?? chatTitle ?? step default` (see `updateLabels`).
    public var subtitleOverride: String? {
        didSet {
            if self.subtitleLabel != nil, oldValue != self.subtitleOverride {
                self.updateLabels()
            }
        }
    }

    // -- setup-flow state --
    private var chosenType: ChatLockPasswordType = .pin   // picked by the type-picker sheet
    private var setupPhase: SetupPhase = .pickType        // drives the setup step machine

    // -- entry state (shared by PIN and text modes) --
    private var enteredCode: String = ""
    private var firstCode: String = ""       // holds the first entry during confirmation step
    private var currentStep: ChatLockSetupStep = .enterNew
    // Wrong-entry counter (verify/master). After 4 we surface recovery — never a lockout.
    private var failedAttempts = 0
    // Zenlygram — audit #40: this screen asked for a biometric unlock and was told the enrolment changed
    // since the credential was set. No sheet was shown and nothing was counted as a wrong entry; the
    // biometric button stays hidden and the next correct pincode ends in the keep/pincode-only choice.
    private var enrollmentChangedOnThisScreen = false

    // -- UI --
    private var titleLabel: UILabel!
    private var subtitleLabel: UILabel!

    // PIN mode
    private var dotsView: UIStackView!
    private var dotViews: [UIView] = []
    private var numberPadView: UIView!

    // Text-password mode
    private var textField: UITextField!
    private var submitButton: UIButton!

    // Biometric button (shown during .verify when biometrics are available & enabled)
    private var biometricButton: UIButton!

    // "Forgot pincode?" button (shown only in .verify mode when an onForgot handler is supplied)
    private var forgotButton: UIButton!

    // Close button (always present)
    private var closeButton: UIButton!

    // Type-picker buttons (shown only during setupPhase == .pickType)
    private var typePickerContainer: UIView!
    private var typePickerButtons: [UIButton] = []

    // MARK: - Init

    /// SG: Chat Lock — `turnsOffChatLock`: this is the master-pincode screen in Settings whose success turns
    /// Chat Lock off for every chat, so it shows that wording instead of the per-chat recovery copy
    /// ("Unlocks this chat and removes its pincode"). Only meaningful in `.verify` mode.
    /// Zenlygram — audit #40: `verifiesMasterForVaultRecovery` is the master-pincode screen the VAULT's
    /// "Forgot" ladder pushes (the iPhone passcode is never accepted for the vault), so it says what success
    /// there does instead of borrowing the per-chat recovery copy.
    /// Zenlygram — audit #90: the default throttle scope is `.vault` (`.legacy` is its alias), which is what
    /// the vault PIN screens in Settings and in the prompt presenter rely on.
    /// Zenlygram — Chat Lock Center (spec §2.4): `purpose` defaults to `.unlock`, so every existing caller
    /// keeps its behaviour; the management flows pass `.manage` on their `.verify` screens.
    public init(mode: ChatPincodeMode, presentationData: PresentationData, isMasterRecovery: Bool = false, recovery: ChatPincodeRecovery = .legacy, throttleScope: ChatLockThrottle.Scope = .vault, turnsOffChatLock: Bool = false, verifiesMasterForVaultRecovery: Bool = false, purpose: ChatPincodePurpose = .unlock) {
        self.mode = mode
        self.presentationData = presentationData
        self.isMasterRecovery = isMasterRecovery
        self.recovery = recovery
        self.throttleScope = throttleScope
        self.purpose = purpose

        // Derive initial step from mode so we skip the type picker for verify.
        switch mode {
        case .set:
            self.setupPhase = .pickType
            self.currentStep = .enterNew
        case .verify:
            self.setupPhase = .enterCredential
            if turnsOffChatLock {
                // SG: Chat Lock — Settings > Chat Lock > Disable: no single chat is involved.
                self.currentStep = .disableChatLock
            } else if verifiesMasterForVaultRecovery {
                self.currentStep = .verifyMasterForVault
            } else {
                self.currentStep = isMasterRecovery ? .verifyMaster : .verify
            }
        }

        // For verify, grab the password type from the mode payload.
        switch mode {
        case .verify(let passwordType, _, _, _, _):
            self.chosenType = passwordType
        case .set:
            self.chosenType = .pin   // overridden by the type picker
        }

        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
        // Zenlygram — portrait-only on the phone (the keypad needs the height); iPad keeps every
        // orientation. This covers a push onto the Display stack; the UIKit container is handled below.
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        syncVisibility()
        updateLabels()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Zenlygram — `screen.view` once per screen, not again when a pushed screen pops back here.
        if !didRecordScreenView {
            didRecordScreenView = true
            if let screen = ChatPincodeViewController.analyticsScreen(mode: mode, scope: throttleScope, purpose: purpose) {
                SGAnalytics.screen(screen)
            }
        }
        // Zenlygram — a chat keyboard left up underneath (e.g. the covered chat's input) must not
        // cover the keypad. Text-password entry takes the focus itself right below.
        if !(setupPhase != .pickType && chosenType == .text) {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        // SG: Chat Lock — Face ID / Touch ID starts by itself only on the FIRST appearance. viewDidAppear
        // runs again when the pushed master-pincode screen pops back here, and must not bring back a
        // biometric sheet the user already dismissed (the biometric button stays available).
        if !didAutoAttemptBiometric {
            didAutoAttemptBiometric = true
            if autoAttemptsBiometric {
                attemptBiometricIfNeeded()
            }
        }
        activateTextFieldIfNeeded()
    }

    // MARK: - Orientation

    // Zenlygram — callers present this screen full-screen inside a plain UIKit UINavigationController,
    // which never asks its children for supported orientations, so on iPhone the PIN screen followed
    // the device into landscape where the keypad runs off-screen. Adopt that container as its delegate
    // so it reports portrait on the phone idiom; iPad keeps every orientation (App Store requirement
    // for iPad multitasking) and relies on the adaptive layout in buildLayout().
    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    public override func willMove(toParent parent: UIViewController?) {
        super.willMove(toParent: parent)
        // Only plain UIKit containers — Display's NavigationController resolves orientation itself.
        if let navigationController = parent as? UINavigationController, !(navigationController is NavigationController), navigationController.delegate == nil {
            navigationController.delegate = self
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        let isDark = presentationData.theme.overallDarkAppearance
        view.backgroundColor = isDark ? UIColor(rgb: 0x1c1c1e) : UIColor(rgb: 0xf2f2f7)

        // Close button
        closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.accessibilityLabel = FenixuzChatLockStrings.close
        // Light tint raised 0.3 → 0.45: black @0.3 on 0xf2f2f7 is ~2.1:1, below the 3:1
        // WCAG minimum for non-text icons (white @0.4 on 0x1c1c1e is ~3.8:1 and passes).
        closeButton.tintColor = isDark ? UIColor(white: 1, alpha: 0.4) : UIColor(white: 0, alpha: 0.45)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        // Title
        titleLabel = UILabel()
        titleLabel.font = scaledFont(size: 28, weight: .bold, textStyle: .title1, maximumPointSize: 34)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.7
        titleLabel.textColor = isDark ? .white : .black
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        // Subtitle
        subtitleLabel = UILabel()
        subtitleLabel.font = scaledFont(size: 15, weight: .regular, textStyle: .subheadline, maximumPointSize: 20)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 2
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subtitleLabel)

        // Type-picker container (only used in set mode, phase .pickType)
        buildTypePickerContainer(isDark: isDark)
        view.addSubview(typePickerContainer)

        // PIN dots row
        buildDotsRow()
        view.addSubview(dotsView)

        // Number pad
        numberPadView = buildNumberPad(isDark: isDark)
        numberPadView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(numberPadView)

        // Text field (for alphanumeric password mode)
        buildTextField(isDark: isDark)
        view.addSubview(textField)
        view.addSubview(submitButton)

        // Biometric button
        buildBiometricButton(isDark: isDark)

        // "Forgot pincode?" button (verify + master-recovery only)
        buildForgotButton(isDark: isDark)

        // Zenlygram — bottom accessories live in a stack so hidden ones collapse, and the keypad is
        // constrained above whatever is actually visible there. The old fixed offsets let "Forgot"
        // overlap the 0 row on short screens (iPad mini landscape, iPhone SE).
        let accessoryStack = UIStackView(arrangedSubviews: [forgotButton, biometricButton])
        accessoryStack.axis = .vertical
        accessoryStack.alignment = .center
        accessoryStack.spacing = 20
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(accessoryStack)

        // Layout constraints
        let padHeight: CGFloat = 4 * 76 + 3 * 14

        // Zenlygram — the design spacing and keypad height are optional: a short container compresses
        // the gaps first, then scales the keypad down (ChatPincodeKeypadView lays its keys out to fit).
        // Both stay below the labels'/buttons' 750 compression resistance so text is never clipped.
        let dotsPreferredTop = dotsView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 36)
        // 731 vs the pad gap's 730 breaks the tie: when height is short the gap above the keypad
        // shrinks first, instead of Auto Layout splitting the deficit arbitrarily (ambiguous layout).
        dotsPreferredTop.priority = UILayoutPriority(731)
        let padPreferredTop = numberPadView.topAnchor.constraint(equalTo: dotsView.bottomAnchor, constant: 44)
        padPreferredTop.priority = UILayoutPriority(730)
        let padPreferredHeight = numberPadView.heightAnchor.constraint(equalToConstant: padHeight)
        padPreferredHeight.priority = UILayoutPriority(740)
        // 999, not required: a hidden arranged subview gets the stack's required height == 0.
        let biometricHeight = biometricButton.heightAnchor.constraint(equalToConstant: 60)
        biometricHeight.priority = UILayoutPriority(999)

        // Zenlygram — audit #70 / #71: the keypad's required "fits between the dots and the accessories"
        // chain is meaningless on the recovery screen (dots and keypad are hidden) and its long explanatory
        // text can make that chain unsatisfiable, so it becomes optional there instead of breaking at 1000.
        let dotsMinimumTop = dotsView.topAnchor.constraint(greaterThanOrEqualTo: subtitleLabel.bottomAnchor, constant: 16)
        let padMinimumTop = numberPadView.topAnchor.constraint(greaterThanOrEqualTo: dotsView.bottomAnchor, constant: 20)
        let padMaximumBottom = numberPadView.bottomAnchor.constraint(lessThanOrEqualTo: accessoryStack.topAnchor, constant: -16)
        if isCredentialLost {
            for constraint in [dotsMinimumTop, padMinimumTop, padMaximumBottom] {
                constraint.priority = UILayoutPriority(999)
            }
        }

        // Zenlygram — audit #70 / #71: on the recovery screen the submit button is the primary action and its
        // title is a sentence ("Set a new vault PIN"), not "Done", so it wraps and grows instead of being
        // clipped by the 200×50 frame the text-password flow uses.
        let submitSizeConstraints: [NSLayoutConstraint]
        if isCredentialLost {
            submitSizeConstraints = [
                submitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
                submitButton.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
                submitButton.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
                submitButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
            ]
        } else {
            submitSizeConstraints = [
                submitButton.widthAnchor.constraint(equalToConstant: 200),
                submitButton.heightAnchor.constraint(equalToConstant: 50)
            ]
        }

        NSLayoutConstraint.activate(submitSizeConstraints + [
            // Close button — 44×44 minimum tap target (was 34×34). The SF-symbol glyph does
            // not scale with the frame, so only the touch area grows; the constants are
            // offset by -5 to keep the glyph in the same visual spot.
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 7),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -11),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            // Title
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            // Subtitle
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            // Type picker (anchored below subtitle, same vertical space as dots+pad)
            typePickerContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            typePickerContainer.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 48),
            typePickerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            typePickerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            // Dots row
            dotsView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dotsPreferredTop,
            dotsMinimumTop,

            // Number pad
            numberPadView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            padPreferredTop,
            padMinimumTop,
            numberPadView.widthAnchor.constraint(equalToConstant: 280),
            padPreferredHeight,
            padMaximumBottom,

            // Text field
            textField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            textField.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 48),
            textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            textField.heightAnchor.constraint(equalToConstant: 50),

            // Submit button (below text field)
            submitButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            submitButton.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 20),

            // Bottom accessories: "Forgot pincode?" above the biometric button, anchored to the
            // safe bottom. The biometric button is hidden in most verify flows (it then collapses).
            accessoryStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            accessoryStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -36),
            biometricButton.widthAnchor.constraint(equalToConstant: 60),
            biometricHeight,
            forgotButton.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            forgotButton.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])

        // Zenlygram — audit #70 / #71: the recovery screen reuses the two buttons it already has.
        if case let .credentialLost(_, _, primaryTitle, _, secondaryTitle, _) = recovery {
            submitButton.setTitle(primaryTitle, for: .normal)
            submitButton.accessibilityLabel = primaryTitle
            submitButton.titleLabel?.numberOfLines = 0
            submitButton.titleLabel?.textAlignment = .center
            // This button has no UIButton.Configuration. Preserve its legacy padding through the
            // public Objective-C property without introducing configuration-driven styling.
            submitButton.setValue(NSValue(uiEdgeInsets: UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)), forKey: "contentEdgeInsets")
            if let secondaryTitle {
                forgotButton.setTitle(secondaryTitle, for: .normal)
                forgotButton.accessibilityLabel = secondaryTitle
                forgotButton.titleLabel?.numberOfLines = 0
                forgotButton.titleLabel?.textAlignment = .center
            }
        }
    }

    /// Zenlygram — audit #70 / #71: this screen cannot ask for anything (the credential is gone).
    private var isCredentialLost: Bool {
        if case .credentialLost = recovery {
            return true
        }
        return false
    }

    /// Zenlygram — audit #40: which credential's biometric enrolment baseline this screen stands for. The
    /// throttle scope already names exactly that credential, so the two can never drift apart.
    private var biometricSlot: SGBiometricSlot {
        switch throttleScope {
        case .vault, .legacy, .vaultSearch:
            // `.vaultSearch` is the chat-list search gate's own budget for the SAME vault credential, so it
            // maps to the same biometric slot. No screen uses it as its scope today; naming it here keeps the
            // mapping total rather than letting a future scope fall through to a wrong slot.
            return .vault
        case .master:
            return .master
        case let .chat(peerId):
            return .chat(peerId)
        }
    }

    // MARK: - Dynamic Type

    /// Scales a fixed design size with the given text style so the lock screen honors
    /// Dynamic Type, capped so the frame/constraint-based layout (fixed keypad grid,
    /// fixed-height cards and fields) cannot break at accessibility sizes.
    private func scaledFont(size: CGFloat, weight: UIFont.Weight, textStyle: UIFont.TextStyle, maximumPointSize: CGFloat) -> UIFont {
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(
            for: .systemFont(ofSize: size, weight: weight),
            maximumPointSize: maximumPointSize
        )
    }

    // MARK: - Sub-view builders

    private func buildTypePickerContainer(isDark: Bool) {
        typePickerContainer = UIView()
        typePickerContainer.translatesAutoresizingMaskIntoConstraints = false

        let pinBtn = makeTypePickerButton(
            title: FenixuzChatLockStrings.chooseTypePin,
            icon: "lock.fill",
            isDark: isDark,
            tag: 0
        )
        let textBtn = makeTypePickerButton(
            title: FenixuzChatLockStrings.chooseTypeText,
            icon: "textformat.abc",
            isDark: isDark,
            tag: 1
        )

        pinBtn.translatesAutoresizingMaskIntoConstraints = false
        textBtn.translatesAutoresizingMaskIntoConstraints = false
        typePickerContainer.addSubview(pinBtn)
        typePickerContainer.addSubview(textBtn)
        typePickerButtons = [pinBtn, textBtn]

        NSLayoutConstraint.activate([
            pinBtn.topAnchor.constraint(equalTo: typePickerContainer.topAnchor),
            pinBtn.leadingAnchor.constraint(equalTo: typePickerContainer.leadingAnchor),
            pinBtn.trailingAnchor.constraint(equalTo: typePickerContainer.trailingAnchor),
            pinBtn.heightAnchor.constraint(equalToConstant: 64),

            textBtn.topAnchor.constraint(equalTo: pinBtn.bottomAnchor, constant: 16),
            textBtn.leadingAnchor.constraint(equalTo: typePickerContainer.leadingAnchor),
            textBtn.trailingAnchor.constraint(equalTo: typePickerContainer.trailingAnchor),
            textBtn.heightAnchor.constraint(equalToConstant: 64),
            textBtn.bottomAnchor.constraint(equalTo: typePickerContainer.bottomAnchor)
        ])
    }

    private func makeTypePickerButton(title: String, icon: String, isDark: Bool, tag: Int) -> UIButton {
        let btn = UIButton(type: .custom)
        btn.tag = tag

        // The visible title lives in a child UILabel, so the container button itself exposes
        // nothing to VoiceOver — surface the whole card as one labeled button element.
        // No .selected trait: this is a one-shot choose-and-advance menu (it disappears on
        // tap), so a pre-selected default card would be misleading to VoiceOver users.
        btn.isAccessibilityElement = true
        btn.accessibilityLabel = title
        btn.accessibilityTraits = .button

        let cardColor = isDark ? UIColor(white: 1, alpha: 0.08) : UIColor.white
        btn.backgroundColor = cardColor
        btn.layer.cornerRadius = 14
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOpacity = isDark ? 0 : 0.07
        btn.layer.shadowOffset = CGSize(width: 0, height: 2)
        btn.layer.shadowRadius = 6

        // Icon
        let imgView = UIImageView(image: UIImage(systemName: icon))
        imgView.tintColor = UIColor(rgb: presentationData.theme.list.itemAccentColor.rgb)
        imgView.contentMode = .scaleAspectFit
        imgView.translatesAutoresizingMaskIntoConstraints = false

        // Label
        let lbl = UILabel()
        lbl.text = title
        lbl.font = scaledFont(size: 17, weight: .medium, textStyle: .body, maximumPointSize: 22)
        lbl.adjustsFontForContentSizeCategory = true
        lbl.adjustsFontSizeToFitWidth = true
        lbl.minimumScaleFactor = 0.8
        lbl.textColor = isDark ? .white : .black
        lbl.translatesAutoresizingMaskIntoConstraints = false

        // Chevron — raised to 0.45 alpha so the affordance icon clears the 3:1
        // non-text contrast minimum against the card background in both themes.
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = isDark ? UIColor(white: 1, alpha: 0.45) : UIColor(white: 0, alpha: 0.45)
        chevron.contentMode = .scaleAspectFit
        chevron.translatesAutoresizingMaskIntoConstraints = false

        btn.addSubview(imgView)
        btn.addSubview(lbl)
        btn.addSubview(chevron)

        NSLayoutConstraint.activate([
            imgView.leadingAnchor.constraint(equalTo: btn.leadingAnchor, constant: 20),
            imgView.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            imgView.widthAnchor.constraint(equalToConstant: 24),
            imgView.heightAnchor.constraint(equalToConstant: 24),

            lbl.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 14),
            lbl.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            // Keep the (Dynamic Type-scaled) label from running under the chevron.
            lbl.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),

            chevron.trailingAnchor.constraint(equalTo: btn.trailingAnchor, constant: -18),
            chevron.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 14),
            chevron.heightAnchor.constraint(equalToConstant: 14)
        ])

        btn.addTarget(self, action: #selector(typePickerTapped(_:)), for: .touchUpInside)
        return btn
    }

    private func buildDotsRow() {
        dotsView = UIStackView()
        dotsView.axis = .horizontal
        dotsView.spacing = 16
        dotsView.translatesAutoresizingMaskIntoConstraints = false

        // VoiceOver: the dots convey entry progress only visually, so expose the row as a
        // single element whose value tracks progress (kept up to date in syncDots()).
        // No per-keystroke announcements — the value change is enough.
        dotsView.isAccessibilityElement = true
        dotsView.accessibilityLabel = FenixuzChatLockStrings.pinCodeLabel
        dotsView.accessibilityValue = FenixuzChatLockStrings.pinDigitsEntered(count: 0, total: 4)
        dotsView.accessibilityTraits = .updatesFrequently

        for _ in 0..<4 {
            let dot = UIView()
            dot.layer.cornerRadius = 10
            dot.layer.borderWidth = 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 20).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 20).isActive = true
            dotViews.append(dot)
            dotsView.addArrangedSubview(dot)
        }
    }

    private func buildTextField(isDark: Bool) {
        textField = UITextField()
        // Explicit placeholder color: the default .placeholderText lands well below 4.5:1
        // on the translucent card background in dark mode.
        textField.attributedPlaceholder = NSAttributedString(
            string: FenixuzChatLockStrings.done,
            attributes: [.foregroundColor: isDark ? UIColor(white: 1, alpha: 0.6) : UIColor(white: 0, alpha: 0.55)]
        )
        textField.isSecureTextEntry = true
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.returnKeyType = .done
        textField.borderStyle = .none
        textField.font = scaledFont(size: 20, weight: .regular, textStyle: .body, maximumPointSize: 24)
        textField.adjustsFontForContentSizeCategory = true
        textField.textColor = isDark ? .white : .black
        textField.textAlignment = .center
        textField.backgroundColor = isDark ? UIColor(white: 1, alpha: 0.08) : UIColor.white
        textField.layer.cornerRadius = 12
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false

        // Add some horizontal padding via a transparent left view.
        let padding = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 1))
        textField.leftView = padding
        textField.leftViewMode = .always

        submitButton = UIButton(type: .custom)
        submitButton.setTitle(FenixuzChatLockStrings.done, for: .normal)
        submitButton.titleLabel?.font = scaledFont(size: 17, weight: .semibold, textStyle: .headline, maximumPointSize: 22)
        submitButton.titleLabel?.adjustsFontForContentSizeCategory = true
        submitButton.setTitleColor(.white, for: .normal)
        let accent = UIColor(rgb: presentationData.theme.list.itemAccentColor.rgb)
        submitButton.backgroundColor = accent
        submitButton.layer.cornerRadius = 14
        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        submitButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildBiometricButton(isDark: Bool) {
        biometricButton = UIButton(type: .custom)
        // Icon will be updated in syncVisibility() based on detected biometric type.
        biometricButton.tintColor = UIColor(rgb: presentationData.theme.list.itemAccentColor.rgb)
        biometricButton.backgroundColor = isDark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.05)
        biometricButton.layer.cornerRadius = 30
        biometricButton.addTarget(self, action: #selector(biometricTapped), for: .touchUpInside)
        biometricButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildForgotButton(isDark: Bool) {
        forgotButton = UIButton(type: .system)
        forgotButton.setTitle(showsResetRecovery ? FenixuzChatLockStrings.resetButtonTitle : FenixuzChatLockStrings.forgotPincode, for: .normal)
        // The raw theme accent is ~3.6:1 on the light 0xf2f2f7 background (default blue),
        // below the 4.5:1 WCAG text minimum — darken it locally in light mode until it
        // passes; dark mode keeps the accent as-is (it passes on 0x1c1c1e).
        let forgotAccent = UIColor(rgb: presentationData.theme.list.itemAccentColor.rgb)
        forgotButton.setTitleColor(presentationData.theme.overallDarkAppearance
            ? forgotAccent
            : Self.darkenedForContrast(forgotAccent, against: UIColor(rgb: 0xf2f2f7)), for: .normal)
        forgotButton.titleLabel?.font = scaledFont(size: 16, weight: .medium, textStyle: .callout, maximumPointSize: 21)
        forgotButton.titleLabel?.adjustsFontForContentSizeCategory = true
        // Pad the bare text button (~20pt tall) up to the 44pt minimum tap target.
        // No UIButton.Configuration is installed; KVC addresses the public legacy padding property.
        forgotButton.setValue(NSValue(uiEdgeInsets: UIEdgeInsets(top: 13, left: 12, bottom: 13, right: 12)), forKey: "contentEdgeInsets")
        forgotButton.addTarget(self, action: #selector(forgotTapped), for: .touchUpInside)
        forgotButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildNumberPad(isDark: Bool) -> UIView {
        let container = ChatPincodeKeypadView()
        let buttonSize: CGFloat = 76
        let spacing: CGFloat = 14
        let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"]

        for (index, label) in digits.enumerated() {
            let row = index / 3
            let col = index % 3
            if label.isEmpty { continue }

            let isBackspace = (label == "⌫")
            let button = UIButton(type: .custom)
            button.setTitle(label, for: .normal)
            // Tighter Dynamic Type caps than the rest of the screen: the keys live in a
            // fixed 76pt frame-based grid, so growth is bounded and the title additionally
            // shrinks to fit rather than overflowing the circle.
            button.titleLabel?.font = isBackspace
                ? scaledFont(size: 24, weight: .medium, textStyle: .title3, maximumPointSize: 30)
                : scaledFont(size: 28, weight: .regular, textStyle: .title2, maximumPointSize: 34)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.5
            button.setTitleColor(isDark ? .white : .black, for: .normal)
            if isBackspace {
                // VoiceOver reads the bare "⌫" glyph poorly — give it a proper name.
                button.accessibilityLabel = FenixuzChatLockStrings.deleteKey
            }

            if !isBackspace {
                button.backgroundColor = isDark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 1, alpha: 0.9)
                button.layer.cornerRadius = buttonSize / 2
                button.layer.shadowColor = UIColor.black.cgColor
                button.layer.shadowOpacity = isDark ? 0 : 0.08
                button.layer.shadowOffset = CGSize(width: 0, height: 2)
                button.layer.shadowRadius = 4
            }

            button.frame = CGRect(
                x: CGFloat(col) * (buttonSize + spacing),
                y: CGFloat(row) * (buttonSize + spacing),
                width: buttonSize,
                height: buttonSize
            )
            button.tag = index
            button.addTarget(self, action: #selector(padTapped(_:)), for: .touchUpInside)
            button.addTarget(self, action: #selector(padPressed(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(padReleased(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])

            container.addSubview(button)
        }

        let rows = 4
        let h = CGFloat(rows) * buttonSize + CGFloat(rows - 1) * spacing
        container.frame = CGRect(x: 0, y: 0, width: 3 * buttonSize + 2 * spacing, height: h)
        return container
    }

    // MARK: - Visibility sync

    /// Show/hide sub-views depending on which phase + type is active.
    private func syncVisibility() {
        // Zenlygram — audit #70 / #71: nothing can be entered on the recovery screen, so every entry
        // affordance (dots, keypad, text field, biometrics) is gone and only the two actions remain.
        if case let .credentialLost(_, _, _, _, secondaryTitle, _) = recovery {
            typePickerContainer.isHidden = true
            dotsView.isHidden = true
            numberPadView.isHidden = true
            textField.isHidden = true
            biometricButton.isHidden = true
            submitButton.isHidden = false
            forgotButton.isHidden = (secondaryTitle == nil)
            return
        }

        let isPickingType = (setupPhase == .pickType)
        let isPINEntry    = !isPickingType && (chosenType == .pin)
        let isTextEntry   = !isPickingType && (chosenType == .text)

        typePickerContainer.isHidden = !isPickingType
        dotsView.isHidden            = !isPINEntry
        numberPadView.isHidden       = !isPINEntry
        textField.isHidden           = !isTextEntry
        submitButton.isHidden        = !isTextEntry

        // "Forgot pincode?": only in verify mode when a master-recovery handler is supplied.
        // Chat page: shown when master recovery exists. Master page: button is "Reset Chat Lock",
        // hidden until the user has struggled (4 wrong tries), per the surface-recovery UX.
        switch recovery {
        case .legacy:
            // Zenlygram — audit #40: the vault's "Forgot" is no longer device-passcode recovery, so it is no
            // longer gated on a device passcode existing (the ladder in `forgotVaultTapped` decides, and its
            // last rung is an honest "recovery unavailable" alert). Like the master screen's Reset, it stays
            // out of sight until the user has actually struggled: 4 wrong entries, or a live lockout (which
            // persists across presentations, so a fresh screen must still offer the way out).
            forgotButton.isHidden = isMasterRecovery
                ? (failedAttempts < 4)
                : (verifyOnForgot == nil || !(failedAttempts >= 4 || ChatLockThrottle.remaining(throttleScope) > 0))
        case .credentialLost:
            // Handled by the early return above.
            break
        case .masterPin:
            // Zenlygram — a chat PIN screen always offers master-pincode recovery while verifying.
            if case .verify = mode {
                forgotButton.isHidden = isPickingType
            } else {
                forgotButton.isHidden = true
            }
        case .resetChatLock:
            // Zenlygram — the master screen surfaces Reset once the user has struggled OR is locked out
            // (the lockout persists across presentations, so a fresh screen must still offer the way out).
            forgotButton.isHidden = !(failedAttempts >= 4 || ChatLockThrottle.remaining(throttleScope) > 0)
        }

        // Biometric button: only during verify (never setup), when device supports it.
        let showBiometric = !isPickingType && biometricShouldShow()
        biometricButton.isHidden = !showBiometric

        if showBiometric {
            let isFaceID = ChatLockBiometricHelper.availableType() == .faceID
            let iconName = isFaceID ? "faceid" : "touchid"
            biometricButton.accessibilityLabel = isFaceID ? "Face ID" : "Touch ID"
            biometricButton.setImage(
                UIImage(systemName: iconName)?.withConfiguration(
                    UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
                ),
                for: .normal
            )
        }

        // Refresh dot colors whenever visibility changes.
        if isPINEntry { syncDots() }
    }

    /// True when the biometric button should be rendered on screen.
    private func biometricShouldShow() -> Bool {
        // Zenlygram — audit #40: a changed enrolment cannot unlock anything on this screen, so offering the
        // button would only produce the same refusal again.
        if enrollmentChangedOnThisScreen || isCredentialLost {
            return false
        }
        // Zenlygram — Chat Lock Center (spec §2.4): a management screen takes the code itself as the proof
        // (the flows also pass `biometricEnabled: false` — belt and braces).
        if purpose == .manage {
            return false
        }
        switch mode {
        case .verify(_, let enabled, _, _, _):
            return enabled && ChatLockBiometricHelper.availableType() != nil
        case .set:
            return false
        }
    }

    // MARK: - Label updates

    private func updateLabels() {
        let isDarkSub = presentationData.theme.overallDarkAppearance
        // Light alpha raised 0.45 → 0.6: black @0.45 on 0xf2f2f7 is ~3.3:1, below the 4.5:1
        // WCAG text minimum (white @0.5 on 0x1c1c1e is ~5.2:1 and passes).
        subtitleLabel.textColor = isDarkSub
            ? UIColor(white: 1, alpha: 0.5)
            : UIColor(white: 0, alpha: 0.6)

        // Zenlygram — audit #70 / #71: the recovery screen explains the situation instead of naming a step.
        if case let .credentialLost(title, text, _, _, _, _) = recovery {
            titleLabel.text = title
            subtitleLabel.numberOfLines = 0
            subtitleLabel.text = text
            return
        }

        // Zenlygram — audit #40: a refused biometric unlock replaces the subtitle until the next entry.
        if enrollmentChangedOnThisScreen {
            titleLabel.text = chosenType == .pin
                ? FenixuzChatLockStrings.pinTitle(mode: currentStep)
                : FenixuzChatLockStrings.textTitle(mode: currentStep)
            subtitleLabel.numberOfLines = 0
            subtitleLabel.text = FenixuzChatLockStrings.biometricEnrollmentChanged
            return
        }

        // Zenlygram — Chat Lock Center (spec §2.4): an explicit caption outranks the chat title, which outranks
        // the step default. Empty strings count as unset.
        let override: String? = {
            if let subtitleOverride, !subtitleOverride.isEmpty {
                return subtitleOverride
            }
            return nil
        }()

        if setupPhase == .pickType {
            titleLabel.text    = FenixuzChatLockStrings.chooseTypeTitle
            subtitleLabel.text = override ?? ""
            return
        }

        switch chosenType {
        case .pin:
            titleLabel.text    = FenixuzChatLockStrings.pinTitle(mode: currentStep)
            subtitleLabel.text = FenixuzChatLockStrings.pinSubtitle(mode: currentStep)
        case .text:
            titleLabel.text    = FenixuzChatLockStrings.textTitle(mode: currentStep)
            subtitleLabel.text = FenixuzChatLockStrings.textSubtitle(mode: currentStep)
        }
        switch currentStep {
        case .verify:
            // Zenlygram — name the chat whose PIN is asked for (the master screen keeps its own copy).
            if let override {
                subtitleLabel.text = override
            } else if let chatTitle, !chatTitle.isEmpty {
                subtitleLabel.text = chatTitle
            }
        case .verifyMaster, .disableChatLock, .enterNew:
            if let override {
                subtitleLabel.text = override
            }
        case .confirmNew, .verifyMasterForVault:
            // "Re-enter the same code" always stays; the vault rung keeps its copy.
            break
        }
    }

    // MARK: - Biometric auto-attempt

    // SG: Chat Lock — set on the first viewDidAppear, so biometrics are auto-attempted at most once per screen.
    private var didAutoAttemptBiometric = false

    /// SG: Chat Lock — false on a master-pincode screen (the one "Forgot pincode?" pushes, or the Settings
    /// screen that turns Chat Lock off): success there is destructive (it removes the chat's lock or turns
    /// Chat Lock off), so a single glance must not do it before the user has read the screen. It takes an
    /// explicit tap on the biometric button or the master pincode.
    private var autoAttemptsBiometric: Bool {
        if isMasterRecovery {
            return false
        }
        if case .resetChatLock = recovery {
            return false
        }
        if isCredentialLost {
            return false
        }
        // Zenlygram — Chat Lock Center (spec §2.4): management screens never auto-attempt.
        if purpose == .manage {
            return false
        }
        return true
    }

    private func attemptBiometricIfNeeded() {
        // onVerify is not needed for the biometric path — bind to _ to silence the warning.
        guard case .verify(_, let enabled, _, let onSuccess, _) = mode,
              enabled,
              !enrollmentChangedOnThisScreen,
              ChatLockBiometricHelper.availableType() != nil
        else { return }

        // SG: Chat Lock — the Settings screen that turns Chat Lock off names the feature, not "this chat".
        let reason = currentStep == .disableChatLock ? FenixuzChatLockStrings.disableChatLockBiometricReason : FenixuzChatLockStrings.biometricReason
        // Zenlygram — audit #40: `slot` makes the helper compare the device's current biometric enrolment
        // against the baseline this credential was set with, BEFORE any sheet is shown.
        ChatLockBiometricHelper.evaluate(reason: reason, slot: biometricSlot) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                // Zenlygram — proving identity biometrically clears this credential's lockout too.
                ChatLockThrottle.reset(self.throttleScope)
                self.lastSuccessMethod = .biometric
                self.onWillSucceed?()
                self.dismissSelf { onSuccess() }
            case .cancelled:
                // User dismissed — leave the PIN/text field ready for manual entry.
                break
            case .unavailable:
                // Biometrics failed (lockout, not enrolled). Fall through to manual entry.
                break
            case .enrollmentChanged:
                // Zenlygram — audit #40: a face or fingerprint enrolled after this credential was set must
                // not inherit its power. No sheet was shown and this is NOT a wrong entry (never throttled):
                // say so, drop the biometric button and ask for the pincode.
                guard !self.enrollmentChangedOnThisScreen else {
                    return
                }
                self.enrollmentChangedOnThisScreen = true
                self.syncVisibility()
                self.updateLabels()
                UIAccessibility.post(notification: .announcement, argument: FenixuzChatLockStrings.biometricEnrollmentChanged)
            }
        }
    }

    /// Zenlygram — audit #40: offered once the right pincode has been entered on a screen whose biometric
    /// unlock was refused for a changed enrolment. Only the credential's owner ever reaches this.
    private func presentBiometricEnrollmentConfirmation(provenCode: String, completion: @escaping () -> Void) {
        let slot = self.biometricSlot
        let masterType = self.chosenType
        let alert = UIAlertController(
            title: FenixuzChatLockStrings.biometricEnrollmentKeepTitle,
            message: FenixuzChatLockStrings.biometricEnrollmentKeepText,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FenixuzChatLockStrings.biometricEnrollmentKeep, style: .default) { _ in
            ChatPincodeManager.shared.recordBiometricBaseline(slot)
            completion()
        })
        alert.addAction(UIAlertAction(title: FenixuzChatLockStrings.biometricEnrollmentPinOnly, style: .cancel) { _ in
            switch slot {
            case .vault:
                ChatPincodeManager.shared.setVaultBiometricEnabled(false)
            case let .chat(peerId):
                ChatPincodeManager.shared.setBiometricEnabled(false, for: peerId)
            case .master:
                // The manager has no metadata-only setter for the master credential, so rewrite the record
                // with the code the user just proved. It also accepts the new enrolment as the master's
                // baseline — harmless, because getting here already required the master pincode, and
                // biometric unlock of the master is off from now on.
                if !provenCode.isEmpty {
                    ChatPincodeManager.shared.setMasterPincode(provenCode, type: masterType, biometricEnabled: false)
                }
            }
            completion()
        })
        // Present on the enclosing UIKit container: Display.ViewController.present reroutes to the window
        // root, which is already showing this screen, where the alert would silently never appear.
        (self.navigationController ?? self).present(alert, animated: true)
    }

    // MARK: - Text field focus

    private func activateTextFieldIfNeeded() {
        guard setupPhase == .enterCredential, chosenType == .text else { return }
        textField.becomeFirstResponder()
    }

    // MARK: - Type picker action

    @objc private func typePickerTapped(_ sender: UIButton) {
        chosenType = (sender.tag == 0) ? .pin : .text
        setupPhase = .enterCredential
        currentStep = .enterNew
        enteredCode = ""
        firstCode = ""
        syncVisibility()
        updateLabels()
        if chosenType == .text {
            textField.text = ""
            textField.becomeFirstResponder()
        }
    }

    // MARK: - Number pad actions

    @objc private func padPressed(_ sender: UIButton) {
        UIView.animate(withDuration: 0.05) {
            sender.transform = CGAffineTransform(scaleX: 0.93, y: 0.93)
        }
    }

    @objc private func padReleased(_ sender: UIButton) {
        UIView.animate(withDuration: 0.1) {
            sender.transform = .identity
        }
    }

    @objc private func padTapped(_ sender: UIButton) {
        guard let title = sender.titleLabel?.text else { return }

        if title == "⌫" {
            if !enteredCode.isEmpty {
                enteredCode.removeLast()
                syncDots()
            }
        } else {
            guard enteredCode.count < 4 else { return }
            enteredCode.append(title)
            syncDots()
            if enteredCode.count == 4 {
                processCredential(enteredCode)
            }
        }
    }

    // MARK: - Submit button (text mode)

    @objc private func submitTapped() {
        // Zenlygram — audit #70 / #71: on the recovery screen this button IS the primary action.
        if case let .credentialLost(_, _, _, onPrimary, _, _) = recovery {
            onPrimary()
            return
        }
        let code = (textField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        textField.resignFirstResponder()
        enteredCode = code
        processCredential(code)
    }

    // MARK: - Biometric button

    @objc private func biometricTapped() {
        attemptBiometricIfNeeded()
    }

    // MARK: - Analytics (Zenlygram, design 40 §10.2)

    /// The screen a PIN screen reports, from its mode, throttle scope and purpose; nil for the secret-code
    /// search gate, which is not a screen of its own.
    /// Zenlygram — Chat Lock Center (spec §2.4, §6 C7): `.vault` / `.legacy` — `.verify` → `vault.unlock`,
    /// `.set` → `vault.settings`; `.chat` — `.verify(.unlock)` → `chat_lock.unlock`, `.verify(.manage)` and
    /// `.set` → `chat_lock.settings`; `.master` → `chat_lock.settings`. (The retired `.remove` mode reported
    /// `chat_lock.settings`, which its replacement — a `.manage` verify — still does.)
    static func analyticsScreen(mode: ChatPincodeMode, scope: ChatLockThrottle.Scope, purpose: ChatPincodePurpose = .unlock) -> SGAnalyticsScreen? {
        switch scope {
        case .vaultSearch:
            return nil
        case .vault, .legacy:
            switch mode {
            case .verify:
                return .vaultUnlock
            case .set:
                return .vaultSettings
            }
        case .chat:
            switch mode {
            case .verify:
                return purpose == .manage ? .chatLockSettings : .chatLockUnlock
            case .set:
                return .chatLockSettings
            }
        case .master:
            return .chatLockSettings
        }
    }

    // MARK: - Forgot pincode

    /// The optional master-recovery handler — present only in `.verify` mode.
    private var verifyOnForgot: (() -> Void)? {
        if case let .verify(_, _, _, _, onForgot) = mode {
            return onForgot
        }
        return nil
    }

    @objc private func forgotTapped() {
        switch recovery {
        case .legacy:
            if isMasterRecovery {
                resetChatLockTapped()
            } else {
                forgotVaultTapped()
            }
        case let .masterPin(makeMasterController):
            // Zenlygram — push the master-pincode screen inside this same modal: no dismiss, no
            // LocalAuthentication. Its close button pops back here.
            navigationController?.pushViewController(makeMasterController(), animated: true)
        case .resetChatLock:
            resetChatLockTapped()
        case let .credentialLost(_, _, _, _, _, onSecondary):
            // Zenlygram — audit #70 / #71: the optional second action (e.g. "Turn off Chat Lock").
            onSecondary?()
        }
    }

    /// True when the recovery button is "Reset Chat Lock" (master screen) rather than "Forgot pincode?".
    private var showsResetRecovery: Bool {
        switch recovery {
        case .legacy:
            return isMasterRecovery
        case .masterPin, .credentialLost:
            return false
        case .resetChatLock:
            return true
        }
    }

    /// True when this screen offers any recovery at all.
    private var hasRecovery: Bool {
        switch recovery {
        case .legacy:
            return isMasterRecovery || verifyOnForgot != nil
        case .masterPin, .resetChatLock:
            return true
        case .credentialLost:
            // Nothing is ever entered here, so there is no "you have struggled" moment to reveal.
            return false
        }
    }

    /// Forgotten vault PIN recovery (Zenlygram — audit #40). The vaulted chats are only PIN-gated (not
    /// separately encrypted), so a device-owner proof is enough to recover — but NOT the iPhone passcode:
    /// the vault's whole purpose is hiding chats from someone who already knows that passcode. The ladder is
    ///   1. Face ID / Touch ID, and only with the enrolment the vault PIN was set with;
    ///   2. the Chat Lock master pincode, asked for on a pushed screen (no LocalAuthentication) — and ONLY
    ///      when that master already existed when the vault PIN was set (see `continueVaultRecoveryWithMaster`);
    ///   3. an honest "cannot be recovered on this iPhone" alert.
    /// A failed biometric MATCH is `.cancelled` (ChatLockBiometricHelper, audit batch 4), so presenting an
    /// unrecognised face never walks the ladder down a rung — the vault PIN screen simply stays put.
    /// Mirrors the successful-verify path: dismiss self, then run the caller's handler.
    private func forgotVaultTapped() {
        guard verifyOnForgot != nil else { return }
        guard ChatPincodeManager.shared.biometricEnrollment(for: .vault) == .unchanged else {
            self.continueVaultRecoveryWithMaster()
            return
        }
        ChatLockBiometricHelper.evaluateBiometricOwner(reason: FenixuzChatLockStrings.forgotVaultReason, slot: .vault) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                guard let onForgot = self.verifyOnForgot else { return }
                self.onRecoveryWillSucceed?(.biometric)
                self.dismissSelf { onForgot() }
            case .cancelled:
                // Dismissed the sheet, or the face simply did not match — the vault PIN screen is still
                // there, and the ladder does NOT advance (audit batch 4).
                break
            case .unavailable, .enrollmentChanged:
                // Biometrics genuinely went away (or the enrolment changed) between the check and the sheet:
                // offer the next rung rather than leaving the user with a button that does nothing.
                self.continueVaultRecoveryWithMaster()
            }
        }
    }

    /// Rung 2 and 3 of the vault recovery ladder (see `forgotVaultTapped`).
    private func continueVaultRecoveryWithMaster() {
        guard let onForgot = verifyOnForgot else { return }
        let manager = ChatPincodeManager.shared
        // Zenlygram — audit batch 4: the master rung is offered ONLY when the master is a secret the user
        // already had when the vault PIN was set. Settings presents the "set master pincode" screen with no
        // authentication whatsoever, so a master created after the fact would hand the vault to anyone
        // holding an unlocked iPhone — exactly the threat the vault exists for. No master, a newer one, an
        // unreadable marker or a vault record from before this scheme all fall through to the honest alert.
        if manager.vaultRecoveryAcceptsMasterPincode() {
            let metadata = manager.getMasterMetadata()
            // Held by value: this screen may be gone when the pushed master screen succeeds.
            let recovered = self.onRecoveryWillSucceed
            // Pushed on the SAME UIKit stack (its close button pops back here). Its own success dismisses
            // the whole container and then runs `onForgot`, exactly like the biometric rung above.
            // No "Forgot"/"Reset" of its own: resetting Chat Lock would not open the vault (dead end).
            let masterController = ChatPincodeViewController(
                mode: .verify(
                    passwordType: metadata.passwordType,
                    biometricEnabled: false,
                    onVerify: { code in
                        return manager.verifyMaster(code)
                    },
                    onSuccess: {
                        recovered?(.code(metadata.passwordType))
                        onForgot()
                    },
                    onForgot: nil
                ),
                presentationData: self.presentationData,
                recovery: .legacy,
                throttleScope: .master,
                verifiesMasterForVaultRecovery: true
            )
            self.navigationController?.pushViewController(masterController, animated: true)
            return
        }
        // Nothing is left on this iPhone that could stand in for the vault PIN. Fail closed and say so.
        let alert = UIAlertController(title: FenixuzChatLockStrings.recoveryUnavailableTitle, message: FenixuzChatLockStrings.recoveryUnavailableText, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: FenixuzChatLockStrings.done, style: .default, handler: nil))
        // Present via the navigation controller: Display.ViewController.present reroutes to the
        // window root (already showing this pincode screen), where the alert would silently not appear.
        (self.navigationController ?? self).present(alert, animated: true)
    }

    // MARK: - Master reset (forgot the master too)

    /// Escape hatch when the user has ALSO forgotten the master pincode. Chat Lock is a local
    /// privacy gate (messages live on Telegram's servers), so a device-owner-proven reset loses
    /// no data. Requires the device Face/Touch ID or passcode so a snooper can't just tap it.
    private func resetChatLockTapped() {
        let alert = UIAlertController(
            title: FenixuzChatLockStrings.resetConfirmTitle,
            message: FenixuzChatLockStrings.resetConfirmMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FenixuzChatLockStrings.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: FenixuzChatLockStrings.resetConfirmAction, style: .destructive) { [weak self] _ in
            self?.authenticateThenReset()
        })
        // Zenlygram — present via the enclosing UIKit navigation controller: Display.ViewController.present
        // reroutes to the window root (already presenting this screen), where the alert silently never showed.
        (self.navigationController ?? self).present(alert, animated: true)
    }

    private func authenticateThenReset() {
        let proceed: () -> Void = { [weak self] in
            guard let self else { return }
            ChatPincodeManager.shared.disableChatLock()
            // Zenlygram — the user turned Chat Lock off (design 40 §10.2); a reset unlocks nothing.
            SGAnalytics.record(.chatLockLockRemoved)
            if case let .resetChatLock(onReset) = self.recovery {
                ChatLockThrottle.resetAll()
                self.lastSuccessMethod = .reset
                self.onWillSucceed?()
                self.dismissSelf { onReset() }
            } else if case let .verify(_, _, _, onSuccess, _) = self.mode {
                self.dismissSelf { onSuccess() }
            } else {
                self.dismissSelf()
            }
        }
        // Zenlygram — audit #40: device-owner proof, with the enrolment taken into account.
        //  - the enrolment the master pincode was set with → biometrics only;
        //  - no usable biometrics at all → the iPhone passcode (Chat Lock is a local gate, and the passcode
        //    already opens this iPhone), but only when the device actually has one;
        //  - a CHANGED enrolment → an explicit "this iPhone changed" confirmation, then the passcode (batch 4:
        //    a re-enrolled face must not silently keep the master's power, but it must not turn the reset into
        //    a permanent dead end for a user who also forgot the master pincode);
        //  - a device that can prove nothing at all → refuse. The old `else { proceed() }` handed a reset to
        //    anyone holding a passcode-less iPhone.
        switch ChatPincodeManager.shared.biometricEnrollment(for: .master) {
        case .unchanged:
            ChatLockBiometricHelper.evaluateBiometricOwner(reason: FenixuzChatLockStrings.resetReason, slot: .master) { [weak self] result in
                switch result {
                case .success:
                    proceed()
                case .cancelled:
                    break
                case .unavailable, .enrollmentChanged:
                    // Biometrics became unusable (e.g. locked out after too many failures) between the
                    // check and the sheet: the passcode rung below is the same device-owner proof.
                    self?.authenticateResetWithDevicePasscode(proceed: proceed)
                }
            }
        case .unavailable:
            self.authenticateResetWithDevicePasscode(proceed: proceed)
        case .changed:
            // Zenlygram — audit #40: the enrolment changed after the master was set, so Face ID / Touch ID
            // proves nothing here. It must not be a dead end either: adding an Alternate Appearance or a
            // second fingerprint would otherwise strand, for good, a user who has also forgotten the master
            // pincode. Confirm explicitly, then ask for the device passcode — the same device-owner proof
            // the `.unavailable` rung uses, and legitimate for CHAT LOCK, which is a local gate whose reset
            // deletes no messages. The VAULT ladder never gets a passcode rung.
            self.presentResetAfterEnrollmentChange(proceed: proceed)
        }
    }

    /// Reset rung for a CHANGED biometric enrolment (audit #40): an explicit confirmation, then the device
    /// passcode. `authenticateResetWithDevicePasscode` refuses by itself on a device that can prove nothing.
    private func presentResetAfterEnrollmentChange(proceed: @escaping () -> Void) {
        let alert = UIAlertController(
            title: FenixuzChatLockStrings.resetEnrollmentChangedTitle,
            message: FenixuzChatLockStrings.resetEnrollmentChangedText,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FenixuzChatLockStrings.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: FenixuzChatLockStrings.resetEnrollmentChangedConfirm, style: .default) { [weak self] _ in
            self?.authenticateResetWithDevicePasscode(proceed: {
                // Accept the enrolment the device owner just confirmed BEFORE the reset runs, so the master
                // slot never keeps describing an enrolment the owner has already disowned. (Today `proceed()`
                // also disables Chat Lock, which drops the baseline together with the credential; doing it in
                // this order keeps the slot correct for any future caller whose `proceed` does not.)
                ChatPincodeManager.shared.recordBiometricBaseline(.master)
                proceed()
            })
        })
        (self.navigationController ?? self).present(alert, animated: true)
    }

    /// Reset rung 2: the iPhone passcode (biometrics included), refused when the device has neither.
    private func authenticateResetWithDevicePasscode(proceed: @escaping () -> Void) {
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            self.presentResetRefused()
            return
        }
        ChatLockSession.shared.isAuthenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: FenixuzChatLockStrings.resetReason) { success, _ in
            DispatchQueue.main.async {
                ChatLockSession.shared.isAuthenticating = false
                if success { proceed() }
            }
        }
    }

    private func presentResetRefused() {
        let alert = UIAlertController(title: FenixuzChatLockStrings.resetRefusedTitle, message: FenixuzChatLockStrings.resetRefusedText, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: FenixuzChatLockStrings.done, style: .default, handler: nil))
        (self.navigationController ?? self).present(alert, animated: true)
    }

    /// After 4 wrong entries we never lock the owner out — we make the recovery obvious instead.
    private func revealRecovery() {
        guard hasRecovery else { return }
        subtitleLabel.text = FenixuzChatLockStrings.recoveryHint
        subtitleLabel.textColor = presentationData.theme.overallDarkAppearance
            ? UIColor(white: 1, alpha: 0.5) : UIColor(white: 0, alpha: 0.6)
        // VoiceOver: announce that recovery is now available (otherwise a silent visual hint).
        UIAccessibility.post(notification: .announcement, argument: FenixuzChatLockStrings.recoveryHint)
        if showsResetRecovery {
            forgotButton.isHidden = false
        } else if case .legacy = recovery, verifyOnForgot != nil {
            // Zenlygram — audit #40: the vault's "Forgot" is hidden until the user has struggled too.
            forgotButton.isHidden = false
        }
        guard !forgotButton.isHidden else { return }
        UIView.animate(withDuration: 0.15, animations: { self.forgotButton.transform = CGAffineTransform(scaleX: 1.12, y: 1.12) }, completion: { _ in
            UIView.animate(withDuration: 0.15) { self.forgotButton.transform = .identity }
        })
    }

    // MARK: - Core credential processing
    //
    // Brute-force throttle (ChatLockThrottle, persisted per credential scope): after 5 consecutive failures
    // any entry is rejected WITHOUT checking the credential for an exponentially growing window. Only
    // verifying an EXISTING credential is throttled — choosing a new PIN (.set) never is, so a lockout can
    // no longer block setting a new PIN.
    // SG: Chat Lock — every chat's screen is also gated by one budget shared by all chats and the master, which
    // a chat success cannot refund beyond that chat's own failures (see ChatLockThrottle), so locking a spare
    // chat with a known PIN buys no extra guesses.

    private func processCredential(_ code: String) {
        let isThrottled: Bool
        switch mode {
        case .verify:
            isThrottled = true
        case .set:
            isThrottled = false
        }
        if isThrottled {
            let remaining = ChatLockThrottle.remaining(throttleScope)
            if remaining > 0 {
                // Throttled: reject the entry without ever checking it against the stored credential.
                let msg = FenixuzChatLockStrings.tooManyAttempts(seconds: remaining)
                shakeAndReset(isPasswordMode: chosenType == .text, message: msg)
                if forgotButton.isHidden {
                    // A locked-out screen must still offer the way out: the master screen's Reset, and
                    // (Zenlygram — audit #40) the vault PIN screen's "Forgot", which is otherwise hidden
                    // until the user has struggled.
                    var revealsRecovery = false
                    if case .resetChatLock = recovery {
                        revealsRecovery = true
                    } else if case .legacy = recovery, verifyOnForgot != nil {
                        revealsRecovery = true
                    }
                    if revealsRecovery {
                        forgotButton.isHidden = false
                        UIAccessibility.post(notification: .layoutChanged, argument: forgotButton)
                    }
                }
                return
            }
        }
        switch mode {

        case let .set(onSuccess):
            handleSetFlow(code: code, onSuccess: onSuccess)

        case let .verify(passwordType, _, onVerify, onSuccess, _):
            if onVerify(code) {
                ChatLockThrottle.reset(throttleScope)
                let finish: () -> Void = { [weak self] in
                    guard let self else { return }
                    self.lastSuccessMethod = .code(passwordType)
                    self.onWillSucceed?()
                    self.dismissSelf { onSuccess() }
                }
                if enrollmentChangedOnThisScreen {
                    // Zenlygram — audit #40: the credential's owner is here, so let them decide explicitly
                    // whether the new Face ID / Touch ID enrolment may unlock this credential from now on.
                    presentBiometricEnrollmentConfirmation(provenCode: code, completion: finish)
                } else {
                    finish()
                }
            } else {
                failedAttempts += 1
                ChatLockThrottle.registerFailure(throttleScope)
                shakeAndReset(isPasswordMode: chosenType == .text)
                // Zenlygram — audit #40: one rule for every screen, `.legacy` (the vault) included — a live
                // lockout reveals the way out, so a fresh screen during a lockout is never a dead end.
                if failedAttempts >= 4 || ChatLockThrottle.remaining(throttleScope) > 0 {
                    revealRecovery()
                }
            }
        }
    }

    // MARK: - Setup flow state machine

    private func handleSetFlow(code: String, onSuccess: @escaping (String, ChatLockPasswordType, Bool) -> Void) {
        switch setupPhase {

        case .enterCredential:
            // First entry — ask for confirmation.
            firstCode = code
            enteredCode = ""
            setupPhase = .confirmCredential
            currentStep = .confirmNew
            updateLabels()
            if chosenType == .text {
                textField.text = ""
                textField.becomeFirstResponder()
            } else {
                syncDots()
            }

        case .confirmCredential:
            if code == firstCode {
                // Codes match — finish setup immediately. Enable biometrics by default when the
                // device supports them: Face ID is the default the user wants, PIN stays the
                // fallback, and Settings lets them turn it off. The previous in-place
                // UIAlertController "offer" could NOT present over this fullScreen pincode flow
                // (Display.ViewController.present routes to the already-busy rootViewController),
                // so it silently failed and hung the confirm step on real devices — removed.
                let hasBiometric = ChatLockBiometricHelper.availableType() != nil
                dismissSelf {
                    onSuccess(self.firstCode, self.chosenType, hasBiometric)
                }
            } else {
                // Mismatch — reset to first entry.
                let msg = (chosenType == .pin)
                    ? FenixuzChatLockStrings.mismatch
                    : FenixuzChatLockStrings.passwordMismatch
                shakeAndReset(isPasswordMode: chosenType == .text, message: msg)
                setupPhase = .enterCredential
                currentStep = .enterNew
            }

        default:
            break
        }
    }

    // MARK: - Biometric offer alert

    private func presentBiometricOffer(type: ChatLockBiometricType, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: FenixuzChatLockStrings.biometricPromptTitle,
            message: FenixuzChatLockStrings.biometricPromptSubtitle(type: type),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: FenixuzChatLockStrings.biometricEnable,
            style: .default
        ) { _ in completion(true) })
        alert.addAction(UIAlertAction(
            title: FenixuzChatLockStrings.biometricSkip,
            style: .cancel
        ) { _ in completion(false) })
        // `self` is a Display.ViewController whose present() routes to the window's
        // rootViewController — which is ALREADY presenting this pincode flow, so the alert
        // silently fails to appear and the confirm step hangs. This surfaces only on real
        // devices (the offer is reached only when biometrics exist; the simulator skips it).
        // Present on the enclosing UIKit navigation controller — the topmost presented
        // controller — instead, mirroring dismissSelf's reason for using navigationController.
        (self.navigationController ?? self).present(alert, animated: true)
    }

    // MARK: - Dot sync

    private func syncDots() {
        let accentColor = UIColor(rgb: presentationData.theme.list.itemAccentColor.rgb)
        let isDark = presentationData.theme.overallDarkAppearance
        // VoiceOver: mirror the visual fill state into the row's value ("N of M entered").
        dotsView.accessibilityValue = FenixuzChatLockStrings.pinDigitsEntered(count: enteredCode.count, total: dotViews.count)
        for (i, dot) in dotViews.enumerated() {
            let filled = i < enteredCode.count
            UIView.animate(withDuration: 0.15) {
                dot.backgroundColor = filled ? accentColor : .clear
                // Empty-dot borders raised (0.3/0.25 → 0.4/0.45) to clear the 3:1
                // non-text contrast minimum against the screen background.
                dot.layer.borderColor = filled
                    ? accentColor.cgColor
                    : (isDark
                        ? UIColor(white: 1, alpha: 0.4).cgColor
                        : UIColor(white: 0, alpha: 0.45).cgColor)
                dot.transform = filled ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
            }
        }
    }

    // MARK: - Shake & reset

    /// Darkens `color` step-by-step until it reaches at least `minimumRatio` WCAG contrast
    /// against the (light) `background`. Darkening monotonically increases contrast on a
    /// light background, so the loop terminates; the theme accent is user-configurable,
    /// which is why a fixed darker constant can't be used here.
    private static func darkenedForContrast(_ color: UIColor, against background: UIColor, minimumRatio: CGFloat = 4.5) -> UIColor {
        func luminance(_ c: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        let backgroundLuminance = luminance(background)
        var candidate = color
        for _ in 0..<12 {
            let candidateLuminance = luminance(candidate)
            let ratio = (max(backgroundLuminance, candidateLuminance) + 0.05) / (min(backgroundLuminance, candidateLuminance) + 0.05)
            if ratio >= minimumRatio {
                return candidate
            }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            candidate.getRed(&r, green: &g, blue: &b, alpha: &a)
            candidate = UIColor(red: r * 0.85, green: g * 0.85, blue: b * 0.85, alpha: a)
        }
        return candidate
    }

    private func shakeAndReset(isPasswordMode: Bool, message: String? = nil) {
        let errorMsg = message ?? (isPasswordMode
            ? FenixuzChatLockStrings.wrongPassword
            : FenixuzChatLockStrings.wrongCode)
        subtitleLabel.text = errorMsg
        // Theme-aware error red: 0xff3b30 is only ~3.4:1 on the light 0xf2f2f7 background,
        // so use the darker system-red variant there; 0xff453a gives ~5:1 on 0x1c1c1e.
        subtitleLabel.textColor = presentationData.theme.overallDarkAppearance
            ? UIColor(rgb: 0xff453a)
            : UIColor(rgb: 0xd70015)
        // VoiceOver: announce the failure — the reset is otherwise a silent visual-only change.
        UIAccessibility.post(notification: .announcement, argument: errorMsg)

        let target: UIView = isPasswordMode ? textField : dotsView
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.duration = 0.4
        anim.values = [-10, 10, -8, 8, -5, 5, 0]
        target.layer.add(anim, forKey: "shake")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.enteredCode = ""
            if isPasswordMode {
                self.textField.text = ""
                self.textField.becomeFirstResponder()
            } else {
                self.syncDots()
            }
            self.updateLabels()
        }
    }

    // MARK: - Dismiss

    private func dismissSelf(completion: (() -> Void)? = nil) {
        // ChatPincodeViewController inherits Display.ViewController, whose
        // dismiss(animated:completion:) override silently drops the completion
        // (Display/Source/ViewController.swift:575). Our enclosing controller is a
        // plain UIKit UINavigationController, so dismiss THAT to get UIKit's real
        // completion — otherwise onSuccess (which stores / verifies the pincode)
        // never runs and the lock silently no-ops.
        let captured = completion
        if let displayNavController = self.navigationController as? NavigationController, displayNavController.presentingViewController == nil {
            // Pushed onto the app's Display navigation stack (not presented): there is nothing to
            // dismiss — Display's dismiss would silently drop the completion — so pop and complete.
            displayNavController.filterController(self, animated: true)
            captured?()
        } else if let navController = self.navigationController {
            navController.dismiss(animated: true) { captured?() }
        } else {
            self.presentingViewController?.dismiss(animated: true) { captured?() }
        }
    }

    // MARK: - Close

    @objc private func closeTapped() {
        // Zenlygram — a screen pushed onto the prompt's UIKit stack (the master-pincode recovery screen)
        // steps back to the screen below instead of cancelling the whole prompt.
        if let navigationController = self.navigationController, !(navigationController is NavigationController), navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
            return
        }
        let cancel = self.onCancel
        dismissSelf { cancel?() }
    }

    // MARK: - Setup phase enum (private)

    private enum SetupPhase {
        case pickType
        case enterCredential
        case confirmCredential
        case offerBiometric
    }
}

// MARK: - UITextFieldDelegate

extension ChatPincodeViewController: UITextFieldDelegate {
    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitTapped()
        return false
    }
}

// MARK: - UINavigationControllerDelegate

extension ChatPincodeViewController: UINavigationControllerDelegate {
    // Zenlygram — see willMove(toParent:): lets the plain UIKit container honor our orientations.
    public func navigationControllerSupportedInterfaceOrientations(_ navigationController: UINavigationController) -> UIInterfaceOrientationMask {
        return self.supportedInterfaceOrientations
    }
}

// MARK: - Keypad view

/// Zenlygram — hosts the 3×4 keys and lays them out proportionally to its bounds (76pt keys and
/// 14pt gaps at full size, centered), so the keypad scales down instead of running off-screen or
/// under "Forgot" when the PIN screen is short: iPad mini landscape, Split View / Stage Manager
/// windows, small phones, large Dynamic Type headers.
private final class ChatPincodeKeypadView: UIView {
    private static let keySize: CGFloat = 76
    private static let spacing: CGFloat = 14

    override func layoutSubviews() {
        super.layoutSubviews()
        let fullWidth = 3 * Self.keySize + 2 * Self.spacing
        let fullHeight = 4 * Self.keySize + 3 * Self.spacing
        let scale = max(0, min(1, self.bounds.width / fullWidth, self.bounds.height / fullHeight))
        let keySize = floor(Self.keySize * scale)
        let spacing = floor(Self.spacing * scale)
        let originX = floor((self.bounds.width - (3 * keySize + 2 * spacing)) / 2)
        let originY = floor((self.bounds.height - (4 * keySize + 3 * spacing)) / 2)
        for case let button as UIButton in self.subviews {
            // The tag is the key's index in the 3-column grid (set in buildNumberPad).
            let row = CGFloat(button.tag / 3)
            let column = CGFloat(button.tag % 3)
            // bounds + center rather than frame: a key may be mid press-animation (scale transform).
            button.bounds = CGRect(x: 0, y: 0, width: keySize, height: keySize)
            button.center = CGPoint(
                x: originX + column * (keySize + spacing) + keySize / 2,
                y: originY + row * (keySize + spacing) + keySize / 2
            )
            button.layer.cornerRadius = keySize / 2
        }
    }
}
