import Foundation
import UIKit
import UIKit.UIGestureRecognizerSubclass
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import ContactsPeerItem
import AccountContext

// MARK: Zenlygram — Contacts ▸ Select: drag one finger down (or up) the checkbox column to check or
// uncheck every row it passes, as in the Messages app. Deleting many contacts used to mean tapping
// each row.
//
// - The drag starts only on the checkbox / avatar column of a row a tap could select, so a drag on
//   the rest of the row still scrolls the list. A tap in the column still toggles the one row.
// - The first row decides the direction: from an unchecked row the drag checks, from a checked row
//   it unchecks. Every row between the first row and the finger gets that state, and a row that
//   falls out of that range gets its own state back, so dragging back undoes.
// - Holding the finger near the top or bottom edge scrolls the list and keeps selecting.

/// A one-finger pan that fails at once unless `shouldBegin` accepts the touch point, and recognizes
/// only after a few points of movement. The list's scroll pan waits for it to fail, so a drag that
/// starts in the column selects instead of scrolling, while one that starts anywhere else scrolls
/// as before (it fails on touch down, so the scroll pan does not wait).
final class ContactListPanSelectionRecognizer: UIPanGestureRecognizer {
    private let activationThreshold: CGFloat = 6.0

    var shouldBegin: ((CGPoint) -> Bool)?

    /// Where the finger went down, in the view's coordinates.
    private(set) var initialLocation = CGPoint()
    private var movedEnough = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)

        self.minimumNumberOfTouches = 1
        self.maximumNumberOfTouches = 1
    }

    override func reset() {
        super.reset()

        self.movedEnough = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if self.state == .possible && self.numberOfTouches == 0 {
            guard touches.count == 1, let touch = touches.first else {
                self.state = .failed
                return
            }
            let location = touch.location(in: self.view)
            if let shouldBegin = self.shouldBegin, !shouldBegin(location) {
                self.state = .failed
                return
            }
            self.initialLocation = location
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if !self.movedEnough, let touch = touches.first {
            let location = touch.location(in: self.view)
            let dx = location.x - self.initialLocation.x
            let dy = location.y - self.initialLocation.y
            if dx * dx + dy * dy < self.activationThreshold * self.activationThreshold {
                return
            }
            self.movedEnough = true
        }
        super.touchesMoved(touches, with: event)
    }
}

final class ContactListPanSelection: NSObject {
    private weak var contactListNode: ContactListNode?

    /// How far past the leading safe-area edge the drag may start: the checkbox and the avatar.
    private let columnWidth: CGFloat = 100.0
    private let scrollingAreaHeight: CGFloat = 50.0

    private struct Row {
        var index: Int
        var peer: EnginePeer
    }

    private struct State {
        /// true: the drag checks rows; false: it unchecks them.
        var selecting: Bool
        var initialPeerId: EnginePeer.Id
        var initialIndex: Int
        var currentIndex: Int
        /// The rows checked when the drag began, to give back to rows that leave its range.
        var initiallySelected: Set<ContactListPeerId>
        /// The rows a tap could select when the drag began.
        var selectablePeerIds: Set<EnginePeer.Id>
        /// Every row the drag's range has covered, with its last known list index. A row that has
        /// scrolled far enough away loses its node, so its place is remembered here: a long drag
        /// with the list scrolling under it must keep the rows it left behind.
        var coveredRows: [EnginePeer.Id: Row]
    }
    private var state: State?

    /// The selectable rows as `shouldBegin` saw them, for the drag that may follow.
    private var pendingSelectablePeerIds: Set<EnginePeer.Id>?

    private var lastLocation: CGPoint?
    private var scrollDelta: CGFloat?
    private var scrollActivationTimer: SwiftSignalKit.Timer?
    private var scrollDisplayLink: ConstantDisplayLinkAnimator?
    private var scrollSkipUpdate = false
    private let hapticFeedback = HapticFeedback()

