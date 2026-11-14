import Foundation

enum SGFeatureStorageCleanupTests {
    static func run() async {
        self.accountNames()
        await self.onToOffKeepsOnlyDeviceLock()
        await self.removeAccountRemovesBothKeyFormsOnly()
        await self.removeAccountsNotInSignedIn()
        await self.deviceLockSurvivesSwitchAndRemoval()
        await self.hookRunsBeforeKeychainDelete()
        await self.hookRunsForStaleAndRemainingAccounts()
        await self.unreadableKeychainDeletesNothing()
    }

    /// The per-account fixture: two accounts (both key forms for 111), device items, folders and defaults.
    private static func makeStorage() -> TestStorage {
        let storage = TestStorage()
        storage.addKeychain(["111", "111@api.example.org", "222@api.example.org", "1110", "d.u13", "d.pin", "install"])
        storage.addKeychain(["111"], service: "other.service")
        storage.addFolder("sgf1/111")
        storage.addFolder("sgf1/111@api.example.org")
        storage.addFolder("sgf1/222")
        storage.addFolder("sgf1/shared")
        storage.addFolder("sgf1-cache/111", root: 1)
        storage.addFolder("sgf1-cache/222", root: 1)
        storage.addFolder("unrelated/111")
        storage.addDefaults(["sgf1.storefront", "sgf1.tab.111", "sgf1.tab.222", "sgf1.seen.1110", "other.111"])
        return storage
    }

    private static func accountNames() {
        check(SGFeatureStorageCleanup.accountPeerId(fromName: "111") == 111, "bare decimal is the account")
        check(SGFeatureStorageCleanup.accountPeerId(fromName: "111@api.example.org") == 111, "origin-scoped key is the account")
        check(SGFeatureStorageCleanup.accountPeerId(fromName: "d.u13") == nil, "device lock is device-level")
        check(SGFeatureStorageCleanup.accountPeerId(fromName: "@host") == nil, "empty id is device-level")
        check(SGFeatureStorageCleanup.accountPeerId(fromName: "12a") == nil, "non-decimal is device-level")
        check(SGFeatureStorageCleanup.accountPeerId(fromName: "-5") == nil, "signed number is device-level")
        check(SGFeatureStorageCleanup.accountPeerId(fromName: "") == nil, "empty name is device-level")
    }

    /// A launch without the feature (on → off): only the device lock remains of the service.
    private static func onToOffKeepsOnlyDeviceLock() async {
        let storage = self.makeStorage()
        await SGFeatureStorageCleanup(storage: storage).removeEverything().value
        check(storage.keychain() == ["d.u13"], "removeEverything keeps only d.u13, got \(storage.keychain())")
        check(storage.keychain(service: "other.service") == ["111"], "other services are untouched")
        check(!storage.exists("sgf1") && !storage.exists("sgf1-cache", root: 1), "every sgf1 entry is removed")
        check(storage.exists("unrelated/111"), "non-prefixed folders stay")
        check(storage.defaultsKeySet == ["other.111"], "every sgf1 default goes, got \(storage.defaultsKeySet)")
    }

    private static func removeAccountRemovesBothKeyFormsOnly() async {
        let storage = self.makeStorage()
        await SGFeatureStorageCleanup(storage: storage).removeAccount(111, beforeRemoval: nil).value
        check(storage.keychain() == ["222@api.example.org", "1110", "d.u13", "d.pin", "install"], "only 111 and 111@host go, got \(storage.keychain())")
        check(!storage.exists("sgf1/111") && !storage.exists("sgf1/111@api.example.org") && !storage.exists("sgf1-cache/111", root: 1), "the account's folders go")
        check(storage.exists("sgf1/222") && storage.exists("sgf1/shared") && storage.exists("sgf1-cache/222", root: 1), "other accounts' and device folders stay")
        check(storage.exists("unrelated/111"), "non-prefixed folders stay")
        check(storage.defaultsKeySet == ["sgf1.storefront", "sgf1.tab.222", "sgf1.seen.1110", "other.111"], "only the account's defaults go, got \(storage.defaultsKeySet)")
    }

