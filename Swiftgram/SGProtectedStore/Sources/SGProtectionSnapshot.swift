import Foundation

/// Zenlygram — the protection state shared with the app extensions (audit batch 3).
///
/// JSON: `{"v":1,"vault":{"<accountPeerId>":[peerId,...]},"unassigned":[peerId,...],"locked":[peerId,...]}`
/// (dictionary keys are strings; ids are `PeerId.toInt64()` values).
/// - `vault`: Secret Vault members per account (audit #19 / #47 / #48 — keyed by the account's own peer id).
/// - `unassigned`: legacy (pre-batch-3, account-less) vault members, hidden in every account except the
///   account whose own peer id it is, until migration M4 assigns them to the logged-in accounts.
/// - `locked`: Chat Lock peers (device-wide, D6), mirrored for the extensions.
///
/// A payload with `v` > `currentVersion` (written by a newer build, then the app was downgraded) is decoded
/// leniently and marked `isNewerFormat`; `v` < 1 or a malformed v1 payload fails to decode.
public struct SGProtectionSnapshot: Codable, Equatable {
    public static let currentVersion = 1

    public var vault: [Int64: Set<Int64>]
    public var unassigned: Set<Int64>
    public var locked: Set<Int64>
    /// Decoded from a newer format this build only partly understands. Readers use it as is (it hides at least
    /// what the newer build hid); SGProtectedStore never writes on top of it while the vault is configured, so
    /// the newer data is not downgraded. Never encoded.
    public private(set) var isNewerFormat: Bool = false

    public static let empty = SGProtectionSnapshot(vault: [:], unassigned: [], locked: [])

    public init(vault: [Int64: Set<Int64>], unassigned: Set<Int64>, locked: Set<Int64>) {
        self.vault = vault
        self.unassigned = unassigned
        self.locked = locked
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case vault
        case unassigned
        case locked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .v) ?? SGProtectionSnapshot.currentVersion
        if version < 1 {
            throw DecodingError.dataCorruptedError(forKey: .v, in: container, debugDescription: "Unsupported protection snapshot version \(version)")
        }
        if version > SGProtectionSnapshot.currentVersion {
            // Written by a newer build: keep whatever still has the v1 shape, skip the rest. Failing here would
            // leave the item undecodable, i.e. every protected chat hidden until the vault is turned off.
            let rawVault = (try? container.decodeIfPresent([String: [Int64]].self, forKey: .vault)) ?? [:]
            var vault: [Int64: Set<Int64>] = [:]
            for (key, peerIds) in rawVault {
                guard let accountPeerId = Int64(key) else {
                    continue
                }
                vault[accountPeerId] = Set(peerIds)
            }
            self.vault = vault
            self.unassigned = Set((try? container.decodeIfPresent([Int64].self, forKey: .unassigned)) ?? [])
            self.locked = Set((try? container.decodeIfPresent([Int64].self, forKey: .locked)) ?? [])
            self.isNewerFormat = true
            return
        }
        let rawVault = try container.decodeIfPresent([String: [Int64]].self, forKey: .vault) ?? [:]
        var vault: [Int64: Set<Int64>] = [:]
        for (key, peerIds) in rawVault {
            guard let accountPeerId = Int64(key) else {
                throw DecodingError.dataCorruptedError(forKey: .vault, in: container, debugDescription: "Invalid account key")
            }
            vault[accountPeerId] = Set(peerIds)
        }
        self.vault = vault
        self.unassigned = Set(try container.decodeIfPresent([Int64].self, forKey: .unassigned) ?? [])
        self.locked = Set(try container.decodeIfPresent([Int64].self, forKey: .locked) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SGProtectionSnapshot.currentVersion, forKey: .v)
        var rawVault: [String: [Int64]] = [:]
        for (accountPeerId, peerIds) in self.vault where !peerIds.isEmpty {
            rawVault["\(accountPeerId)"] = peerIds.sorted()
        }
        try container.encode(rawVault, forKey: .vault)
        try container.encode(self.unassigned.sorted(), forKey: .unassigned)
        try container.encode(self.locked.sorted(), forKey: .locked)
    }

    /// Drops empty per-account sets and an account's own peer id from its set (Saved Messages is never
    /// vaulted, audit #48), so equal states compare equal.
    public mutating func normalize() {
        var vault: [Int64: Set<Int64>] = [:]
        for (accountPeerId, peerIds) in self.vault {
            let filtered = peerIds.subtracting([accountPeerId])
            if !filtered.isEmpty {
                vault[accountPeerId] = filtered
            }
        }
        self.vault = vault
    }

    /// Membership for one account: its own set plus the legacy unassigned ids. Never the account itself.
    public func isVaulted(_ peerId: Int64, accountPeerId: Int64) -> Bool {
        if peerId == accountPeerId {
            return false
        }
        if let peerIds = self.vault[accountPeerId], peerIds.contains(peerId) {
            return true
        }
        return self.unassigned.contains(peerId)
    }

    public func vaultMembers(accountPeerId: Int64) -> Set<Int64> {
        return (self.vault[accountPeerId] ?? []).union(self.unassigned).subtracting([accountPeerId])
    }

    public func isVaultedInAnyAccount(_ peerId: Int64) -> Bool {
        if self.unassigned.contains(peerId) {
            return true
        }
        for (_, peerIds) in self.vault where peerIds.contains(peerId) {
            return true
        }
        return false
    }

    public var allVaultMembers: Set<Int64> {
        var result = self.unassigned
        for (_, peerIds) in self.vault {
            result.formUnion(peerIds)
        }
        return result
    }
}
