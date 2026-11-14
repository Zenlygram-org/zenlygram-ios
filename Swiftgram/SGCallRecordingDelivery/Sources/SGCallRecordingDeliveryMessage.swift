// MARK: Zenlygram — call recording delivery: the message a leg becomes.
//
// Split out of SGCallRecordingDelivery.swift; same type, same rules (see that file's header).

import Foundation
import Darwin

import TelegramCore

import SGCallRecording
import SGCallRecordingDeliveryCore
import SGStrings

extension SGCallRecordingDelivery {
    /// The message one leg becomes. `neutral` names nobody: no peer in the caption, the file name or
    /// the audio title — used for a protected recording the user explicitly authorized exporting.
    func message(item: SGCallRecordingItem, record: SGCallRecordingSendRecord, legIndex: Int, path: String, lang: String, neutral: Bool) -> EnqueueMessage? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber else {
            return nil
        }
        let dateString = sgCallRecordingMessageDateFormatter.string(from: Date(timeIntervalSince1970: item.startTimestamp))

        // A pre-mix recording is two files, so two messages, each saying which half it is.
        var legSuffix = ""
        if record.legs.count > 1 {
            let key = legIndex == 0 ? "CallRecording.SendToSaved.Leg.Local" : "CallRecording.SendToSaved.Leg.Remote"
            legSuffix = " · \(i18n(key, lang))"
        }

        let caption: String
        let fileName: String
        let audioTitle: String?
        if neutral {
            caption = "CallRecording.SendToSaved.Caption.Neutral".i18n(lang, args: dateString) + legSuffix
            fileName = sgCallRecordingSanitizedFileName("\(caption).ogg")
            audioTitle = nil
        } else {
            let peerTitle = item.peerTitle.isEmpty ? i18n("CallRecording.UnknownPeer", lang) : item.peerTitle
            caption = "CallRecording.SendToSaved.Caption".i18n(lang, args: peerTitle, dateString) + legSuffix
            fileName = sgCallRecordingSanitizedFileName("\(peerTitle) \(dateString)\(legSuffix).ogg")
            audioTitle = peerTitle
        }

        let correlationId = record.legs[legIndex].correlationId
        // `isUniquelyReferencedTemporaryFile: false` — the uploader COPIES this file into the media
        // box and leaves the original alone: the recording on disk is the only copy the user is
        // guaranteed to have until the server says otherwise. The random id is DERIVED from the
        // correlation id so that copy can be found and removed later by its exact resource id.
        let resource = LocalFileReferenceMediaResource(
            localFilePath: path,
            randomId: sgCallRecordingResourceRandomId(correlationId: correlationId),
            isUniquelyReferencedTemporaryFile: false,
            size: size.int64Value
        )
        let file = TelegramMediaFile(
            fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)),
            partialReference: nil,
            resource: resource,
            previewRepresentations: [],
            videoThumbnails: [],
            immediateThumbnailData: nil,
            mimeType: "audio/ogg",
            size: size.int64Value,
            attributes: [
                .FileName(fileName: fileName),
                .Audio(isVoice: false, duration: Int(item.duration.rounded()), title: audioTitle, performer: dateString, waveform: nil)
            ],
            alternativeRepresentations: []
        )

        return .message(
            text: caption,
            attributes: [],
            inlineStickers: [:],
            mediaReference: .standalone(media: file),
            threadId: nil,
            replyToMessageId: nil,
            replyToStoryId: nil,
            localGroupingKey: nil,
            correlationId: correlationId,
            bubbleUpEmojiOrStickersets: []
        )
    }
}

private let sgCallRecordingMessageDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

/// Whether the file can be opened for reading RIGHT NOW. `FileManager.isReadableFile` answers a
/// POSIX-permission question and says yes for a file its data-protection class makes unopenable.
/// A one-byte read is the only honest test. Nothing about the file is logged or returned.
func sgCallRecordingFileIsReadable(atPath path: String) -> Bool {
    let descriptor = Darwin.open(path, O_RDONLY)
    if descriptor < 0 {
        return false
    }
    var probe: UInt8 = 0
    let count = Darwin.read(descriptor, &probe, 1)
    Darwin.close(descriptor)
    return count >= 0
}

/// A file name that survives every filesystem and every client it may be opened on.
private func sgCallRecordingSanitizedFileName(_ value: String) -> String {
    var result = ""
    for character in value {
        if character.isNewline {
            result.append(" ")
        } else if "/\\:*?\"<>|".contains(character) {
            result.append("-")
        } else {
            result.append(character)
        }
    }
    result = result.trimmingCharacters(in: .whitespaces)
    if result.count > 120 {
        result = String(result.prefix(116)) + ".ogg"
    }
    if result.isEmpty {
        result = "call.ogg"
    }
    return result
}
