import Foundation
import UndoUI
import AccountContext
import TelegramCore
import Postbox
import Display
import SwiftSignalKit
import TelegramPresentationData
import PresentationDataUtils
import SGSimpleSettings
import SGLogging
import SGKeychainBackupManager

struct SessionBackup: Codable {
    var name: String? = nil
    var date: Date = Date()
    let accountRecord: AccountRecord<TelegramAccountManagerTypes.Attribute>
    
    var peerIdInternal: Int64 {
        var userId: Int64 = 0
        for attribute in accountRecord.attributes {
            if case let .backupData(backupData) = attribute, let backupPeerID = backupData.data?.peerId {
                userId = backupPeerID
                break
            }
        }
        return userId
    }
    
    var userId: Int64 {
        return PeerId(peerIdInternal).id._internalGetInt64Value()
    }
}

import SwiftUI
import SGSwiftUI
import LegacyUI
import SGStrings
import SGTasks
import UIKit
import LocalAuthentication


/// Zenlygram — audit #43: lives in `UserDefaults.standard`, so it dies with the app container on
/// delete. Its absence at the first unlock means the stored sessions were written by a *previous*
/// installation of the app on this iPhone (the Keychain outlives the container).
private let sessionBackupInstallMarkerKey = "zg.backup.installMarker"


@available(iOS 13.0, *)
struct SessionBackupRow: View {
    @Environment(\.lang) var lang: String
    let backup: SessionBackup
    let isLoggedIn: Bool
    
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
    
    var formattedDate: String {
        if #available(iOS 15.0, *) {
            return backup.date.formatted(date: .abbreviated, time: .shortened)
        } else {
            return dateFormatter.string(from: backup.date)
        }
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.name ?? String(backup.userId))
                    .font(.body)
                
                Text("ID: \(backup.userId)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text("SessionBackup.LastBackupAt".i18n(lang, args: formattedDate))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text((isLoggedIn ? "SessionBackup.LoggedIn" : "SessionBackup.LoggedOut").i18n(lang))
                .font(.caption)
                .foregroundColor(isLoggedIn ? .white : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isLoggedIn ? Color.accentColor : Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
        .padding(.vertical, 4)
    }
}


@available(iOS 13.0, *)
struct BorderedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

@available(iOS 13.0, *)
struct SessionBackupManagerView: View {
    @Environment(\.lang) var lang: String
    weak var wrapperController: LegacyController?
    let context: AccountContext
    
    @State private var sessions: [SessionBackup] = []
    @State private var loggedInPeerIDs: [Int64] = []
    @State private var loggedInAccountsDisposable: Disposable? = nil

    // Zenlygram — audit #43: the backup holds live auth keys, so the screen itself is the gate.
    // Gating in the view (rather than at the push site) covers every entry route, and keeps SGProUI
    // free of any SGChatLock / SGProtectedStore dependency. Nothing is read from the Keychain until
    // `isUnlocked` is true, and it drops back to false as soon as the app is backgrounded.
    @State private var isUnlocked: Bool = false
    @State private var isAuthenticating: Bool = false
    @State private var didRequestInitialUnlock: Bool = false
    @State private var loadErrorText: String? = nil
    @State private var backgroundObserver: NSObjectProtocol? = nil
    
    private func performBackup() {
        let controller = OverlayStatusController(theme: context.sharedContext.currentPresentationData.with { $0 }.theme, type: .loading(cancelled: nil))
        
        let signal = context.sharedContext.accountManager.accountRecords()
        |> take(1)
        |> deliverOnMainQueue
        
        let signal2 = context.sharedContext.activeAccountsWithInfo
        |> take(1)
        |> deliverOnMainQueue
        
        wrapperController?.present(controller, in: .window(.root), with: nil)
        
        Task {
            if let result = try? await combineLatest(signal, signal2).awaitable() {
                let (view, accountsWithInfo) = result
                backupSessionsFromView(view, accountsWithInfo: accountsWithInfo.1)
                // This installation now owns what is stored, so the "previous installation" notice
                // must not fire for it later (audit #43).
                UserDefaults.standard.set(true, forKey: sessionBackupInstallMarkerKey)
                reloadSessions()
                controller.dismiss()
            }
        }
        
    }
    
    /// Audit #43: Restore plants live auth keys into the app, so device ownership is proven again
    /// here (the screen unlock may be minutes old) and the user confirms how many accounts are added.
    private func performRestore() {
        authenticateDeviceOwner(reasonKey: "SessionBackup.AuthReason") { success in
            guard success else {
                return
            }
            confirmRestore()
        }
    }
    
