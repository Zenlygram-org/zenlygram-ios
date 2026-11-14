import Foundation

// SG: fork read access to the timestamp-based message attribute index, used by the
// retention sweeper for kept-deleted messages and edit history
// (TelegramCore/Sources/State/SGMessageRetention.swift).
//
// The key layout mirrors TimestampBasedMessageAttributesTable.key(tag:timestamp:id:):
// [tag: UInt16][timestamp: Int32][peerId: Int64][namespace: Int32][id: Int32].
// The upstream key/bound helpers are private, so the bounds are rebuilt here.
extension TimestampBasedMessageAttributesTable {
    private func sgLowerBound(tag: UInt16) -> ValueBoxKey {
        let key = ValueBoxKey(length: 3)
        key.setUInt16(0, value: tag)
        key.setInt8(2, value: 0)
        return key
    }

    private func sgUpperBound(tag: UInt16) -> ValueBoxKey {
        let key = ValueBoxKey(length: 3)
        key.setUInt16(0, value: tag &+ 1)
        key.setInt8(2, value: 0)
        return key
    }

    /// Exclusive end key that admits every entry of `tag` with `entry.timestamp <= timestamp`.
    private func sgEndKey(tag: UInt16, upTo timestamp: Int32) -> ValueBoxKey {
        if timestamp == Int32.max {
            return self.sgUpperBound(tag: tag)
        }
        let key = ValueBoxKey(length: 2 + 4)
        key.setUInt16(0, value: tag)
        key.setInt32(2, value: timestamp + 1)
        return key
    }

    /// Entries of `tag` with `timestamp <= upTo`, oldest first. `limit <= 0` means no limit.
    func sgEntries(tag: UInt16, upTo timestamp: Int32, limit: Int) -> [TimestampBasedMessageAttributesEntry] {
        var result: [TimestampBasedMessageAttributesEntry] = []
        self.valueBox.range(self.table, start: self.sgLowerBound(tag: tag), end: self.sgEndKey(tag: tag, upTo: timestamp), keys: { key in
            let entryTimestamp = key.getInt32(2)
            let idPeerId = key.getInt64(2 + 4)
            let idNamespace = key.getInt32(2 + 4 + 8)
            let idId = key.getInt32(2 + 4 + 8 + 4)
            result.append(TimestampBasedMessageAttributesEntry(tag: tag, timestamp: entryTimestamp, messageId: MessageId(peerId: PeerId(idPeerId), namespace: idNamespace, id: idId)))
            return true
        }, limit: limit)
        return result
    }

    /// Number of index entries stored under `tag`.
    func sgCount(tag: UInt16) -> Int {
        return self.valueBox.count(self.table, start: self.sgLowerBound(tag: tag), end: self.sgUpperBound(tag: tag))
    }
}