    private static func removeAccountsNotInSignedIn() async {
        let storage = self.makeStorage()
        await SGFeatureStorageCleanup(storage: storage).removeAccounts(notIn: [222], beforeRemoval: nil).value
        check(storage.keychain() == ["222@api.example.org", "d.u13", "d.pin", "install"], "signed-out accounts go, got \(storage.keychain())")
        check(!storage.exists("sgf1/111") && !storage.exists("sgf1/111@api.example.org") && !storage.exists("sgf1-cache/111", root: 1), "signed-out folders go")
        check(storage.exists("sgf1/222") && storage.exists("sgf1/shared") && storage.exists("sgf1-cache/222", root: 1), "signed-in and device folders stay")
        check(storage.defaultsKeySet == ["sgf1.storefront", "sgf1.tab.222", "other.111"], "signed-out defaults go, got \(storage.defaultsKeySet)")
    }

    /// QUL-07: the under-13 lock outlives switching accounts, removing them and the last sign-out.
    private static func deviceLockSurvivesSwitchAndRemoval() async {
        let storage = self.makeStorage()
        let cleanup = SGFeatureStorageCleanup(storage: storage)
        cleanup.removeAccount(111, beforeRemoval: nil)
        cleanup.removeAccounts(notIn: [333], beforeRemoval: nil)
        await cleanup.removeAllAccounts(beforeRemoval: nil).value
        check(storage.keychain() == ["d.u13", "d.pin", "install"], "device items survive every account removal, got \(storage.keychain())")
        check(!storage.exists("sgf1") && !storage.exists("sgf1-cache", root: 1), "the last sign-out removes every sgf1 entry")
        check(storage.defaultsKeySet == ["sgf1.storefront", "other.111"], "device defaults stay on the last sign-out, got \(storage.defaultsKeySet)")
        await cleanup.removeEverything().value
        check(storage.keychain() == ["d.u13"], "the lock survives a later launch without the feature")
    }

    /// The hook (server logout) still finds the account's session; deletion follows it.
    private static func hookRunsBeforeKeychainDelete() async {
        let storage = self.makeStorage()
        let recorder = HookRecorder()
        let cleanup = SGFeatureStorageCleanup(storage: storage)
        cleanup.removeAccount(111, beforeRemoval: { accountPeerId in
            await recorder.record(accountPeerId, keychain: storage.keychain())
        })
        await cleanup.removeAllAccounts(beforeRemoval: nil).value
        let calls = await recorder.calls
        let atCall = await recorder.keychainAtCall[111] ?? []
        check(calls == [111], "hook called once for the removed account, got \(calls)")
        check(atCall.contains("111") && atCall.contains("111@api.example.org"), "the session is still stored when the hook runs")
        check(storage.keychain() == ["d.u13", "d.pin", "install"], "a later wipe runs only after the hook finished")
    }

    private static func hookRunsForStaleAndRemainingAccounts() async {
        let storage = self.makeStorage()
        let recorder = HookRecorder()
        let hook: SGFeatureStorageCleanup.BeforeRemoval = { accountPeerId in
            await recorder.record(accountPeerId, keychain: storage.keychain())
        }
        let cleanup = SGFeatureStorageCleanup(storage: storage)
        await cleanup.removeAccounts(notIn: [222], beforeRemoval: hook).value
        let launchCalls = await recorder.calls
        check(launchCalls == [111, 1110], "launch reconciliation logs out each signed-out account once, got \(launchCalls)")
        await cleanup.removeAllAccounts(beforeRemoval: hook).value
        let allCalls = await recorder.calls
        check(allCalls == [111, 1110, 222], "the last sign-out logs out the remaining account, got \(allCalls)")
        let atCall = await recorder.keychainAtCall[222] ?? []
        check(atCall.contains("222@api.example.org"), "its session is still stored at the hook")
        await cleanup.removeEverything().value
        let finalCalls = await recorder.calls
        check(finalCalls.count == 3, "removeEverything never calls the hook")
    }

    private static func unreadableKeychainDeletesNothing() async {
        let storage = self.makeStorage()
        storage.keychainReadable = false
        let recorder = HookRecorder()
        await SGFeatureStorageCleanup(storage: storage).removeAccounts(notIn: [], beforeRemoval: { accountPeerId in
            await recorder.record(accountPeerId, keychain: [])
        }).value
        storage.keychainReadable = true
        check(storage.keychain().count == 7, "a locked Keychain is left for the next launch")
        let calls = await recorder.calls
        check(calls.isEmpty, "no hook without a readable Keychain")
    }
}