    private func confirmRestore() {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let backupSessions = reloadSessions()
        if backupSessions.isEmpty {
            return
        }
        
        let controller = textAlertController(context: context, title: "SessionBackup.RestoreConfirm.Title".i18n(lang), text: "SessionBackup.RestoreConfirm.Text".i18n(lang, args: "\(backupSessions.count)"), actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {
                runRestore(backupSessions)
            }),
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {})
        ])
        
        wrapperController?.present(controller, in: .window(.root), with: nil)
    }
    
    private func runRestore(_ backupSessions: [SessionBackup]) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
        
        let _ = (context.sharedContext.accountManager.accountRecords()
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak controller] view in
            
            var restoredSessions: Int64 = 0
            
            func importNextBackup(index: Int) {
                // Check if we're done
                if index >= backupSessions.count {
                    // All done, update UI
                    reloadSessions()
                    controller?.dismiss()
                    wrapperController?.present(
                        okUndoController("SessionBackup.RestoreOK".i18n(lang, args: "\(restoredSessions)"), presentationData),
                        in: .current
                    )
                    return
                }
                
                let backup = backupSessions[index]
                
                // Check for existing record
                let existingRecord = view.records.first { record in
                    var userId: Int64 = 0
                    for attribute in record.attributes {
                        if case let .backupData(backupData) = attribute {
                            userId = backupData.data?.peerId ?? 0
                        }
                    }
                    return userId == backup.peerIdInternal
                }
                
                if existingRecord != nil {
                    SGLogger.shared.log("SessionBackup", "Record \(backup.userId) already exists, skipping")
                    importNextBackup(index: index + 1)
                    return
                }
                
                var importAttributes = backup.accountRecord.attributes
                importAttributes.removeAll { attribute in
                    if case .sortOrder = attribute {
                        return true
                    }
                    return false
                }
                
                let importBackupSignal = context.sharedContext.accountManager.transaction { transaction -> Void in
                    let nextSortOrder = (transaction.getRecords().map({ record -> Int32 in
                        for attribute in record.attributes {
                            if case let .sortOrder(sortOrder) = attribute {
                                return sortOrder.order
                            }
                        }
                        return 0
                    }).max() ?? 0) + 1
                    importAttributes.append(.sortOrder(AccountSortOrderAttribute(order: nextSortOrder)))
                    let accountRecordId = transaction.createRecord(importAttributes)
                    SGLogger.shared.log("SessionBackup", "Imported record \(accountRecordId) for \(backup.userId)")
                    restoredSessions += 1
                }
                |> deliverOnMainQueue
                
                let _ = importBackupSignal.start(completed: {
                    importNextBackup(index: index + 1)
                })
            }
            
            // Start the import chain
            importNextBackup(index: 0)
        })
        
        wrapperController?.present(controller, in: .window(.root), with: nil)
    }
    
    private func performDeleteAll() {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        let controller = textAlertController(context: context, title: "SessionBackup.DeleteAll.Title".i18n(lang), text: "SessionBackup.DeleteAll.Text".i18n(lang), actions: [
            TextAlertAction(type: .destructiveAction, title: presentationData.strings.Common_Delete, action: {
                let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
                wrapperController?.present(controller, in: .window(.root), with: nil)
                do {
                    try KeychainBackupManager.shared.deleteAllSessions()
                    reloadSessions()
                    controller.dismiss()
                } catch let e {
                    SGLogger.shared.log("SessionBackup", "Error deleting all sessions: \(e)")
                }
            }),
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_Cancel, action: {})
        ])
        
        wrapperController?.present(controller, in: .window(.root), with: nil)
    }
    
    private func performDelete(_ session: SessionBackup) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        let controller = textAlertController(context: context, title: "SessionBackup.DeleteSingle.Title".i18n(lang), text: "SessionBackup.DeleteSingle.Text".i18n(lang, args: "\(session.name ?? "\(session.userId)")"), actions: [
            TextAlertAction(type: .destructiveAction, title: presentationData.strings.Common_Delete, action: {
                let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
                wrapperController?.present(controller, in: .window(.root), with: nil)
                do {
                    try KeychainBackupManager.shared.deleteSession(for: "\(session.peerIdInternal)")
                    reloadSessions()
                    controller.dismiss()
                } catch let e {
                    SGLogger.shared.log("SessionBackup", "Error deleting session: \(e)")
                }
            }),
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_Cancel, action: {})
        ])
        
        wrapperController?.present(controller, in: .window(.root), with: nil)
    }
    
    
    private func performRemoveSessionFromApp(session: SessionBackup) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        var confirmationText = "SessionBackup.RemoveFromApp.Text".i18n(lang, args: "\(session.name ?? "\(session.userId)")")
        // Zenlygram — Tasks R4: what removing the account costs its cloud tasks (unsent changes, a
        // device-to-Cloud copy that resumes at the next sign-in); no line when nothing is waiting, the
        // generic notice when the counts cannot be read.
        if let tasksNotice = sgTasksLogoutNotice(accountPeerId: session.peerIdInternal, languageCode: lang, genericNotice: "Tasks.Cloud.LogoutNotice".i18n(lang)) {
            confirmationText += "\n\n" + tasksNotice
        }
        let controller = textAlertController(context: context, title: "SessionBackup.RemoveFromApp.Title".i18n(lang), text: confirmationText, actions: [
            TextAlertAction(type: .destructiveAction, title: presentationData.strings.Common_Delete, action: {
                let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
                wrapperController?.present(controller, in: .window(.root), with: nil)
                
                let signal = context.sharedContext.accountManager.accountRecords()
                |> take(1)
                |> deliverOnMainQueue
                
                let _ = signal.start(next: { [weak controller] view in
                    
                    // Find record to delete
                    let accountRecord = view.records.first { record in
                        var userId: Int64 = 0
                        for attribute in record.attributes {
                            if case let .backupData(backupData) = attribute {
                                userId = backupData.data?.peerId ?? 0
                            }
                        }
                        return userId == session.peerIdInternal
                    }
                    
                    if let record = accountRecord {
                        let deleteSignal = context.sharedContext.accountManager.transaction { transaction -> Void in
                            transaction.updateRecord(record.id, { _ in return nil})
                        }
                        |> deliverOnMainQueue
                        
                        let _ = deleteSignal.start(next: {
                            reloadSessions()
                            controller?.dismiss()
                        })
                    } else {
                        controller?.dismiss()
                    }
                })
                
            }),
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_Cancel, action: {})
        ])
        
        wrapperController?.present(controller, in: .window(.root), with: nil)
    }
    
    
    /// The real screen. Only rendered once `isUnlocked` is true, so Backup / Restore / Delete are
    /// unreachable — and no session is decoded — before device-owner authentication (audit #43).
    private var unlockedContent: some View {
        List {
            Section() {
                Button(action: performBackup) {
                    HStack {
                        Image(systemName: "key.fill")
                            .frame(width: 30)
                        Text("SessionBackup.Actions.Backup".i18n(lang))
                        Spacer()
                    }
                }
                
                Button(action: performRestore) {
                    HStack {
                        Image(systemName: "arrow.2.circlepath")
                            .frame(width: 30)
                        Text("SessionBackup.Actions.Restore".i18n(lang))
                        Spacer()
                    }
                }
                
                Button(action: performDeleteAll) {
                    HStack {
                        Image(systemName: "trash")
                            .frame(width: 30)
                        Text("SessionBackup.Actions.DeleteAll".i18n(lang))
                    }
                }
                .foregroundColor(.red)
                
            }
            
            Text("SessionBackup.Notice".i18n(lang))
                .font(.caption)
                .foregroundColor(.secondary)
            
            // A Keychain read error must not look like "you have no backups" (audit #43).
            if let loadErrorText = loadErrorText {
                Text(loadErrorText)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            Section(header: Text("SessionBackup.Sessions.Title".i18n(lang))) {
                ForEach(sessions, id: \.peerIdInternal) { session in
                    SessionBackupRow(
                        backup: session,
                        isLoggedIn: loggedInPeerIDs.contains(session.peerIdInternal)
                    )
                    .contextMenu {
                        Button(action: {
                            performDelete(session)
                        }, label: {
                            HStack(spacing: 4) {
                                Text("SessionBackup.Actions.DeleteOne".i18n(lang))
                                Image(systemName: "trash")
                            }
                        })
                        Button(action: {
                            performRemoveSessionFromApp(session: session)
                        }, label: {
                        
                            HStack(spacing: 4) {
                                Text("SessionBackup.Actions.RemoveFromApp".i18n(lang))
                                Image(systemName: "trash")
                            }
                        })
                    }
                }
//                .onDelete { indexSet in
//                    performDelete(indexSet)
//                }
            }
        }
    }
    
    /// Shown until device-owner authentication succeeds; nothing is read from the Keychain behind it.
    private var lockedPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            
            Text("SessionBackup.Locked.Title".i18n(lang))
                .font(.headline)
                .multilineTextAlignment(.center)
            
            Text("SessionBackup.Locked.Text".i18n(lang))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button(action: {
                authenticate()
            }) {
                Text("SessionBackup.Locked.Action".i18n(lang))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(BorderedButtonStyle())
            .disabled(isAuthenticating)
            .padding(.top, 8)
            
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    var body: some View {
        Group {
            if isUnlocked {
                unlockedContent
            } else {
                lockedPlaceholder
            }
        }
        .onAppear {
            // One automatic prompt per visit; a cancel leaves the explicit [Unlock] button.
            if !didRequestInitialUnlock {
                didRequestInitialUnlock = true
                authenticate()
            }
            installBackgroundLock()
            
            let accountsSignal = context.sharedContext.accountManager.accountRecords()
            |> deliverOnMainQueue
            
            loggedInAccountsDisposable = accountsSignal.start(next: { view in
                var result: [Int64] = []
                for record in view.records {
                    var isLoggedOut: Bool = false
                    var userId: Int64 = 0
                    for attribute in record.attributes {
                        if case .loggedOut = attribute  {
                            isLoggedOut = true
                        } else if case let .backupData(backupData) = attribute {
                            userId = backupData.data?.peerId ?? 0
                        }
                    }
                    
                    if !isLoggedOut && userId != 0 {
                        result.append(userId)
                    }
                }
  
                SGLogger.shared.log("SessionBackup", "Logged in accounts: \(result)")
                if loggedInPeerIDs != result {
                    SGLogger.shared.log("SessionBackup", "Updating logged in accounts: \(result)")
                    loggedInPeerIDs = result
                }
            })

        }
        .onDisappear {
            loggedInAccountsDisposable?.dispose()
            if let backgroundObserver = backgroundObserver {
                NotificationCenter.default.removeObserver(backgroundObserver)
            }
            backgroundObserver = nil
            // Leaving the screen re-arms the automatic prompt for the next visit.
            didRequestInitialUnlock = false
        }
    }
    
    // MARK: - Zenlygram: device-owner gate (audit #43)
    
    /// Re-locks whenever the app leaves the foreground and drops the decoded sessions from memory.
    private func installBackgroundLock() {
        if backgroundObserver != nil {
            return
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            isUnlocked = false
            isAuthenticating = false
            didRequestInitialUnlock = false
            sessions = []
            loadErrorText = nil
        }
    }
    
    /// Biometrics or the iPhone passcode, on a fresh `LAContext` with the reuse window disabled, so
    /// every unlock is a real prompt rather than a ride on an earlier one.
    private func authenticateDeviceOwner(reasonKey: String, completion: @escaping (Bool) -> Void) {
        let laContext = LAContext()
        laContext.touchIDAuthenticationAllowableReuseDuration = 0
        
        var laError: NSError?
        guard laContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &laError) else {
            // Neither biometrics nor a device passcode: there is no device owner to prove, so the
            // gate fails closed. `SessionBackup.Locked.Text` tells the user to set a passcode.
            SGLogger.shared.log("SessionBackup", "Device owner auth unavailable: \(String(describing: laError))")
            completion(false)
            return
        }
        
        laContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reasonKey.i18n(lang)) { success, _ in
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }
    
    private func authenticate() {
        if isUnlocked || isAuthenticating {
            return
        }
        isAuthenticating = true
        authenticateDeviceOwner(reasonKey: "SessionBackup.AuthReason") { success in
            isAuthenticating = false
            if success {
                unlock()
            }
        }
    }
    
    private func unlock() {
        isUnlocked = true
        // Heal sessions written by an older build while we are here (audit #72): they may still be
        // `WhenUnlocked`, which travels with an encrypted backup. Protected data is available in
        // practice — the user just cleared the device-owner gate — but the real value is passed rather
        // than a literal so the "never set the done-flag on a locked-device read" invariant holds here too.
        KeychainBackupManager.shared.upgradeAccessibilityIfNeeded(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
        let loaded = reloadSessions()
        
        // The Keychain outlives the app container, so backups written before a delete+reinstall
        // reappear here. Say so once instead of letting them look like this installation's own.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: sessionBackupInstallMarkerKey) == nil {
            defaults.set(true, forKey: sessionBackupInstallMarkerKey)
            if !loaded.isEmpty {
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let controller = textAlertController(context: context, title: nil, text: "SessionBackup.PreviousInstall.Notice".i18n(lang), actions: [
                    TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
                ])
                wrapperController?.present(controller, in: .window(.root), with: nil)
            }
        }
    }
    
    /// Single place that touches the Keychain for the list. A read failure surfaces as an error
    /// instead of silently looking like an empty backup.
    @discardableResult
    private func reloadSessions() -> [SessionBackup] {
        do {
            let loaded = try loadBackedSessions()
            withAnimation {
                sessions = loaded
                loadErrorText = nil
            }
            return loaded
        } catch let e {
            SGLogger.shared.log("SessionBackup", "Error getting all sessions: \(e)")
            withAnimation {
                sessions = []
                loadErrorText = "SessionBackup.ReadError".i18n(lang)
            }
            return []
        }
    }
    
}


