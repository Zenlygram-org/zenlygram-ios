import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import SGChatLock // SG: Chat Lock

final class HashtagSearchGlobalChatContents: ChatCustomContentsProtocol {
    private final class Impl {
        let queue: Queue
        let context: AccountContext
        
        fileprivate var query: String {
            didSet {
                if self.query != oldValue {
                    self.updateHistoryViewRequest(reload: true)
                }
            }
        }
        private let publicPosts: Bool
        private var currentSearchState: SearchMessagesState?
        
        private(set) var mergedHistoryView: EngineRawMessageHistoryView?
        private var sourceHistoryView: EngineRawMessageHistoryView?

        private var historyViewDisposable: Disposable?
        let historyViewStream = ValuePipe<(EngineRawMessageHistoryView, EngineViewUpdateType)>()
        private var nextUpdateIsHoleFill: Bool = false
        
        var hashtagSearchResultsUpdate: ((SearchMessagesResult, SearchMessagesState)) -> Void = { _ in }
        
        let isSearchingPromise = ValuePromise<Bool>(true)
        
        init(queue: Queue, context: AccountContext, query: String, publicPosts: Bool) {
            self.queue = queue
            self.context = context
            self.query = query
            self.publicPosts = publicPosts
            
            self.updateHistoryViewRequest(reload: false)
        }
        
        deinit {
            self.historyViewDisposable?.dispose()
        }
        
        private func updateHistoryViewRequest(reload: Bool) {
            guard self.historyViewDisposable == nil || reload else {
                return
            }
            self.historyViewDisposable?.dispose()
            
            let search: Signal<(SearchMessagesResult, SearchMessagesState), NoError>
            if self.publicPosts {
                search = self.context.engine.messages.searchHashtagPosts(hashtag: self.query, state: nil)
            } else {
                search = self.context.engine.messages.searchMessages(location: .general(scope: .everywhere, groupId: nil, tags: nil, minDate: nil, maxDate: nil, folderId: nil, communityId: nil), query: self.query, state: nil)
            }
            
            self.isSearchingPromise.set(true)
            self.historyViewDisposable = (search
            |> deliverOn(self.queue)).start(next: { [weak self] result in
                guard let self else {
                    return
                }
                let result = sgChatLockFilteredHashtagResult(result, accountPeerId: self.context.account.peerId) // SG: Chat Lock
                
                let updateType: EngineViewUpdateType = .Initial

                let historyView = EngineRawMessageHistoryView(tag: nil, namespaces: .just(Set([Namespaces.Message.Cloud])), entries: result.0.messages.reversed().map { EngineRawMessageHistoryEntry(message: $0, isRead: false, location: nil, monthLocation: nil, attributes: EngineRawMutableMessageHistoryEntryAttributes(authorIsContact: false)) }, holeEarlier: !result.0.completed, holeLater: false, isLoading: false)
                self.sourceHistoryView = historyView
                self.updateHistoryView(updateType: updateType)
                                
                Queue.mainQueue().async {
                    self.currentSearchState = result.1
                    
                    self.hashtagSearchResultsUpdate(result)
                }
                
                self.historyViewDisposable?.dispose()
                self.historyViewDisposable = nil
                
                self.isSearchingPromise.set(false)
            })
        }
        
        private func updateHistoryView(updateType: EngineViewUpdateType) {
            var entries = self.sourceHistoryView?.entries ?? []
            entries.sort(by: { $0.message.index < $1.message.index })

            let mergedHistoryView = EngineRawMessageHistoryView(tag: nil, namespaces: .just(Set([Namespaces.Message.Cloud])), entries: entries, holeEarlier: self.sourceHistoryView?.holeEarlier ?? false, holeLater: false, isLoading: false)
            self.mergedHistoryView = mergedHistoryView
            
            self.historyViewStream.putNext((mergedHistoryView, updateType))
        }
        
