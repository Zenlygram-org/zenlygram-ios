import CryptoKit
import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the profile snapshot (design 40 §9, contract §2.4.3): every normalisation, the
/// canonical body and its digest without `observed_at`, the shared `profile-sync-valid.json` bodies
/// (as parsed JSON), and the sync cadence.
final class SGProfileSnapshotTests: XCTestCase {
    private let tg: Int64 = 555_000_111
    /// 2026-11-01T10:00:00Z.
    private let received = Date(timeIntervalSince1970: 1_793_527_200)

    func testE164() {
        XCTAssertEqual(SGProfileSnapshot.e164("998901234567"), "+998901234567", "Telegram's phone has no +")
        XCTAssertEqual(SGProfileSnapshot.e164("+998 (90) 123-45-67"), "+998901234567", "digits only")
        XCTAssertEqual(SGProfileSnapshot.e164("1234567"), "+1234567")
        XCTAssertEqual(SGProfileSnapshot.e164("123456789012345"), "+123456789012345")
        XCTAssertNil(SGProfileSnapshot.e164("1234567890123456"), "16 digits")
        XCTAssertNil(SGProfileSnapshot.e164("123456"), "6 digits")
        XCTAssertNil(SGProfileSnapshot.e164("0998901234"), "no leading 0")
        XCTAssertNil(SGProfileSnapshot.e164(""), "hidden")
        XCTAssertNil(SGProfileSnapshot.e164(nil))
        XCTAssertNil(SGProfileSnapshot.e164("٩٩٨٩٠١٢٣٤٥٦٧"), "only ASCII digits count")
    }

    func testUsernames() {
        typealias Name = SGProfileUser.Username
        let list = [
            Name(value: "collectible1", isActive: true, isEditable: false),
            Name(value: "primary_name", isActive: true, isEditable: true),
            Name(value: "Primary_Name", isActive: true, isEditable: false),
            Name(value: "inactive_one", isActive: false, isEditable: false),
            Name(value: "abc", isActive: true, isEditable: false),
            Name(value: "with-dash", isActive: true, isEditable: false),
            Name(value: String(repeating: "x", count: 33), isActive: true, isEditable: false),
        ]
        XCTAssertEqual(SGProfileSnapshot.usernames(list, fallback: "ignored_name"), ["primary_name", "collectible1"], "active, editable first, de-duplicated case-insensitively, pattern-checked")
        XCTAssertEqual(SGProfileSnapshot.usernames([], fallback: "single_name"), ["single_name"], "the single username when the list is empty")
        XCTAssertEqual(SGProfileSnapshot.usernames([], fallback: "no"), [])
        XCTAssertEqual(SGProfileSnapshot.usernames([], fallback: nil), [])
        XCTAssertEqual(SGProfileSnapshot.usernames([Name(value: "inactive_one", isActive: false, isEditable: true)], fallback: "single_name"), [], "a list of inactive names is not empty")
        let many = (0 ..< 40).map { Name(value: "name_\($0)", isActive: true, isEditable: false) }
        XCTAssertEqual(SGProfileSnapshot.usernames(many, fallback: nil), (0 ..< 32).map { "name_\($0)" }, "at most 32")
    }

