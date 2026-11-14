import TextFormat
import Foundation
import NaturalLanguage
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramUIPreferences
import SGSimpleSettings // Zenlygram — #60

public struct ChatTranslationState: Codable {
    enum CodingKeys: String, CodingKey {
        case baseLang
        case fromLang
        case timestamp
        case toLang
        case isEnabled
        case sgGoogleConsent // Zenlygram — #60
    }
    
    public let baseLang: String
    public let fromLang: String
    public let timestamp: Int32?
    public let toLang: String?
    public let isEnabled: Bool
    // Zenlygram — #60: true only when translation was switched on by an explicit tap while Google Translate was the selected service.
    // An isEnabled that came from Telegram's channel auto-translate (or was set under the Telegram service) never sends text to Google.
    public let sgGoogleConsent: Bool
    
    public init(
        baseLang: String,
        fromLang: String,
        timestamp: Int32?,
        toLang: String?,
        isEnabled: Bool,
        sgGoogleConsent: Bool = false // Zenlygram — #60
    ) {
        self.baseLang = baseLang
        self.fromLang = fromLang
        self.timestamp = timestamp
        self.toLang = toLang
        self.isEnabled = isEnabled
        self.sgGoogleConsent = sgGoogleConsent // Zenlygram — #60
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.baseLang = try container.decode(String.self, forKey: .baseLang)
        self.fromLang = try container.decode(String.self, forKey: .fromLang)
        self.timestamp = try container.decodeIfPresent(Int32.self, forKey: .timestamp)
        self.toLang = try container.decodeIfPresent(String.self, forKey: .toLang)
        self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        self.sgGoogleConsent = try container.decodeIfPresent(Bool.self, forKey: .sgGoogleConsent) ?? false // Zenlygram — #60
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(self.baseLang, forKey: .baseLang)
        try container.encode(self.fromLang, forKey: .fromLang)
        try container.encodeIfPresent(self.timestamp, forKey: .timestamp)
        try container.encodeIfPresent(self.toLang, forKey: .toLang)
        try container.encode(self.isEnabled, forKey: .isEnabled)
        try container.encode(self.sgGoogleConsent, forKey: .sgGoogleConsent) // Zenlygram — #60
    }

    public func withFromLang(_ fromLang: String) -> ChatTranslationState {
        return ChatTranslationState(
            baseLang: self.baseLang,
            fromLang: fromLang,
            timestamp: self.timestamp,
            toLang: self.toLang,
            isEnabled: self.isEnabled,
            sgGoogleConsent: self.sgGoogleConsent // Zenlygram — #60
        )
    }
    public func withToLang(_ toLang: String?) -> ChatTranslationState {
        return ChatTranslationState(
            baseLang: self.baseLang,
            fromLang: self.fromLang,
            timestamp: self.timestamp,
            toLang: toLang,
            isEnabled: self.isEnabled,
            sgGoogleConsent: self.sgGoogleConsent // Zenlygram — #60
        )
    }
    
    public func withIsEnabled(_ isEnabled: Bool) -> ChatTranslationState {
        return ChatTranslationState(
            baseLang: self.baseLang,
            fromLang: self.fromLang,
            timestamp: self.timestamp,
            toLang: self.toLang,
            isEnabled: isEnabled,
            // Zenlygram — #60: every withIsEnabled caller is an explicit user action (Translate bar, language pick, PeerInfo 'Translate');
            // turning on while Google is selected records consent, turning off clears it.
            sgGoogleConsent: isEnabled ? (self.sgGoogleConsent || sgTranslationUsesGoogle()) : false
        )
    }
}

// Zenlygram — #60: read-time gate. With Google selected, a stored isEnabled without Google consent (auto-translate channel,
// or enabled while the Telegram service was selected) is shown as "not translated" until the user taps Translate.
// The downgraded copy is never persisted, so switching back to Telegram restores the upstream behaviour.
private func sgEffectiveTranslationState(_ s: ChatTranslationState) -> ChatTranslationState {
    if sgTranslationUsesGoogle() && s.isEnabled && !s.sgGoogleConsent {
        return ChatTranslationState(
            baseLang: s.baseLang,
            fromLang: s.fromLang,
            timestamp: s.timestamp,
            toLang: s.toLang,
            isEnabled: false,
            sgGoogleConsent: false
        )
    }
    return s
}

