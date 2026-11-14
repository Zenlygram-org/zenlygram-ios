import Foundation
import Postbox

public struct EditedMessageHistoryEntry: PostboxCoding, Codable, Equatable {
    public let timestamp: Int32
    public let text: String
    public let entities: [MessageTextEntity]
    // Fenixuz v2: previous media of the edited message (photos/videos/files).
    // Encoded via the Postbox generic-object path only; entries stored before
    // this field existed decode to an empty array (missing key -> []).
    public let media: [Media]
    // SG: local wall-clock time this revision was captured (retention: purged 30 days later).
    // 0 for revisions stored before the field existed (legacy; never shown).
    public let capturedAt: Int32

    public init(timestamp: Int32, text: String, entities: [MessageTextEntity], media: [Media] = [], capturedAt: Int32 = 0) {
        self.timestamp = timestamp
        self.text = text
        self.entities = entities
        self.media = media
        self.capturedAt = capturedAt
    }

    public init(decoder: PostboxDecoder) {
        self.timestamp = decoder.decodeInt32ForKey("t", orElse: 0)
        self.text = decoder.decodeStringForKey("text", orElse: "")
        self.entities = decoder.decodeObjectArrayWithDecoderForKey("entities")
        let mediaObjects: [PostboxCoding] = decoder.decodeObjectArrayForKey("media")
        self.media = mediaObjects.compactMap { $0 as? Media }
        self.capturedAt = decoder.decodeInt32ForKey("ca", orElse: 0)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        self.timestamp = try container.decode(Int32.self, forKey: "t")
        self.text = try container.decode(String.self, forKey: "text")
        self.entities = try container.decode([MessageTextEntity].self, forKey: "entities")
        // Media is not representable through the Codable path; persistence goes
        // through PostboxCoding above, so this path intentionally drops media.
        self.media = []
        self.capturedAt = try container.decodeIfPresent(Int32.self, forKey: "ca") ?? 0
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.timestamp, forKey: "t")
        encoder.encodeString(self.text, forKey: "text")
        encoder.encodeObjectArray(self.entities, forKey: "entities")
        encoder.encodeGenericObjectArray(self.media.map { $0 as PostboxCoding }, forKey: "media")
        encoder.encodeInt32(self.capturedAt, forKey: "ca")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encode(self.timestamp, forKey: "t")
        try container.encode(self.text, forKey: "text")
        try container.encode(self.entities, forKey: "entities")
        try container.encode(self.capturedAt, forKey: "ca")
    }

    public static func ==(lhs: EditedMessageHistoryEntry, rhs: EditedMessageHistoryEntry) -> Bool {
        return lhs.timestamp == rhs.timestamp && lhs.text == rhs.text && lhs.entities == rhs.entities && lhs.media.map { $0.id } == rhs.media.map { $0.id } && lhs.capturedAt == rhs.capturedAt
    }
}

// SG: opt-in, local-only edit history (policy and sweeper: State/SGMessageRetention.swift).
// Schema 1 attributes are indexed in Postbox at min(capturedAt) + 30 days so the sweeper can
// purge expired revisions. An EMPTY schema-1 attribute is a tombstone: it is not indexed and not
// carried across message re-saves, and it is how history is removed (removing the attribute by
// omission is undone by mergeMessageAttributes). Schema 0 (legacy, pre-opt-in) is never shown.
public class EditedMessageHistoryAttribute: MessageAttribute, Equatable {
    public let history: [EditedMessageHistoryEntry]
    public let schema: Int32
    public let automaticTimestampBasedAttribute: (UInt16, Int32)?

    public init(history: [EditedMessageHistoryEntry], schema: Int32 = 1) {
        self.history = history
        self.schema = schema
        self.automaticTimestampBasedAttribute = EditedMessageHistoryAttribute.indexValue(history: history, schema: schema)
    }

    required public init(decoder: PostboxDecoder) {
        let history: [EditedMessageHistoryEntry] = decoder.decodeObjectArrayWithDecoderForKey("history")
        let schema = decoder.decodeInt32ForKey("sg_v", orElse: 0)
        self.history = history
        self.schema = schema
        self.automaticTimestampBasedAttribute = EditedMessageHistoryAttribute.indexValue(history: history, schema: schema)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeObjectArray(self.history, forKey: "history")
        encoder.encodeInt32(self.schema, forKey: "sg_v")
    }

    private static func indexValue(history: [EditedMessageHistoryEntry], schema: Int32) -> (UInt16, Int32)? {
        if schema < 1 {
            return nil
        }
        var minCapturedAt: Int32?
        for entry in history where entry.capturedAt > 0 {
            if let current = minCapturedAt {
                minCapturedAt = min(current, entry.capturedAt)
            } else {
                minCapturedAt = entry.capturedAt
            }
        }
        if let minCapturedAt {
            return (sgEditHistoryTimestampTag, minCapturedAt &+ sgRetentionMaxAgeSeconds)
        } else {
            return nil
        }
    }

    /// Non-empty current-schema history (not legacy, not a tombstone).
    public var isCurrentFormat: Bool {
        return self.schema >= 1 && !self.history.isEmpty
    }

    /// Revisions that may be shown/kept: current schema, captured less than 30 days before `now`
    /// and after the last purge request (`purgeBefore`, 0 = none).
    public func sgVisibleHistory(now: Int32, purgeBefore: Int32) -> [EditedMessageHistoryEntry] {
        if self.schema < 1 {
            return []
        }
        return self.history.filter { entry in
            return entry.capturedAt > 0 && entry.capturedAt &+ sgRetentionMaxAgeSeconds > now && entry.capturedAt > purgeBefore
        }
    }

    public var associatedPeerIds: [PeerId] {
        var result: [PeerId] = []
        for entry in self.history {
            for entity in entry.entities {
                switch entity.type {
                    case let .TextMention(peerId):
                        result.append(peerId)
                    default:
                        break
                }
            }
        }
        return result
    }

    public var associatedMediaIds: [MediaId] {
        var result: [MediaId] = []
        for entry in self.history {
            for entity in entry.entities {
                switch entity.type {
                case let .CustomEmoji(_, fileId):
                    result.append(MediaId(namespace: Namespaces.Media.CloudFile, id: fileId))
                default:
                    break
                }
            }
            for media in entry.media {
                if let id = media.id {
                    result.append(id)
                }
            }
        }
        if result.isEmpty {
            return result
        } else {
            return Array(Set(result))
        }
    }

    public static func ==(lhs: EditedMessageHistoryAttribute, rhs: EditedMessageHistoryAttribute) -> Bool {
        return lhs.history == rhs.history && lhs.schema == rhs.schema
    }
}