    func testNames() {
        XCTAssertEqual(SGProfileSnapshot.nameText("  Ali  "), "Ali")
        XCTAssertEqual(SGProfileSnapshot.nameText("\u{00A0}Ali\u{2003}"), "Ali", "Unicode White_Space trimmed")
        XCTAssertNil(SGProfileSnapshot.nameText(""), "empty → null")
        XCTAssertNil(SGProfileSnapshot.nameText(" \t "), "blank → null")
        XCTAssertNil(SGProfileSnapshot.nameText(nil))
        XCTAssertEqual(SGProfileSnapshot.nameText("A\u{0}l\u{7}i\u{85}\u{9F}\u{2028}\u{2029}"), "Ali", "C0/C1 controls and line separators removed")
        XCTAssertEqual(SGProfileSnapshot.nameText("Ali\nValiyev"), "AliValiyev")
        XCTAssertEqual(SGProfileSnapshot.nameText("Valie\u{0301}v"), "Valiév", "NFC")
        XCTAssertEqual(SGProfileSnapshot.nameText("Алишер Ўзбек"), "Алишер Ўзбек")
        XCTAssertEqual(SGProfileSnapshot.nameText("👩‍💻 Dev"), "👩‍💻 Dev")
        let long = String(repeating: "Ş", count: 200)
        XCTAssertEqual(SGProfileSnapshot.nameText(long)?.unicodeScalars.count, 128, "clipped to 128 scalars")
        let decomposed = String(repeating: "e\u{0301}", count: 100)
        XCTAssertEqual(SGProfileSnapshot.nameText(decomposed), String(repeating: "é", count: 100), "composed before clipping")
        XCTAssertEqual(SGProfileSnapshot.nameText("Valie\u{0007}\u{0301}v").map { Array($0.unicodeScalars) }, Array("Vali\u{00E9}v".unicodeScalars), "a removed control between a letter and its mark: composed again")
        // Compared scalar by scalar: String's == is canonical equivalence, so it cannot tell NFC from NFD.
        for text in [long, decomposed, "Ali \u{0007}", String(repeating: "\u{0958}", count: 130), "e\u{0007}\u{0301}", "Ali\u{2028}\u{0301}", "\u{1100}\u{0085}\u{1161}"] {
            if let name = SGProfileSnapshot.nameText(text) {
                XCTAssertLessThanOrEqual(name.unicodeScalars.count, 128)
                XCTAssertEqual(Array(name.unicodeScalars), Array(name.precomposedStringWithCanonicalMapping.unicodeScalars), "stays NFC")
            }
        }
    }