private func cachedChatTranslationState(engine: TelegramEngine, peerId: EnginePeer.Id, threadId: Int64?) -> Signal<ChatTranslationState?, NoError> {
    let key: EngineDataBuffer
    if let threadId {
        key = EngineDataBuffer(length: 16)
        key.setInt64(0, value: peerId.id._internalGetInt64Value())
        key.setInt64(8, value: threadId)
    } else {
        key = EngineDataBuffer(length: 8)
        key.setInt64(0, value: peerId.id._internalGetInt64Value())
    }
    
    return engine.data.subscribe(TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.translationState, id: key))
    |> map { entry -> ChatTranslationState? in
        return entry?.get(ChatTranslationState.self)
    }
}

private func updateChatTranslationState(engine: TelegramEngine, peerId: EnginePeer.Id, threadId: Int64?, state: ChatTranslationState?) -> Signal<Never, NoError> {
    let key: EngineDataBuffer
    if let threadId {
        key = EngineDataBuffer(length: 16)
        key.setInt64(0, value: peerId.id._internalGetInt64Value())
        key.setInt64(8, value: threadId)
    } else {
        key = EngineDataBuffer(length: 8)
        key.setInt64(0, value: peerId.id._internalGetInt64Value())
    }
    
    if let state {
        return engine.itemCache.put(collectionId: ApplicationSpecificItemCacheCollectionId.translationState, id: key, item: state)
    } else {
        return engine.itemCache.remove(collectionId: ApplicationSpecificItemCacheCollectionId.translationState, id: key)
    }
}

public func updateChatTranslationStateInteractively(engine: TelegramEngine, peerId: EnginePeer.Id, threadId: Int64?, _ f: @escaping (ChatTranslationState?) -> ChatTranslationState?) -> Signal<Never, NoError> {
    let key: EngineDataBuffer
    if let threadId {
        key = EngineDataBuffer(length: 16)
        key.setInt64(0, value: peerId.id._internalGetInt64Value())
        key.setInt64(8, value: threadId)
    } else {
        key = EngineDataBuffer(length: 8)
        key.setInt64(0, value: peerId.id._internalGetInt64Value())
    }
    
    return engine.data.get(TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.translationState, id: key))
    |> map { entry -> ChatTranslationState? in
        return entry?.get(ChatTranslationState.self)
    }
    |> mapToSignal { current -> Signal<Never, NoError> in
        if let current {
            return updateChatTranslationState(engine: engine, peerId: peerId, threadId: threadId, state: f(current))
        } else {
            return .never()
        }
    }
}


@available(iOS 12.0, *)
private let languageRecognizer = NLLanguageRecognizer()