        func loadMore() {
            guard self.historyViewDisposable == nil, let currentSearchState = self.currentSearchState, let sourceHistoryView = self.sourceHistoryView, sourceHistoryView.holeEarlier else {
                return
            }
            
            let search: Signal<(SearchMessagesResult, SearchMessagesState), NoError>
            if self.publicPosts {
                search = self.context.engine.messages.searchHashtagPosts(hashtag: self.query, state: self.currentSearchState)
            } else {
                search = self.context.engine.messages.searchMessages(location: .general(scope: .everywhere, groupId: nil, tags: nil, minDate: nil, maxDate: nil, folderId: nil, communityId: nil), query: self.query, state: currentSearchState)
            }
            
            self.historyViewDisposable?.dispose()
            self.historyViewDisposable = (search
            |> deliverOn(self.queue)).startStrict(next: { [weak self] result in
                guard let self else {
                    return
                }
                let result = sgChatLockFilteredHashtagResult(result, accountPeerId: self.context.account.peerId) // SG: Chat Lock
                
                let updateType: EngineViewUpdateType = .FillHole

                let historyView = EngineRawMessageHistoryView(tag: nil, namespaces: .just(Set([Namespaces.Message.Cloud])), entries: result.0.messages.reversed().map { EngineRawMessageHistoryEntry(message: $0, isRead: false, location: nil, monthLocation: nil, attributes: EngineRawMutableMessageHistoryEntryAttributes(authorIsContact: false)) }, holeEarlier: !result.0.completed, holeLater: false, isLoading: false)
                self.sourceHistoryView = historyView
                                                     
                self.updateHistoryView(updateType: updateType)
                
                Queue.mainQueue().async {
                    self.currentSearchState = result.1
                    
                    self.hashtagSearchResultsUpdate(result)
                }
                
                self.historyViewDisposable?.dispose()
                self.historyViewDisposable = nil
            })
        }
        
        func enqueueMessages(messages: [EnqueueMessage]) {
        }

        func deleteMessages(ids: [EngineMessage.Id]) {
            
        }
        
        func editMessage(id: EngineMessage.Id, text: String, media: RequestEditMessageMedia, entities: TextEntitiesMessageAttribute?, webpagePreviewAttribute: WebpagePreviewMessageAttribute?, disableUrlPreview: Bool) {
        }
    }
    
    var kind: ChatCustomContentsKind

    var historyView: Signal<(EngineRawMessageHistoryView, EngineViewUpdateType), NoError> {
        return self.impl.signalWith({ impl, subscriber in
            if let mergedHistoryView = impl.mergedHistoryView {
                subscriber.putNext((mergedHistoryView, .Initial))
            }
            return impl.historyViewStream.signal().start(next: subscriber.putNext)
        })
    }
    
    var searching: Signal<Bool, NoError> {
        return self.impl.signalWith({ impl, subscriber in
            return impl.isSearchingPromise.get().start(next: subscriber.putNext)
        })
    }
    
    var messageLimit: Int? {
        return nil
    }
    
    private let queue: Queue
    private let impl: QueueLocalObject<Impl>
    
    init(context: AccountContext, query: String, publicPosts: Bool) {
        self.kind = .hashTagSearch(publicPosts: publicPosts)
        
        let queue = Queue()
        self.queue = queue
        self.impl = QueueLocalObject(queue: queue, generate: {
            return Impl(queue: queue, context: context, query: query, publicPosts: publicPosts)
        })
    }
    
    func enqueueMessages(messages: [EnqueueMessage]) {
        
    }

    func deleteMessages(ids: [EngineMessage.Id]) {

    }
    
    func editMessage(id: EngineMessage.Id, text: String, media: RequestEditMessageMedia, entities: TextEntitiesMessageAttribute?, webpagePreviewAttribute: WebpagePreviewMessageAttribute?, disableUrlPreview: Bool) {

    }
    
    func quickReplyUpdateShortcut(value: String) {
        
    }
    
    func businessLinkUpdate(message: String, entities: [TelegramCore.MessageTextEntity], title: String?) {
        
    }
    
    func loadMore() {
        self.impl.with { impl in
            impl.loadMore()
        }
    }
    
    var hashtagSearchResultsUpdate: ((SearchMessagesResult, SearchMessagesState)) -> Void = { _ in } {
        didSet {
            self.impl.with { impl in
                impl.hashtagSearchResultsUpdate = self.hashtagSearchResultsUpdate
            }
        }
    }
    
    func hashtagSearchUpdate(query: String) {
        self.impl.with { impl in
            impl.query = query
        }
    }
}

// SG: Chat Lock — cross-chat hashtag results (chat view, list view, result arrows and count) never include
// locked chats (and, from Batch 3, vaulted ones). Filtering the search result itself covers the initial
// load and every loadMore, since both feed the history view and `hashtagSearchResultsUpdate` from it.
private func sgChatLockFilteredHashtagResult(_ result: (SearchMessagesResult, SearchMessagesState), accountPeerId: EnginePeer.Id) -> (SearchMessagesResult, SearchMessagesState) {
    let messages = result.0.messages.filter { !ChatLockSession.shared.shouldHideContentGlobally(peerId: $0.id.peerId, accountPeerId: accountPeerId) }
    if messages.count == result.0.messages.count {
        return result
    }
    let hiddenCount = Int32(result.0.messages.count - messages.count)
    return (SearchMessagesResult(messages: messages, readStates: result.0.readStates, threadInfo: result.0.threadInfo, totalCount: max(0, result.0.totalCount - hiddenCount), completed: result.0.completed), result.1)
}
