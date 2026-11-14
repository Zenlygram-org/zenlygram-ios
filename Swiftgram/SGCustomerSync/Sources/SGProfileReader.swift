import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import SGCustomerSyncCore

/// Zenlygram — the signed-in accounts' own Telegram users, read locally from the account's database
/// (design 40 §9.1): `engine.data.subscribe(Peer.Peer(id: account.peerId))`, nothing sent. Only the
/// accounts that may upload their profile (`.uploadProfile` clearance) are read; another chat, another
/// peer or the user's `language_code` never is.
///
/// Main queue. `didChange` gets an account whose user changed (its snapshot digest may have).
final class SGProfileReader {
    private final class Subscription {
        weak var context: AccountContext?
        let disposable = MetaDisposable()

        init(context: AccountContext) {
            self.context = context
        }
    }

    private var subscriptions: [Int64: Subscription] = [:]
    private var users: [Int64: SGProfileUser] = [:]
    var didChange: ((Int64) -> Void)?

    deinit {
        for subscription in self.subscriptions.values {
            subscription.disposable.dispose()
        }
    }

    /// Reads exactly these accounts (packed `PeerId.toInt64()` → its context); every other
    /// subscription and value goes.
    func read(_ accounts: [Int64: AccountContext]) {
        assert(Thread.isMainThread)
        for (accountPeerId, subscription) in self.subscriptions {
            if let context = accounts[accountPeerId], context === subscription.context {
                continue
            }
            subscription.disposable.dispose()
            self.subscriptions[accountPeerId] = nil
            self.users[accountPeerId] = nil
        }
        for (accountPeerId, context) in accounts where self.subscriptions[accountPeerId] == nil {
            let userId = context.account.peerId.id._internalGetInt64Value()
            let subscription = Subscription(context: context)
            self.subscriptions[accountPeerId] = subscription
            subscription.disposable.set((context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
            |> map { peer -> SGProfileUser? in
                return SGProfileReader.user(peer, userId: userId)
            }
            |> distinctUntilChanged
            |> deliverOnMainQueue).startStrict(next: { [weak self, weak subscription] user in
                // Only the account's current subscription writes (a replaced one may still deliver).
                guard let self, let subscription, self.subscriptions[accountPeerId] === subscription else {
                    return
                }
                let previous = self.users[accountPeerId]
                self.users[accountPeerId] = user
                if previous != user {
                    self.didChange?(accountPeerId)
                }
            }))
        }
    }

    /// The account's user as last read; nil until the first read or while it is not read.
    func user(accountPeerId: Int64) -> SGProfileUser? {
        return self.users[accountPeerId]
    }

    /// The fields `SGProfileSnapshot` normalises (design 40 §9.1).
    static func user(_ peer: EnginePeer?, userId: Int64) -> SGProfileUser? {
        guard case let .user(user)? = peer else {
            return nil
        }
        return SGProfileUser(
            userId: userId,
            phone: user.phone,
            usernames: user.usernames.map { username in
                return SGProfileUser.Username(value: username.username, isActive: username.flags.contains(.isActive), isEditable: username.flags.contains(.isEditable))
            },
            username: user.username,
            firstName: user.firstName,
            lastName: user.lastName,
            isPremium: user.flags.contains(.isPremium)
        )
    }

    // MARK: - The wall's account line

    /// `Consent.Wall.Account`'s `%@` for the account in `context` (design 40 §5.3): first + last
    /// name, else `@username`, else the phone masked to its last two digits
    /// (`+998 •• ••• •• 67`); nil until the local read finishes. Read from the account's database
    /// only, nothing sent.
    static func wallIdentity(context: AccountContext) -> Signal<String?, NoError> {
        return context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        |> map { peer -> String? in
            guard case let .user(user)? = peer else {
                return nil
            }
            let username = user.usernames.first(where: { $0.flags.contains(.isActive) })?.username ?? user.username
            return SGProfileReader.accountLine(firstName: user.firstName, lastName: user.lastName, username: username, phone: user.phone)
        }
        |> distinctUntilChanged
    }

    static func accountLine(firstName: String?, lastName: String?, username: String?, phone: String?) -> String? {
        let name = [firstName, lastName].compactMap { part -> String? in
            guard let trimmed = part?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }.joined(separator: " ")
        if !name.isEmpty {
            return name
        }
        if let username, !username.isEmpty {
            return "@" + username
        }
        return SGProfileReader.maskedPhone(phone)
    }

    /// `+<country code> •• ••• •• <last two digits>`: only the country code (ITU E.164 prefixes) and
    /// the last two digits stay; nil without at least 7 digits.
    static func maskedPhone(_ phone: String?) -> String? {
        let digits = Array((phone ?? "").unicodeScalars.filter { $0.value >= 0x30 && $0.value <= 0x39 }.map(Character.init))
        guard digits.count >= 7 else {
            return nil
        }
        let codeLength = SGProfileReader.countryCodeLength(digits)
        let hidden = digits.count - codeLength - 2
        var groups: [String] = []
        var remaining = hidden
        let pattern = [2, 3, 2]
        var index = 0
        while remaining > 0 {
            let size = min(remaining, pattern[index % pattern.count])
            groups.append(String(repeating: "\u{2022}", count: size))
            remaining -= size
            index += 1
        }
        return "+" + String(digits.prefix(codeLength)) + " " + groups.joined(separator: " ") + " " + String(digits.suffix(2))
    }

    /// The length of the E.164 country code `digits` start with (1, 2 or 3).
    static func countryCodeLength(_ digits: [Character]) -> Int {
        guard let first = digits.first else {
            return 0
        }
        if first == "1" || first == "7" {
            return 1
        }
        guard digits.count >= 2 else {
            return 1
        }
        let twoDigitCodes: Set<String> = [
            "20", "27", "30", "31", "32", "33", "34", "36", "39", "40", "41", "43", "44", "45", "46", "47", "48", "49",
            "51", "52", "53", "54", "55", "56", "57", "58", "60", "61", "62", "63", "64", "65", "66", "81", "82", "84",
            "86", "90", "91", "92", "93", "94", "95", "98",
        ]
        return twoDigitCodes.contains(String(digits.prefix(2))) ? 2 : 3
    }
}