public func translateMessageIds(context: AccountContext, messageIds: [EngineMessage.Id], fromLang: String?, toLang: String, viaText: Bool = false, forQuickTranslate: Bool = false) -> Signal<Never, NoError> {
    return context.account.postbox.transaction { transaction -> Signal<Never, NoError> in
        var messageDictToTranslate: [EngineMessage.Id: String] = [:]
        var messageIdsToTranslate: [EngineMessage.Id] = []
        var messageIdsSet = Set<EngineMessage.Id>()
        // Zenlygram — #61: 1:1 chats keep "restrict saving" in CachedUserData, not on each message (see ChatHistoryListNode isCopyProtectionEnabled).
        func sgChatCopyProtected(_ peerId: EnginePeer.Id) -> Bool {
            if let cached = transaction.getPeerCachedData(peerId: peerId) as? CachedUserData {
                return cached.flags.contains(.copyProtectionEnabled) || cached.flags.contains(.myCopyProtectionEnabled)
            }
            return false
        }
        for messageId in messageIds {
            if let message = transaction.getMessage(messageId) {
                // Zenlygram — #61: the quoted reply is translated only if it may be (never E2E; never copy-protected via Google).
                // Zenlygram — a kept-deleted copy (Show Deleted Messages) no longer exists on the server, so Telegram's
                // by-ID translation must not get its ID: the per-peer request would fail and take the other messages of
                // the batch down with it (no Google fallback since #60). Only the by-text path (viaText) can translate it.
                if let replyAttribute = message.attributes.first(where: { $0 is ReplyMessageAttribute }) as? ReplyMessageAttribute, let replyMessage = message.associatedMessages[replyAttribute.messageId], viaText || !replyMessage.sgIsKeptDeleted, sgMayTranslate(peerId: replyMessage.id.peerId, isCopyProtected: replyMessage.isCopyProtected() || message.isCopyProtected() || (viaText && (sgChatCopyProtected(replyMessage.id.peerId) || sgChatCopyProtected(message.id.peerId))), viaGoogle: viaText) {
                    if !replyMessage.text.isEmpty {
                        if let translation = replyMessage.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute, translation.toLang == toLang {
                        } else {
                            if !messageIdsSet.contains(replyMessage.id) {
                                messageIdsToTranslate.append(replyMessage.id)
                                messageIdsSet.insert(replyMessage.id)
                                messageDictToTranslate[replyMessage.id] = replyMessage.text
                            }
                        }
                    }
                }
                if !viaText && message.sgIsKeptDeleted {
                    continue
                }
                // Zenlygram — #61: secret-chat text is never translated; copy-protected text never goes to Google.
                guard sgMayTranslate(peerId: message.id.peerId, isCopyProtected: message.isCopyProtected() || (viaText && sgChatCopyProtected(message.id.peerId)), viaGoogle: viaText) else {
                    continue
                }
                // MARK: Swiftgram
                guard forQuickTranslate || message.author?.id != context.account.peerId else {
                    continue
                }
                if let translation = message.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute, translation.toLang == toLang {
                    continue
                }
                
                if !message.text.isEmpty {
                    if !messageIdsSet.contains(messageId) {
                        messageIdsToTranslate.append(messageId)
                        messageIdsSet.insert(messageId)
                        messageDictToTranslate[messageId] = message.text
                    }
                } else if let _ = message.richText {
                    if !messageIdsSet.contains(messageId) {
                        messageIdsToTranslate.append(messageId)
                        messageIdsSet.insert(messageId)
                        messageDictToTranslate[messageId] = message.text
                    }
                } else if let _ = message.richText {
                    if !messageIdsSet.contains(messageId) {
                        messageIdsToTranslate.append(messageId)
                        messageIdsSet.insert(messageId)
                        messageDictToTranslate[messageId] = message.text
                    }
                // TODO(swiftgram): Translate polls
                } else if let _ = message.media.first(where: { $0 is TelegramMediaPoll }), !viaText {
                    if !messageIdsSet.contains(messageId) {
                        messageIdsToTranslate.append(messageId)
                        messageIdsSet.insert(messageId)
                    }
                } else if let audioTranscription = message.attributes.first(where: { $0 is AudioTranscriptionMessageAttribute }) as? AudioTranscriptionMessageAttribute, !audioTranscription.text.isEmpty && !audioTranscription.isPending {
                    if !messageIdsSet.contains(messageId) {
                        messageIdsToTranslate.append(messageId)
                        messageIdsSet.insert(messageId)
                    }
                }
            } else {
                // Zenlygram — #61: a secret-chat message is never sent for translation, even if it is not loaded yet.
                if messageId.peerId.namespace == Namespaces.Peer.SecretChat {
                    continue
                }
                if !messageIdsSet.contains(messageId) {
                    messageIdsToTranslate.append(messageId)
                    messageIdsSet.insert(messageId)
                }
            }
        }
        
        let translationConfiguration = TranslationConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
        var enableLocalIfPossible = false
        switch translationConfiguration.auto {
        case .system:
            if #available(iOS 18.0, *) {
                enableLocalIfPossible = true
            }
        default:
            break
        }
        if viaText {
        // Zenlygram — #61: everything may have been filtered out; an empty batch must not leave the Quick Translate spinner hanging.
        if messageDictToTranslate.isEmpty {
            return .complete()
        }
        return context.engine.messages.translateMessagesViaText(messagesDict: messageDictToTranslate, fromLang: fromLang, toLang: toLang, generateEntitiesFunction: { text in
            generateTextEntities(text, enabledTypes: .all)
        }, enableLocalIfPossible: enableLocalIfPossible) //context.sharedContext.immediateExperimentalUISettings.enableLocalTranslation)
        |> `catch` { _ -> Signal<Never, NoError> in
            return .complete()
        }
        } else {
        if forQuickTranslate && messageIdsToTranslate.isEmpty { return .complete() } // Otherwise Telegram's API will return .never()
        return context.engine.messages.translateMessages(messageIds: messageIdsToTranslate, fromLang: fromLang, toLang: toLang, enableLocalIfPossible: enableLocalIfPossible)
        |> `catch` { _ -> Signal<Never, NoError> in
            // Zenlygram — #60: no silent fallback to Google Translate; a failed Telegram translation just shows nothing.
            return .complete()
        }
        }
    } |> switchToLatest
}