/// Zenlygram — audit #43: throws on a Keychain failure so the caller can tell "cannot read" apart
/// from "nothing stored" (the old version swallowed the error and returned an empty list).
/// An individual record that fails to decode is still skipped rather than failing the whole read.
func loadBackedSessions() throws -> [SessionBackup] {
    var sessions: [SessionBackup] = []
    let backupSessionsData = try KeychainBackupManager.shared.getAllSessons()
    for sessionBackupData in backupSessionsData {
        do {
            let backup = try JSONDecoder().decode(SessionBackup.self, from: sessionBackupData)
            sessions.append(backup)
        } catch let e {
            SGLogger.shared.log("SessionBackup", "IMPORT ERROR: \(e)")
        }
    }
    return sessions
}


func backupSessionsFromView(_ view: AccountRecordsView<TelegramAccountManagerTypes>, accountsWithInfo: [AccountWithInfo] = []) {
    var recordsToBackup: [Int64: AccountRecord<TelegramAccountManagerTypes.Attribute>] = [:]
    for record in view.records {
        var sortOrder: Int32 = 0
        var isLoggedOut: Bool = false
        var isTestingEnvironment: Bool = false
        var peerId: Int64 = 0
        for attribute in record.attributes {
            if case let .sortOrder(value) = attribute {
                sortOrder = value.order
            } else if case .loggedOut = attribute  {
                isLoggedOut = true
            } else if case let .environment(environment) = attribute, case .test = environment.environment {
                isTestingEnvironment = true
            } else if case let .backupData(backupData) = attribute {
                peerId = backupData.data?.peerId ?? 0
            }
        }
        let _ = sortOrder
        let _ = isTestingEnvironment
        
        if !isLoggedOut && peerId != 0 {
            recordsToBackup[peerId] = record
        }
    }
    
    for (peerId, record) in recordsToBackup {
        var backupName: String? = nil
        if let accountWithInfo = accountsWithInfo.first(where: { $0.peer.id == PeerId(peerId) }) {
            if let username = accountWithInfo.peer.addressName {
                backupName = "@\(username)"
            } else {
                backupName = accountWithInfo.peer.debugDisplayTitle
            }
        }
        let backup = SessionBackup(name: backupName, accountRecord: record)
        do {
            let data = try JSONEncoder().encode(backup)
            try KeychainBackupManager.shared.saveSession(id: "\(backup.peerIdInternal)", data)
        } catch let e {
            SGLogger.shared.log("SessionBackup", "BACKUP ERROR: \(e)")
        }
    }
}


@available(iOS 13.0, *)
public func sgSessionBackupManagerController(context: AccountContext, presentationData: PresentationData? = nil) -> ViewController {
    let theme = presentationData?.theme ?? (UITraitCollection.current.userInterfaceStyle == .dark ? defaultDarkColorPresentationTheme : defaultPresentationTheme)
    let strings = presentationData?.strings ?? defaultPresentationStrings

    let legacyController = LegacySwiftUIController(
        presentation: .navigation,
        theme: theme,
        strings: strings
    )
    legacyController.statusBar.statusBarStyle = theme.rootController
        .statusBarStyle.style
    legacyController.title = "SessionBackup.Title".i18n(strings.baseLanguageCode)

    let swiftUIView = SGSwiftUIView<SessionBackupManagerView>(
        legacyController: legacyController,
        manageSafeArea: true,
        content: {
            SessionBackupManagerView(wrapperController: legacyController, context: context)
        }
    )
    let controller = UIHostingController(rootView: swiftUIView, ignoreSafeArea: true)
    legacyController.bind(controller: controller)

    return legacyController
}
