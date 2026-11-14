import Foundation
import Postbox

// SG: retention constants shared by the kept-deleted messages and edit-history features
// (policy and sweeper: State/SGMessageRetention.swift).

/// Kept-deleted messages and edit-history revisions are purged this long after they were stamped/captured.
public let sgRetentionMaxAgeSeconds: Int32 = 30 * 24 * 60 * 60
/// At most this many kept-deleted messages are stored per account (oldest removed first).
public let sgKeptDeletedMaxCountPerAccount: Int = 5000
/// At most this many edit-history revisions are stored per message (newest kept).
public let sgEditedMessageHistoryMaxRevisions: Int = 20
/// Postbox timestamp-index tags. Upstream uses 0 (autoremove) and 1 (autoclear); re-check
/// `automaticTimestampBasedAttribute` users on every upstream sync to avoid collisions.
public let sgKeptDeletedTimestampTag: UInt16 = 0x5347
public let sgEditHistoryTimestampTag: UInt16 = 0x5348

/// Local wall-clock Unix time. Retention deliberately never uses the server time offset.
public func sgRetentionNow() -> Int32 {
    return Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
}

public class DeletedMessageAttribute: MessageAttribute, Equatable {
    public let deletionTimestamp: Int32
    /// 0 = legacy stamp (pre-index builds, never indexed), 1 = indexed for the retention sweeper.
    public let schema: Int32
    public let automaticTimestampBasedAttribute: (UInt16, Int32)?

    public init(deletionTimestamp: Int32 = 0, schema: Int32 = 1) {
        self.deletionTimestamp = deletionTimestamp
        self.schema = schema
        self.automaticTimestampBasedAttribute = DeletedMessageAttribute.indexValue(deletionTimestamp: deletionTimestamp, schema: schema)
    }

    required public init(decoder: PostboxDecoder) {
        // SG: backward-compat — old instances stored no fields, decode as 0 (legacy schema).
        let deletionTimestamp = decoder.decodeInt32ForKey("sg_dts", orElse: 0)
        let schema = decoder.decodeInt32ForKey("sg_v", orElse: 0)
        self.deletionTimestamp = deletionTimestamp
        self.schema = schema
        self.automaticTimestampBasedAttribute = DeletedMessageAttribute.indexValue(deletionTimestamp: deletionTimestamp, schema: schema)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.deletionTimestamp, forKey: "sg_dts")
        encoder.encodeInt32(self.schema, forKey: "sg_v")
    }

    // Postbox (re)indexes only when this value changes between the stored and the updated
    // message, which is why legacy (schema 0) stamps compute nil and are indexed by restamping.
    private static func indexValue(deletionTimestamp: Int32, schema: Int32) -> (UInt16, Int32)? {
        if schema >= 1 && deletionTimestamp > 0 {
            return (sgKeptDeletedTimestampTag, deletionTimestamp &+ sgRetentionMaxAgeSeconds)
        } else {
            return nil
        }
    }

    public static func ==(lhs: DeletedMessageAttribute, rhs: DeletedMessageAttribute) -> Bool {
        return lhs.deletionTimestamp == rhs.deletionTimestamp && lhs.schema == rhs.schema
    }
}

/// True for a message kept locally after the server deleted it (any stamp, legacy included).
public func sgIsKeptDeletedMessage(_ message: Message?) -> Bool {
    return message?.sgIsKeptDeleted ?? false
}

public extension Message {
    /// True for a message kept locally after the server deleted it (any stamp, legacy included).
    var sgIsKeptDeleted: Bool {
        for attribute in self.attributes {
            if attribute is DeletedMessageAttribute {
                return true
            }
        }
        return false
    }

    /// Local time the message was stamped as deleted; nil when not kept or when the stamp has no time.
    var sgKeptDeletionTimestamp: Int32? {
        for attribute in self.attributes {
            if let attribute = attribute as? DeletedMessageAttribute {
                return attribute.deletionTimestamp > 0 ? attribute.deletionTimestamp : nil
            }
        }
        return nil
    }
}

public extension EngineMessage {
    /// True for a message kept locally after the server deleted it (any stamp, legacy included).
    var sgIsKeptDeleted: Bool {
        for attribute in self.attributes {
            if attribute is DeletedMessageAttribute {
                return true
            }
        }
        return false
    }
}