    func testDeviceValues() {
        XCTAssertEqual(SGCustomerNormalise.uiLanguage("pt-br"), "pt")
        XCTAssertEqual(SGCustomerNormalise.uiLanguage("uz-raw"), "uz")
        XCTAssertEqual(SGCustomerNormalise.uiLanguage("zh-hans"), "zh")
        XCTAssertEqual(SGCustomerNormalise.uiLanguage("zh-hans-raw"), "zh")
        XCTAssertEqual(SGCustomerNormalise.uiLanguage("EN"), "en")
        XCTAssertEqual(SGCustomerNormalise.uiLanguage("pt_BR"), "pt")
        XCTAssertEqual(SGCustomerNormalise.uiLanguage("fil"), "fil")
        XCTAssertNil(SGCustomerNormalise.uiLanguage("english"))
        XCTAssertNil(SGCustomerNormalise.uiLanguage("u"))
        XCTAssertNil(SGCustomerNormalise.uiLanguage(""))
        XCTAssertNil(SGCustomerNormalise.uiLanguage(nil))

        XCTAssertEqual(SGCustomerNormalise.bcp47(identifier: "uz_UZ"), "uz-UZ")
        XCTAssertEqual(SGCustomerNormalise.bcp47(identifier: "uz-Latn-UZ"), "uz-Latn-UZ")
        XCTAssertEqual(SGCustomerNormalise.bcp47(identifier: "uz_latn_uz"), "uz-Latn-UZ")
        XCTAssertEqual(SGCustomerNormalise.bcp47(identifier: "en_US@calendar=gregorian"), "en-US")
        XCTAssertEqual(SGCustomerNormalise.bcp47(identifier: "en_US_POSIX"), "en-US")
        XCTAssertEqual(SGCustomerNormalise.bcp47(identifier: "de-DE-u-co-phonebk"), "de-DE")
        XCTAssertEqual(SGCustomerNormalise.bcp47(identifier: "es_419"), "es-419")
        XCTAssertEqual(SGCustomerNormalise.bcp47(identifier: "zh-Hans"), "zh-Hans")
        XCTAssertEqual(SGCustomerNormalise.bcp47(identifier: "ru"), "ru")
        XCTAssertNil(SGCustomerNormalise.bcp47(identifier: "x"))
        XCTAssertNil(SGCustomerNormalise.bcp47(identifier: "english_US"))
        XCTAssertNil(SGCustomerNormalise.bcp47(identifier: ""))
        XCTAssertEqual(SGCustomerNormalise.bcp47(language: "uz", script: "Latn", region: "UZ"), "uz-Latn-UZ")
        XCTAssertEqual(SGCustomerNormalise.bcp47(language: "UZ", script: nil, region: "uz"), "uz-UZ")
        XCTAssertEqual(SGCustomerNormalise.bcp47(language: "uz", script: "Lat", region: "UZ"), "uz-UZ", "an invalid script is left out")
        XCTAssertEqual(SGCustomerNormalise.bcp47(language: "es", script: nil, region: "419"), "es-419")
        XCTAssertNil(SGCustomerNormalise.bcp47(language: nil, script: "Latn", region: "UZ"))
        for tag in ["uz-UZ", "uz-Latn-UZ", "es-419", "ru"] {
            XCTAssertTrue(SGCustomerNormalise.isBCP47(tag), tag)
        }
        XCTAssertFalse(SGCustomerNormalise.isBCP47("en-us"))

        XCTAssertEqual(SGCustomerNormalise.timezone("Asia/Tashkent"), "Asia/Tashkent")
        XCTAssertEqual(SGCustomerNormalise.timezone("Etc/GMT+5"), "Etc/GMT+5")
        XCTAssertEqual(SGCustomerNormalise.timezone("America/Argentina/Buenos_Aires"), "America/Argentina/Buenos_Aires")
        XCTAssertNil(SGCustomerNormalise.timezone("Mars/Olympus Mons"))
        XCTAssertNil(SGCustomerNormalise.timezone("/Asia"))
        XCTAssertNil(SGCustomerNormalise.timezone(String(repeating: "A", count: 65)))
        XCTAssertNil(SGCustomerNormalise.timezone(nil))

        XCTAssertEqual(SGCustomerNormalise.model("iPhone17,1"), "iPhone17,1")
        XCTAssertEqual(SGCustomerNormalise.model(" iPad\t16,3 "), "iPad 16,3")
        XCTAssertEqual(SGCustomerNormalise.model("Google  Pixel\u{00A0}8"), "Google Pixel 8")
        XCTAssertEqual(SGCustomerNormalise.model("Pixel\tTablet"), "Pixel Tablet")
        XCTAssertEqual(SGCustomerNormalise.model("Ünïcode"), "ncode")
        XCTAssertEqual(SGCustomerNormalise.model(String(repeating: "M", count: 70))?.count, 64)
        XCTAssertNil(SGCustomerNormalise.model("   "))
        XCTAssertNil(SGCustomerNormalise.model(nil))

        XCTAssertEqual(SGCustomerNormalise.version("12.0.1"), "12.0.1")
        XCTAssertEqual(SGCustomerNormalise.version("12.0.1β"), "12.0.1")
        XCTAssertEqual(SGCustomerNormalise.version("12.0.1 (build 2026-11-01 nightly 7)"), "12.0.1 (build 2026-11-01 nightly")
        XCTAssertEqual(SGCustomerNormalise.version("ß"), "0")
        XCTAssertEqual(SGCustomerNormalise.optionalVersion("1234"), "1234")
        XCTAssertNil(SGCustomerNormalise.optionalVersion("   "))
        XCTAssertNil(SGCustomerNormalise.optionalVersion("—"))
        XCTAssertNil(SGCustomerNormalise.optionalVersion(nil))
    }