public func chatTranslationState(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64?, forcePredict: Bool = false) -> Signal<ChatTranslationState?, NoError> {
    if peerId.id == EnginePeer.Id.Id._internalFromInt64Value(777000) {
        return .single(nil)
    }
    
    guard canTranslateChats(context: context) else {
        return .single(nil)
    }
    
    let loggingEnabled = context.sharedContext.immediateExperimentalUISettings.logLanguageRecognition
    
    if #available(iOS 12.0, *) {
        var baseLang = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        let rawSuffix = "-raw"
        if baseLang.hasSuffix(rawSuffix) {
            baseLang = String(baseLang.dropLast(rawSuffix.count))
        }

        return combineLatest(
            context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.translationSettings])
            |> map { sharedData -> TranslationSettings in
                return sharedData.entries[ApplicationSpecificSharedDataKeys.translationSettings]?.get(TranslationSettings.self) ?? TranslationSettings.defaultSettings
            },
            context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.AutoTranslateEnabled(id: peerId))
        )
        |> mapToSignal { settings, autoTranslateEnabled in
            if !settings.translateChats && !autoTranslateEnabled && !forcePredict {
                return .single(nil)
            }
            
            var dontTranslateLanguages = Set<String>()
            if let ignoredLanguages = settings.ignoredLanguages {
                dontTranslateLanguages = Set(ignoredLanguages)
            } else {
                dontTranslateLanguages.insert(baseLang)
                for language in systemLanguageCodes() {
                    dontTranslateLanguages.insert(language)
                }
            }
            
            return cachedChatTranslationState(engine: context.engine, peerId: peerId, threadId: threadId)
            |> mapToSignal { cached in
                let currentTime = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
                if let cached, let timestamp = cached.timestamp, cached.baseLang == baseLang && currentTime - timestamp < 60 * 60 {
                    if !dontTranslateLanguages.contains(cached.fromLang) || forcePredict {
                        return .single(sgEffectiveTranslationState(cached)) // Zenlygram — #60
                    } else {
                        return .single(nil)
                    }
                } else {
                    return .single(nil)
                    |> then(
                        context.account.viewTracker.aroundMessageHistoryViewForLocation(.peer(peerId: peerId, threadId: threadId), index: .upperBound, anchorIndex: .upperBound, count: 32, fixedCombinedReadStates: nil)
                        |> filter { messageHistoryView -> Bool in
                            return messageHistoryView.0.entries.count > 1
                        }
                        |> take(1)
                        |> map { messageHistoryView, _, _ -> ChatTranslationState? in
                            let messages = messageHistoryView.entries.map(\.message)
                            
                            if loggingEnabled {
                                Logger.shared.log("ChatTranslation", "Start language recognizing for \(peerId)")
                            }
                            var fromLangs: [String: Int] = [:]
                            var count = 0
                            for message in messages {
                                if message.effectivelyIncoming(context.account.peerId), message.text.count >= 10 {
                                    if let summaryAttribute = message.attributes.first(where: { $0 is SummarizationMessageAttribute }) as? SummarizationMessageAttribute, !summaryAttribute.fromLang.isEmpty {
                                        let fromLang = normalizeTranslationLanguage(summaryAttribute.fromLang)
                                        if supportedTranslationLanguages.contains(fromLang) {
                                            fromLangs[fromLang] = (fromLangs[fromLang] ?? 0) + message.text.count
                                            count += 1
                                        }
                                    } else {
                                        var text = String(message.text.prefix(256))
                                        if var entities = message.textEntitiesAttribute?.entities.filter({ entity in
                                            switch entity.type {
                                            case .Pre, .Code, .Url, .Email, .Mention, .Hashtag, .BotCommand:
                                                return true
                                            default:
                                                return false
                                            }
                                        }) {
                                            entities = entities.sorted(by: { $0.range.lowerBound > $1.range.lowerBound })
                                            var ranges: [Range<String.Index>] = []
                                            for entity in entities {
                                                if entity.range.lowerBound > text.count || entity.range.upperBound > text.count {
                                                    continue
                                                }
                                                ranges.append(text.index(text.startIndex, offsetBy: entity.range.lowerBound) ..< text.index(text.startIndex, offsetBy: entity.range.upperBound))
                                            }
                                            for range in ranges {
                                                if range.upperBound < text.endIndex {
                                                    text.removeSubrange(range)
                                                }
                                            }
                                        }
                                        
                                        if message.text.count < 10 {
                                            continue
                                        }
                                        
                                        languageRecognizer.processString(text)
                                        let hypotheses = languageRecognizer.languageHypotheses(withMaximum: 4)
                                        languageRecognizer.reset()
                                        
                                        let filteredLanguages = hypotheses.filter { supportedTranslationLanguages.contains(normalizeTranslationLanguage($0.key.rawValue)) }.sorted(by: { $0.value > $1.value })
                                        if let language = filteredLanguages.first {
                                            let fromLang = normalizeTranslationLanguage(language.key.rawValue)
                                            if loggingEnabled && !["en", "ru"].contains(fromLang) && !dontTranslateLanguages.contains(fromLang) {
                                                Logger.shared.log("ChatTranslation", "\(text)")
                                                Logger.shared.log("ChatTranslation", "Recognized as: \(fromLang), other hypotheses: \(hypotheses.map { $0.key.rawValue }.joined(separator: ",")) ")
                                            }
                                            fromLangs[fromLang] = (fromLangs[fromLang] ?? 0) + message.text.count
                                            count += 1
                                        }
                                    }
                                }
                                if count >= 16 {
                                    break
                                }
                            }
                                                        
                            var mostFrequent: (String, Int)?
                            for (lang, count) in fromLangs {
                                if let current = mostFrequent {
                                    if count > current.1 {
                                        mostFrequent = (lang, count)
                                    }
                                } else {
                                    mostFrequent = (lang, count)
                                }
                            }
                            let fromLang = mostFrequent?.0 ?? ""
                            if loggingEnabled {
                                Logger.shared.log("ChatTranslation", "Ended with: \(fromLang)")
                            }
                            
                            let isEnabled: Bool
                            if let currentIsEnabled = cached?.isEnabled {
                                isEnabled = currentIsEnabled
                            } else if autoTranslateEnabled {
                                isEnabled = true
                            } else {
                                isEnabled = false
                            }
                            
                            let state = ChatTranslationState(
                                baseLang: baseLang,
                                fromLang: fromLang,
                                timestamp: currentTime,
                                toLang: cached?.toLang,
                                isEnabled: isEnabled,
                                sgGoogleConsent: cached?.sgGoogleConsent ?? false // Zenlygram — #60
                            )
                            let _ = updateChatTranslationState(engine: context.engine, peerId: peerId, threadId: threadId, state: state).start()
                            if !dontTranslateLanguages.contains(fromLang) || forcePredict {
                                return sgEffectiveTranslationState(state) // Zenlygram — #60: gate only the returned value; the raw state was persisted above
                            } else {
                                return nil
                            }
                        }
                    )
                }
            }
        }
    } else {
        return .single(nil)
    }
}

// MARK: Zenlygram — translation routing (#60/#61): the Service setting is the only decision point.
/// True only when the user picked Google Translate as the translation service. Telegram (default) and System never send text to Google.
public func sgTranslationUsesGoogle() -> Bool {
    return SGSimpleSettings.shared.translationBackendEnum == .gtranslate
}

/// Whether a message's text may be translated at all.
public func sgMayTranslate(peerId: EnginePeer.Id, isCopyProtected: Bool, viaGoogle: Bool) -> Bool {
    if peerId.namespace == Namespaces.Peer.SecretChat {
        return false // E2E text is never translated
    }
    if viaGoogle && isCopyProtected {
        return false // copy-protected text never leaves for Google
    }
    return true
}