    init(contactListNode: ContactListNode) {
        self.contactListNode = contactListNode

        super.init()

        let recognizer = ContactListPanSelectionRecognizer(target: self, action: #selector(self.panGesture(_:)))
        recognizer.shouldBegin = { [weak self] point in
            return self?.canBegin(at: point) ?? false
        }
        contactListNode.listNode.view.addGestureRecognizer(recognizer)
        contactListNode.listNode.scroller.panGestureRecognizer.require(toFail: recognizer)
    }

    deinit {
        self.scrollActivationTimer?.invalidate()
        self.scrollDisplayLink?.invalidate()
    }

    private func canBegin(at point: CGPoint) -> Bool {
        self.pendingSelectablePeerIds = nil
        guard let contactListNode = self.contactListNode, contactListNode.isPanSelectionEnabled, contactListNode.selectionState != nil else {
            return false
        }
        // ContactsPeerItem draws the checkbox on the left in every language (x = safe inset + 17).
        if point.x > contactListNode.listNode.insets.left + self.columnWidth {
            return false
        }
        guard let row = self.row(at: point) else {
            return false
        }
        let selectablePeerIds = Set(contactListNode.selectableDisplayedPeers.map(\.id))
        if !selectablePeerIds.contains(row.peer.id) {
            return false
        }
        self.pendingSelectablePeerIds = selectablePeerIds
        return true
    }

    /// The contact row under `point` (in the list's coordinates).
    private func row(at point: CGPoint) -> Row? {
        guard let listNode = self.contactListNode?.listNode else {
            return nil
        }
        var result: Row?
        listNode.forEachItemNode { itemNode in
            guard result == nil, let itemNode = itemNode as? ContactsPeerItemNode, itemNode.frame.minY <= point.y, point.y < itemNode.frame.maxY else {
                return
            }
            if let index = itemNode.index, let item = itemNode.item, case let .peer(peer, _) = item.peer, let peer {
                result = Row(index: index, peer: peer)
            }
        }
        return result
    }

    /// The contact rows the list has nodes for.
    private func loadedRows() -> [Row] {
        guard let listNode = self.contactListNode?.listNode else {
            return []
        }
        var rows: [Row] = []
        listNode.forEachItemNode { itemNode in
            guard let itemNode = itemNode as? ContactsPeerItemNode, let index = itemNode.index, let item = itemNode.item, case let .peer(peer, _) = item.peer, let peer else {
                return
            }
            rows.append(Row(index: index, peer: peer))
        }
        return rows
    }

    @objc private func panGesture(_ recognizer: ContactListPanSelectionRecognizer) {
        guard let contactListNode = self.contactListNode else {
            return
        }
        let location = recognizer.location(in: contactListNode.listNode.view)
        switch recognizer.state {
        case .began:
            guard let selectionState = contactListNode.selectionState, let selectablePeerIds = self.pendingSelectablePeerIds, let row = self.row(at: recognizer.initialLocation), selectablePeerIds.contains(row.peer.id) else {
                return
            }
            let initiallySelected = Set(selectionState.selectedPeerIndices.keys)
            self.state = State(
                selecting: !initiallySelected.contains(.peer(row.peer.id)),
                initialPeerId: row.peer.id,
                initialIndex: row.index,
                currentIndex: row.index,
                initiallySelected: initiallySelected,
                selectablePeerIds: selectablePeerIds,
                coveredRows: [:]
            )
            self.applyRange()
            self.lastLocation = location
            self.handle(location: location)
        case .changed:
            self.lastLocation = location
            self.handle(location: location)
        case .ended, .cancelled, .failed:
            self.state = nil
            self.pendingSelectablePeerIds = nil
            self.lastLocation = nil
            self.scrollDelta = nil
            self.scrollDisplayLink?.invalidate()
            self.scrollDisplayLink = nil
            self.scrollActivationTimer?.invalidate()
            self.scrollActivationTimer = nil
            self.scrollSkipUpdate = false
        default:
            break
        }
    }

    private func handle(location: CGPoint) {
        guard let listNode = self.contactListNode?.listNode, var state = self.state else {
            return
        }
        let insets = listNode.insets
        let height = listNode.bounds.height

        var clampedLocation = location
        clampedLocation.y = max(insets.top + 5.0, min(height - insets.bottom - 5.0, clampedLocation.y))
        if let row = self.row(at: clampedLocation), row.index != state.currentIndex {
            state.currentIndex = row.index
            self.state = state
            self.applyRange()
        }

        if location.y < self.scrollingAreaHeight + insets.top || location.y > height - self.scrollingAreaHeight - insets.bottom {
            if location.y < height / 2.0 {
                self.scrollDelta = (self.scrollingAreaHeight - (location.y - insets.top)) / self.scrollingAreaHeight
            } else {
                self.scrollDelta = -(self.scrollingAreaHeight - min(self.scrollingAreaHeight, max(0.0, height - insets.bottom - location.y))) / self.scrollingAreaHeight
            }
            if let displayLink = self.scrollDisplayLink {
                displayLink.isPaused = false
            } else if self.scrollActivationTimer == nil {
                let timer = SwiftSignalKit.Timer(timeout: 0.45, repeat: false, completion: { [weak self] in
                    self?.startScrolling()
                }, queue: .mainQueue())
                timer.start()
                self.scrollActivationTimer = timer
            }
        } else {
            self.scrollDisplayLink?.isPaused = true
            self.scrollActivationTimer?.invalidate()
            self.scrollActivationTimer = nil
        }
    }

    private func startScrolling() {
        self.scrollActivationTimer = nil
        guard self.state != nil else {
            return
        }
        self.scrollDisplayLink = ConstantDisplayLinkAnimator(update: { [weak self] in
            guard let self, let delta = self.scrollDelta, let listView = self.contactListNode?.listNode as? ListViewImpl else {
                return
            }
            let distance: CGFloat = 15.0 * min(1.0, 0.15 + abs(delta * delta))
            let _ = listView.scrollWithDirection(delta > 0.0 ? .up : .down, distance: distance)
            if let location = self.lastLocation {
                if !self.scrollSkipUpdate {
                    self.handle(location: location)
                }
                self.scrollSkipUpdate = !self.scrollSkipUpdate
            }
        })
        self.scrollDisplayLink?.isPaused = false
    }

    /// Gives every selectable row between the first row and the finger the drag's state, and every
    /// other row the drag has covered the state it had before the drag.
    private func applyRange() {
        guard let contactListNode = self.contactListNode, var state = self.state else {
            return
        }
        let rows = self.loadedRows()
        // The list can change under the drag (a sync); follow the first row if it is still loaded.
        if let initialRow = rows.first(where: { $0.peer.id == state.initialPeerId }) {
            state.initialIndex = initialRow.index
        }
        let range = min(state.initialIndex, state.currentIndex) ... max(state.initialIndex, state.currentIndex)
        for row in rows where state.selectablePeerIds.contains(row.peer.id) {
            if range.contains(row.index) || state.coveredRows[row.peer.id] != nil {
                state.coveredRows[row.peer.id] = row
            }
        }
        self.state = state

        var toSelect: [Row] = []
        var toDeselect: [Row] = []
        for (peerId, row) in state.coveredRows {
            let wanted = range.contains(row.index) ? state.selecting : state.initiallySelected.contains(.peer(peerId))
            if wanted {
                toSelect.append(row)
            } else {
                toDeselect.append(row)
            }
        }
        // Checked in the order the finger reached them, which is the order the selection keeps.
        let initialIndex = state.initialIndex
        toSelect.sort { abs($0.index - initialIndex) < abs($1.index - initialIndex) }

        var changed = false
        contactListNode.updateSelectionState { current in
            guard let current else {
                return nil
            }
            var selectedPeerMap = current.selectedPeerMap
            var selectIds: [ContactListPeerId] = []
            for row in toSelect where current.selectedPeerIndices[.peer(row.peer.id)] == nil {
                selectIds.append(.peer(row.peer.id))
                selectedPeerMap[.peer(row.peer.id)] = .peer(peer: row.peer, isGlobal: false, participantCount: nil)
            }
            var deselectIds: [ContactListPeerId] = []
            for row in toDeselect where current.selectedPeerIndices[.peer(row.peer.id)] != nil {
                deselectIds.append(.peer(row.peer.id))
                selectedPeerMap.removeValue(forKey: .peer(row.peer.id))
            }
            if selectIds.isEmpty && deselectIds.isEmpty {
                return current
            }
            changed = true
            return current.withPeerIds(selectIds, selected: true).withPeerIds(deselectIds, selected: false).withSelectedPeerMap(selectedPeerMap)
        }
        if changed {
            self.hapticFeedback.tap()
        }
    }
}