    func testTheSharedBodiesEqualTheBuilderOutput() throws {
        let fixture = try SGCustomerSyncTestFixtures.jsonObject("profile-sync-valid.json")
        XCTAssertEqual(SGCustomerJSON.integer(fixture["tg_user_id"]), Int(self.tg))
        let cases = try SGCustomerSyncTestFixtures.cases("profile-sync-valid.json").filter { $0["binding_platform"] as? String == "ios" && $0["client_built"] as? Bool == true }
        XCTAssertGreaterThanOrEqual(cases.count, 2, "an iPhone and an iPad body")
        var seen = Set<String>()
        for item in cases {
            let id = try XCTUnwrap(item["id"] as? String)
            let body = try XCTUnwrap(item["body"] as? [String: Any])
            let observedAt = try XCTUnwrap((body["observed_at"] as? String).flatMap(SGCustomerTime.date(fromInstant:)))
            let input = try self.rawInput(for: body)
            let snapshot = try XCTUnwrap(SGProfileSnapshot(user: input.user, device: input.device), id)
            let built = snapshot.body(observedAt: observedAt)
            SGCustomerSyncTestFixtures.assertJSON(built, equals: body, id)
            XCTAssertLessThanOrEqual(built.count, SGProfileSnapshot.maxBodyBytes)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: built, options: []) as? [String: Any])
            XCTAssertTrue(SGConsentEvent.isVersionText(try XCTUnwrap(object["app_version"] as? String)), "ProfileBoundary's ver")
            XCTAssertTrue(SGConsentEvent.isVersionText(try XCTUnwrap(object["os_version"] as? String)))
            seen.insert((body["device"] as? [String: Any])?["device_class"] as? String ?? "")
            for key in ["phone", "first_name", "last_name"] where (body["telegram"] as? [String: Any])?[key] is NSNull {
                seen.insert("null \(key)")
            }
        }
        XCTAssertTrue(seen.isSuperset(of: ["phone", "tablet", "null phone", "null first_name", "null last_name"]), "the iOS bodies cover both device classes and the null names and phone: \(seen)")
    }

    func testTheBodyWritesNullForEveryUnknownValue() throws {
        let user = SGProfileUser(userId: self.tg, phone: nil, usernames: [], username: nil, firstName: nil, lastName: " ", isPremium: false)
        let device = SGCustomerDeviceFacts(deviceClass: .phone, deviceModel: nil, osVersion: "18.1", appVersion: "12.0.1", appBuild: nil, uiLanguage: nil, locale: nil, timezone: nil, distribution: .debug)
        let snapshot = try XCTUnwrap(SGProfileSnapshot(user: user, device: device))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: snapshot.body(observedAt: self.received), options: []) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema_version", "observed_at", "app_version", "os_version", "telegram", "device"])
        let telegram = try XCTUnwrap(object["telegram"] as? [String: Any])
        XCTAssertEqual(Set(telegram.keys), ["user_id", "phone", "usernames", "first_name", "last_name", "is_premium"])
        for key in ["phone", "first_name", "last_name"] {
            XCTAssertTrue(telegram[key] is NSNull, key)
        }
        let deviceObject = try XCTUnwrap(object["device"] as? [String: Any])
        XCTAssertEqual(Set(deviceObject.keys), ["platform", "device_class", "device_model", "app_build", "ui_language", "locale", "timezone", "distribution"])
        for key in ["device_model", "app_build", "ui_language", "locale", "timezone"] {
            XCTAssertTrue(deviceObject[key] is NSNull, key)
        }
        XCTAssertEqual(deviceObject["platform"] as? String, "ios")
        XCTAssertEqual(object["observed_at"] as? String, "2026-11-01T10:00:00Z")
        XCTAssertFalse(String(decoding: snapshot.body(observedAt: self.received), as: UTF8.self).contains("\\/"), "slashes are not escaped")
    }

    func testTheDigestLeavesOutObservedAtAndDoesNotDependOnKeyOrder() throws {
        let input = self.phoneInput
        let snapshot = try XCTUnwrap(SGProfileSnapshot(user: input.user, device: input.device))
        let early = snapshot.body(observedAt: self.received)
        let late = snapshot.body(observedAt: self.received.addingTimeInterval(3600))
        XCTAssertNotEqual(early, late)
        XCTAssertEqual(snapshot.digest.count, 64)
        XCTAssertTrue(SGCustomerTime.isHex64(snapshot.digest))

        // The digest is the SHA-256 of the canonical body without observed_at, whichever order the keys come in.
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: late, options: []) as? [String: Any])
        object["observed_at"] = nil
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertEqual(SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined(), snapshot.digest)

        // The same account read in another raw order (the editable username first, no duplicate, other padding).
        let reordered = SGProfileUser(userId: input.user.userId, phone: "+998 90 123 45 67", usernames: [
            SGProfileUser.Username(value: "primary_name", isActive: true, isEditable: true),
            SGProfileUser.Username(value: "collectible1", isActive: true, isEditable: false),
        ], username: nil, firstName: "Ali", lastName: nil, isPremium: input.user.isPremium)
        XCTAssertEqual(try XCTUnwrap(SGProfileSnapshot(user: reordered, device: input.device)).digest, snapshot.digest)
        var changed = input.user
        changed.isPremium = true
        XCTAssertNotEqual(try XCTUnwrap(SGProfileSnapshot(user: changed, device: input.device)).digest, snapshot.digest, "any field change is a new digest")
        var moved = input.device
        moved.timezone = "Asia/Samarkand"
        XCTAssertNotEqual(try XCTUnwrap(SGProfileSnapshot(user: input.user, device: moved)).digest, snapshot.digest)
    }

    func testAUserIdOutsideTgIdHasNoSnapshot() throws {
        let input = self.phoneInput
        for userId: Int64 in [0, -1, 9_007_199_254_740_992] {
            var user = input.user
            user.userId = userId
            XCTAssertNil(SGProfileSnapshot(user: user, device: input.device), "\(userId)")
        }
        var user = input.user
        user.userId = 9_007_199_254_740_991
        XCTAssertNotNil(SGProfileSnapshot(user: user, device: input.device))
    }

    func testTheLargestBodyFitsTheRouteLimit() throws {
        let names = (0 ..< 40).map { SGProfileUser.Username(value: "u\($0)_" + String(repeating: "z", count: 28), isActive: true, isEditable: $0 == 0) }
        let user = SGProfileUser(userId: self.tg, phone: "123456789012345", usernames: names, username: nil, firstName: String(repeating: "𝔄", count: 300), lastName: String(repeating: "𝔅", count: 300), isPremium: true)
        let device = SGCustomerDeviceFacts(deviceClass: .tablet, deviceModel: String(repeating: "M", count: 100), osVersion: String(repeating: "9", count: 50), appVersion: String(repeating: "1", count: 50), appBuild: String(repeating: "2", count: 50), uiLanguage: "fil", locale: "uz-Latn-UZ", timezone: "America/Argentina/Buenos_Aires", distribution: .testflight)
        let snapshot = try XCTUnwrap(SGProfileSnapshot(user: user, device: device))
        XCTAssertEqual(snapshot.telegram.usernames.count, 32)
        XCTAssertLessThanOrEqual(snapshot.body(observedAt: self.received).count, SGProfileSnapshot.maxBodyBytes)
    }

    func testTheCadence() {
        let digest = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        let now = self.received
        XCTAssertEqual(SGProfileSyncCadence.dueAt(digest: digest, receipt: nil, digestChangedAt: nil, lastAttemptAt: now, minIntervalS: nil, isForeground: false, now: now), now, "(a) no receipt for this binding: now")
        let fresh = SGProfileSyncReceipt(digest: digest, at: now.addingTimeInterval(-60))
        XCTAssertEqual(SGProfileSyncCadence.dueAt(digest: digest, receipt: fresh, digestChangedAt: nil, lastAttemptAt: nil, minIntervalS: nil, isForeground: true, now: now), fresh.at.addingTimeInterval(6 * 3600), "(c) 6 h after the receipt")
        XCTAssertEqual(SGProfileSyncCadence.dueAt(digest: digest, receipt: fresh, digestChangedAt: nil, lastAttemptAt: nil, minIntervalS: 43_200, isForeground: true, now: now), fresh.at.addingTimeInterval(43_200), "(c) or min_interval_s when longer")
        XCTAssertEqual(SGProfileSyncCadence.dueAt(digest: digest, receipt: fresh, digestChangedAt: nil, lastAttemptAt: nil, minIntervalS: 60, isForeground: true, now: now), fresh.at.addingTimeInterval(6 * 3600), "(c) never sooner than 6 h")
        XCTAssertNil(SGProfileSyncCadence.dueAt(digest: digest, receipt: fresh, digestChangedAt: nil, lastAttemptAt: nil, minIntervalS: nil, isForeground: false, now: now), "(c) in the foreground only")
        let changedAt = now.addingTimeInterval(-3)
        XCTAssertEqual(SGProfileSyncCadence.dueAt(digest: other, receipt: fresh, digestChangedAt: changedAt, lastAttemptAt: now.addingTimeInterval(-3600), minIntervalS: nil, isForeground: false, now: now), changedAt.addingTimeInterval(10), "(b) debounced 10 s")
        XCTAssertEqual(SGProfileSyncCadence.dueAt(digest: other, receipt: fresh, digestChangedAt: changedAt, lastAttemptAt: now.addingTimeInterval(-60), minIntervalS: nil, isForeground: true, now: now), now.addingTimeInterval(240), "(b) ≥ 5 min after the last attempt")
        XCTAssertEqual(SGProfileSyncCadence.dueAt(digest: other, receipt: fresh, digestChangedAt: nil, lastAttemptAt: nil, minIntervalS: nil, isForeground: true, now: now), now.addingTimeInterval(10))
    }

    // MARK: - Raw inputs (as SGProfileReader and SGDeviceInfo read them)

    /// An iPhone account as Telegram and the device report it (the contract §2.4.3 example).
    private var phoneInput: (user: SGProfileUser, device: SGCustomerDeviceFacts) {
        return (
            SGProfileUser(
                userId: self.tg,
                phone: "998901234567",
                usernames: [
                    SGProfileUser.Username(value: "collectible1", isActive: true, isEditable: false),
                    SGProfileUser.Username(value: "old_name", isActive: false, isEditable: false),
                    SGProfileUser.Username(value: "primary_name", isActive: true, isEditable: true),
                    SGProfileUser.Username(value: "COLLECTIBLE1", isActive: true, isEditable: false),
                ],
                username: "primary_name",
                firstName: " Ali ",
                lastName: "",
                isPremium: false
            ),
            SGCustomerDeviceFacts(deviceClass: .phone, deviceModel: "iPhone17,1", osVersion: "18.1", appVersion: "12.0.1", appBuild: "1234", uiLanguage: "uz-raw", locale: "uz_UZ", timezone: "Asia/Tashkent", distribution: .appstore)
        )
    }

    /// What the app reads for a sync body, in raw form, so the builder must normalise it back: the
    /// phone without `+` (hidden: empty), the usernames out of order with an inactive one and a
    /// case-insensitive duplicate (the first one editable), names padded with white space (unknown:
    /// blank), `CFBundleShortVersionString` with a character outside `ver`, the app language with
    /// `-raw`, the locale as an identifier with `_` and a keyword.
    private func rawInput(for body: [String: Any]) throws -> (user: SGProfileUser, device: SGCustomerDeviceFacts) {
        let telegram = try XCTUnwrap(body["telegram"] as? [String: Any])
        let device = try XCTUnwrap(body["device"] as? [String: Any])
        let usernames = try XCTUnwrap(telegram["usernames"] as? [String])
        var raw: [SGProfileUser.Username] = usernames.dropFirst().map { SGProfileUser.Username(value: $0, isActive: true, isEditable: false) }
        if let first = usernames.first {
            raw.append(SGProfileUser.Username(value: "inactive_name", isActive: false, isEditable: false))
            raw.append(SGProfileUser.Username(value: first, isActive: true, isEditable: true))
            raw.append(SGProfileUser.Username(value: (usernames.last ?? first).uppercased(), isActive: true, isEditable: false))
        }
        func padded(_ value: Any?) -> String {
            return (value as? String).map { " \($0)\u{00A0}" } ?? " "
        }
        let user = SGProfileUser(
            userId: Int64(try XCTUnwrap(SGCustomerJSON.integer(telegram["user_id"]))),
            phone: (telegram["phone"] as? String).map { String($0.dropFirst()) } ?? "",
            usernames: raw,
            username: nil,
            firstName: padded(telegram["first_name"]),
            lastName: padded(telegram["last_name"]),
            isPremium: try XCTUnwrap(SGCustomerJSON.bool(telegram["is_premium"]))
        )
        let facts = SGCustomerDeviceFacts(
            deviceClass: try XCTUnwrap((device["device_class"] as? String).flatMap(SGCustomerDeviceClass.init(rawValue:))),
            deviceModel: device["device_model"] as? String,
            osVersion: try XCTUnwrap(body["os_version"] as? String),
            appVersion: try XCTUnwrap(body["app_version"] as? String) + "β",
            appBuild: device["app_build"] as? String,
            uiLanguage: (device["ui_language"] as? String).map { "\($0)-raw" },
            locale: (device["locale"] as? String).map { $0.replacingOccurrences(of: "-", with: "_") + "@calendar=gregorian" },
            timezone: device["timezone"] as? String,
            distribution: try XCTUnwrap((device["distribution"] as? String).flatMap(SGCustomerDistribution.init(rawValue:)))
        )
        return (user, facts)
    }
}
