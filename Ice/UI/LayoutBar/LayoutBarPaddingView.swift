//
//  LayoutBarPaddingView.swift
//  Ice
//

import Cocoa
import Combine

/// A Cocoa view that manages the menu bar layout interface.
final class LayoutBarPaddingView: NSView {
    private struct VisibleLayoutSnapshot: Equatable {
        struct Item: Equatable {
            let windowID: CGWindowID
            let info: MenuBarItemInfo
            let ownerPID: pid_t
            let frame: CGRect

            init(_ item: MenuBarItem) {
                self.windowID = item.windowID
                self.info = item.info
                self.ownerPID = item.ownerPID
                self.frame = item.frame.integral
            }
        }

        let items: [Item]

        init(_ items: [MenuBarItem]) {
            self.items = items.map(Item.init)
        }
    }

    private struct ExpectedVisibleLayoutItem {
        let windowID: CGWindowID
        let info: MenuBarItemInfo
        let ownerPID: pid_t
        let hasGenericIdentity: Bool

        init(_ item: MenuBarItem) {
            self.windowID = item.windowID
            self.info = item.info
            self.ownerPID = item.ownerPID
            self.hasGenericIdentity = item.hasGenericIdentity
        }

        func matches(_ item: MenuBarItem) -> Bool {
            if hasGenericIdentity {
                return item.windowID == windowID
            }
            return item.info == info && item.ownerPID == ownerPID
        }
    }

    private let container: LayoutBarContainer

    /// Window IDs for layout moves currently being applied from this layout bar.
    private var movingWindowIDs = Set<CGWindowID>()

    /// Number of physical layout moves currently being applied by any layout bar.
    private static var physicalMoveCount = 0

    /// The date until which drag/drop should be ignored after a layout move.
    private var dragCooldownEndDate: Date?

    /// Whether this layout bar is currently managing a drag session.
    private var isDraggingItem = false

    /// A Boolean value that indicates whether layout dragging is temporarily
    /// cooling down after a physical menu bar move.
    private var isDragCoolingDown: Bool {
        guard let dragCooldownEndDate else {
            return false
        }
        return Date.now < dragCooldownEndDate
    }

    private var isAnyLayoutMoveActive: Bool {
        Self.physicalMoveCount > 0
    }

    /// The visible section is managed by Control Center on newer macOS
    /// versions and often needs an extra beat to settle after a synthetic drag.
    private var initialLayoutConvergenceDelay: Duration {
        switch section.name {
        case .visible: .milliseconds(700)
        case .hidden, .alwaysHidden: .milliseconds(250)
        }
    }

    private var layoutConvergenceRetryDelay: Duration {
        switch section.name {
        case .visible: .milliseconds(350)
        case .hidden, .alwaysHidden: .milliseconds(50)
        }
    }

    private var hiddenPhysicalStepCooldownDelay: Duration {
        .milliseconds(125)
    }

    private var dragCooldownDuration: TimeInterval {
        switch section.name {
        case .visible: 0.35
        case .hidden, .alwaysHidden: 0.05
        }
    }

    private var physicalMoveMaxAttempts: Int {
        switch section.name {
        case .visible: 1
        case .hidden, .alwaysHidden: 1
        }
    }

    /// Whether this layout bar accepts layout drag operations.
    var allowsDragging: Bool {
        didSet {
            if allowsDragging {
                registerForDraggedTypes([.layoutBarItem])
            } else {
                unregisterDraggedTypes()
            }
        }
    }

    /// The section whose items are represented.
    var section: MenuBarSection {
        container.section
    }

    /// The amount of space between each arranged view.
    var spacing: CGFloat {
        get { container.spacing }
        set { container.spacing = newValue }
    }

    /// The layout view's arranged views.
    ///
    /// The views are laid out from left to right in the order that they
    /// appear in the array. The ``spacing`` property determines the amount
    /// of space between each view.
    var arrangedViews: [LayoutBarItemView] {
        get { container.arrangedViews }
        set { container.arrangedViews = newValue }
    }

    /// Creates a layout bar view with the given app state, section, and spacing.
    ///
    /// - Parameters:
    ///   - appState: The shared app state instance.
    ///   - section: The section whose items are represented.
    ///   - spacing: The amount of space between each arranged view.
    init(appState: AppState, section: MenuBarSection, spacing: CGFloat, allowsDragging: Bool) {
        self.container = LayoutBarContainer(appState: appState, section: section, spacing: spacing)
        self.allowsDragging = allowsDragging

        super.init(frame: .zero)
        addSubview(self.container)

        self.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // center the container along the y axis
            container.centerYAnchor.constraint(equalTo: centerYAnchor),

            // give the container a few points of trailing space
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 7.5),

            // allow variable spacing between leading anchors to let the view stretch
            // to fit whatever size is required; container should remain aligned toward
            // the trailing edge; this view is itself nested in a scroll view, so if it
            // has to expand to a larger size, it can be clipped
            leadingAnchor.constraint(lessThanOrEqualTo: container.leadingAnchor, constant: -7.5),
        ])

        if allowsDragging {
            registerForDraggedTypes([.layoutBarItem])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard allowsDragging, !isDragCoolingDown, !isAnyLayoutMoveActive, !container.isSettlingMove else {
            return []
        }
        isDraggingItem = true
        container.canSetArrangedViews = false
        return container.updateArrangedViewsForDrag(with: sender, phase: .entered)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard allowsDragging, !isDragCoolingDown, !isAnyLayoutMoveActive, !container.isSettlingMove else {
            return
        }
        if let sender {
            container.updateArrangedViewsForDrag(with: sender, phase: .exited)
        }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard allowsDragging, !isDragCoolingDown, !isAnyLayoutMoveActive, !container.isSettlingMove else {
            return []
        }
        return container.updateArrangedViewsForDrag(with: sender, phase: .updated)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard allowsDragging else {
            return
        }
        if
            isDraggingItem,
            let draggingSource = sender.draggingSource as? LayoutBarItemView,
            isDragCoolingDown || isAnyLayoutMoveActive || container.isSettlingMove
        {
            restoreOriginalPosition(of: draggingSource)
        }
        container.updateArrangedViewsForDrag(with: sender, phase: .ended)
        if isDraggingItem {
            isDraggingItem = false
            container.canSetArrangedViews = true
        }
        container.dragMoveIntent = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let draggingSource = sender.draggingSource as? LayoutBarItemView else {
            return false
        }
        guard allowsDragging, !isDragCoolingDown, !isAnyLayoutMoveActive, !container.isSettlingMove else {
            rejectDragOperation(from: draggingSource)
            return false
        }
        isDraggingItem = false

        guard let index = arrangedViews.firstIndex(of: draggingSource) else {
            Logger.layoutBar.warning("No layout index for dropped item \(draggingSource.item.logString)")
            restoreOriginalPosition(of: draggingSource)
            return false
        }

        guard let destination = moveDestination(for: draggingSource, at: index) else {
            Logger.layoutBar.warning("No physical move destination for dropped item \(draggingSource.item.logString)")
            restoreOriginalPosition(of: draggingSource)
            return false
        }

        let desiredViews = desiredArrangedViews(for: draggingSource)
        let desiredWindowIDs = uniqueWindowIDs(from: desiredViews.map(\.item.windowID))
        let expectedItems = desiredViews.map { ExpectedVisibleLayoutItem($0.item) }
        move(
            draggingSource,
            to: destination,
            desiredWindowIDs: desiredWindowIDs,
            expectedItems: expectedItems
        )
        return true
    }

    private func rejectDragOperation(from sourceView: LayoutBarItemView) {
        Logger.layoutBar.debug("Restoring rejected drag for \(sourceView.item.logString)")
        restoreOriginalPosition(of: sourceView)
        isDraggingItem = false
        container.canSetArrangedViews = true
        container.dragMoveIntent = nil
    }

    private func moveDestination(
        for sourceView: LayoutBarItemView,
        at index: Int
    ) -> MenuBarItemManager.MoveDestination? {
        if
            section.name == .visible,
            let intent = container.dragMoveIntent,
            intent.sourceView === sourceView,
            intent.destinationView.item.hasUsableMoveDestinationFrame
        {
            if intent.destinationIndex > intent.sourceIndex {
                if
                    let sourceIndex = intent.arrangedViews.firstIndex(of: sourceView),
                    intent.arrangedViews.indices.contains(sourceIndex + 1),
                    let targetItem = intent.arrangedViews[(sourceIndex + 1)...]
                        .first(where: { isUsableMoveTarget($0.item) })?
                        .item
                {
                    return .leftOfItem(targetItem)
                }
                return .rightOfItem(intent.destinationView.item)
            }
            if intent.destinationIndex < intent.sourceIndex {
                return .leftOfItem(intent.destinationView.item)
            }
        }

        if arrangedViews.count == 1 {
            // dragging source is the only view in the layout bar, so we
            // need to find a target item
            let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
            let targetItem: MenuBarItem? = switch section.name {
            case .visible: nil // visible section always has more than 1 item
            case .hidden: items.first { $0.info == .hiddenControlItem }
            case .alwaysHidden: items.first { $0.info == .alwaysHiddenControlItem }
            }
            return targetItem.map { .leftOfItem($0) }
        }

        if arrangedViews.indices.contains(index + 1),
            let targetItem = arrangedViews[(index + 1)...].first(where: { isUsableMoveTarget($0.item) })?.item
        {
            return .leftOfItem(targetItem)
        }

        if arrangedViews.indices.contains(index - 1),
            let targetItem = arrangedViews[..<index].last(where: { isUsableMoveTarget($0.item) })?.item
        {
            return .rightOfItem(targetItem)
        }

        if let boundaryDestination = sectionBoundaryMoveDestination() {
            Logger.layoutBar.debug("Using section boundary as move destination for \(sourceView.item.logString)")
            return boundaryDestination
        }

        Logger.layoutBar.debug("No usable adjacent target for \(sourceView.item.logString)")
        return nil
    }

    private func desiredArrangedViews(for sourceView: LayoutBarItemView) -> [LayoutBarItemView] {
        guard
            section.name == .visible,
            let intent = container.dragMoveIntent,
            intent.sourceView === sourceView
        else {
            return arrangedViews
        }

        return intent.arrangedViews
    }

    private func isUsableMoveTarget(_ item: MenuBarItem) -> Bool {
        switch section.name {
        case .visible:
            item.hasUsableMoveDestinationFrame
        case .hidden, .alwaysHidden:
            item.hasMoveDestinationFrame
        }
    }

    private func uniqueWindowIDs(from windowIDs: [CGWindowID]) -> [CGWindowID] {
        var seen = Set<CGWindowID>()
        return windowIDs.filter { seen.insert($0).inserted }
    }

    private func currentMenuBarItems() -> [MenuBarItem] {
        guard let appState = container.appState else {
            return MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        }

        let sections = appState.menuBarManager.sections
        return MenuBarItem.getMenuBarItems(
            onScreenOnly: false,
            activeSpaceOnly: true,
            controlItemMap: ControlItemDiscovery.buildMap(for: sections),
            axMap: AXMenuBarDiscovery.buildIdentityMap()
        )
    }

    private func sectionBoundaryMoveDestination() -> MenuBarItemManager.MoveDestination? {
        let items = currentMenuBarItems()
        switch section.name {
        case .visible:
            return items.firstIndex(matching: .hiddenControlItem).map { .rightOfItem(items[$0]) }
        case .hidden:
            return items.firstIndex(matching: .hiddenControlItem).map { .leftOfItem(items[$0]) }
        case .alwaysHidden:
            return items.firstIndex(matching: .alwaysHiddenControlItem).map { .leftOfItem(items[$0]) }
        }
    }

    private func restoreOriginalPosition(of sourceView: LayoutBarItemView) {
        guard let (oldContainer, oldIndex) = sourceView.oldContainerInfo else {
            return
        }

        container.shouldAnimateNextLayoutPass = false
        oldContainer.shouldAnimateNextLayoutPass = false

        if let currentIndex = arrangedViews.firstIndex(of: sourceView) {
            arrangedViews.remove(at: currentIndex)
        }

        if let existingIndex = oldContainer.arrangedViews.firstIndex(of: sourceView) {
            if existingIndex != oldIndex {
                oldContainer.arrangedViews.move(
                    fromOffsets: [existingIndex],
                    toOffset: min(oldIndex, oldContainer.arrangedViews.endIndex)
                )
            }
        } else {
            oldContainer.arrangedViews.insert(
                sourceView,
                at: min(oldIndex, oldContainer.arrangedViews.endIndex)
            )
        }
    }

    private func move(
        _ sourceView: LayoutBarItemView,
        to destination: MenuBarItemManager.MoveDestination,
        desiredWindowIDs: [CGWindowID],
        expectedItems: [ExpectedVisibleLayoutItem]
    ) {
        guard let appState = container.appState else {
            return
        }
        let item = sourceView.item

        let targetItem = switch destination {
        case .leftOfItem(let item), .rightOfItem(let item): item
        }
        guard targetItem.windowID != item.windowID else {
            return
        }
        guard !movingWindowIDs.contains(item.windowID) else {
            Logger.layoutBar.debug("Ignoring duplicate move request for \(item.logString)")
            return
        }
        guard !appState.itemManager.isMovingItem else {
            Logger.layoutBar.debug("Ignoring move request for \(item.logString) while another item is moving")
            self.restoreOriginalPosition(of: sourceView)
            return
        }

        movingWindowIDs.insert(item.windowID)
        Self.physicalMoveCount += 1
        if section.name == .visible {
            Logger.layoutBar.debug(
                "Visible move source=\(item.logString) target=\(targetItem.logString)"
            )
        }
        let oldContainer = sourceView.oldContainerInfo?.container
        container.canSetArrangedViews = false
        container.isSettlingMove = true
        oldContainer?.canSetArrangedViews = false
        oldContainer?.isSettlingMove = true

        Task { @MainActor in
            try await Task.sleep(for: .milliseconds(25))
            await self.waitForAppKitDragSessionToEnd(sourceView)
            var didFinishPhysicalMove = false
            @MainActor
            func finishPhysicalMove() {
                guard !didFinishPhysicalMove else {
                    return
                }
                didFinishPhysicalMove = true
                self.movingWindowIDs.remove(item.windowID)
                Self.physicalMoveCount = max(0, Self.physicalMoveCount - 1)
                self.dragCooldownEndDate = Date.now.addingTimeInterval(self.dragCooldownDuration)
                self.container.canSetArrangedViews = true
                oldContainer?.canSetArrangedViews = true
                self.container.setArrangedViews(items: appState.itemManager.itemCache.managedItems(for: self.section.name))
                if let oldContainer {
                    oldContainer.setArrangedViews(items: appState.itemManager.itemCache.managedItems(for: oldContainer.section.name))
                    oldContainer.isSettlingMove = false
                }
                self.container.isSettlingMove = false
                sourceView.oldContainerInfo = nil
            }
            defer {
                finishPhysicalMove()
            }
            if self.section.name == .visible {
                Logger.layoutBar.debug("Applying visible drag move for \(item.logString)")
                do {
                    try await appState.itemManager.moveVisibleItem(
                        item: item,
                        to: destination,
                        maxAttempts: self.physicalMoveMaxAttempts,
                        wakeUpOnFailure: false
                    )
                } catch {
                    Logger.layoutBar.info(
                        "Visible drag move reported an event error; waiting for menu bar state: \(error)"
                    )
                }
                try? await Task.sleep(for: .milliseconds(150))
                await appState.itemManager.cacheItemsRegardless()
                Logger.layoutBar.debug("Visible drag move completed; using actual menu bar order")
                await self.refreshImagesAfterMove(appState: appState, expectedItems: expectedItems)
                return
            }

            await self.moveHiddenItemStepwise(
                appState: appState,
                item: item,
                destination: destination,
                desiredWindowIDs: desiredWindowIDs
            )
            appState.itemManager.removeTempShownItemFromCache(with: item)
            Logger.layoutBar.debug("Layout move completed; using actual menu bar order")
            finishPhysicalMove()
            await self.refreshImagesAfterMove(appState: appState, expectedItems: expectedItems)
        }
    }

    private func waitForAppKitDragSessionToEnd(_ sourceView: LayoutBarItemView) async {
        for _ in 0..<20 {
            guard sourceView.isDraggingSessionActive else {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Logger.layoutBar.debug("Continuing layout move while AppKit drag session is still ending for \(sourceView.item.logString)")
    }

    private func moveHiddenItemUsingBestAvailablePath(
        appState: AppState,
        item: MenuBarItem,
        destination: MenuBarItemManager.MoveDestination
    ) async {
        let targetItem = switch destination {
        case .leftOfItem(let item), .rightOfItem(let item): item
        }

        do {
            if item.hasMoveDestinationFrame, targetItem.hasMoveDestinationFrame {
                Logger.layoutBar.debug("Applying frame-based layout drag move for \(item.logString)")
                try await appState.itemManager.moveVisibleItem(
                    item: item,
                    to: destination,
                    maxAttempts: self.physicalMoveMaxAttempts,
                    wakeUpOnFailure: false,
                    requireMenuBarDestination: false,
                    waitForMouse: false
                )
            } else {
                try await appState.itemManager.move(
                    item: item,
                    to: destination,
                    maxAttempts: self.physicalMoveMaxAttempts,
                    wakeUpOnFailure: false
                )
            }
        } catch {
            Logger.layoutBar.info(
                "Layout move reported an event error; using actual menu bar order: \(error)"
            )
        }
    }

    private func moveHiddenItemStepwise(
        appState: AppState,
        item: MenuBarItem,
        destination: MenuBarItemManager.MoveDestination,
        desiredWindowIDs: [CGWindowID]
    ) async {
        await appState.itemManager.cacheItemsRegardless()

        await moveHiddenItemUsingBestAvailablePath(
            appState: appState,
            item: item,
            destination: destination
        )
        if await cacheHiddenItemsUntilDesiredOrder(
            appState: appState,
            desiredWindowIDs: desiredWindowIDs
        ) {
            Logger.layoutBar.debug("Direct hidden layout move completed for \(item.logString)")
            return
        }
        logHiddenLayoutMismatch(
            appState: appState,
            item: item,
            desiredWindowIDs: desiredWindowIDs,
            reason: "direct move did not match desired order"
        )

        let maxSteps = max(1, min(desiredWindowIDs.count + 1, 8))
        for step in 0..<maxSteps {
            let actualItems = appState.itemManager.itemCache.managedItems(for: section.name)
            let actualRelevantItems = actualItems.filter { desiredWindowIDs.contains($0.windowID) }

            guard
                let actualIndex = actualRelevantItems.firstIndex(where: { $0.windowID == item.windowID }),
                let desiredIndex = desiredWindowIDs.firstIndex(of: item.windowID)
            else {
                Logger.layoutBar.info(
                    "Could not find stepwise layout position for \(item.logString); using actual menu bar order"
                )
                return
            }

            if actualIndex == desiredIndex {
                if step > 0 {
                    Logger.layoutBar.debug("Stepwise layout move completed for \(item.logString) in \(step) step(s)")
                }
                return
            }

            let sourceItem = actualRelevantItems[actualIndex]
            let itemToMove: MenuBarItem
            let destination: MenuBarItemManager.MoveDestination

            if desiredIndex < actualIndex {
                guard actualRelevantItems.indices.contains(actualIndex - 1) else {
                    Logger.layoutBar.info("No left step target for \(item.logString); using actual menu bar order")
                    return
                }
                itemToMove = sourceItem
                destination = .leftOfItem(actualRelevantItems[actualIndex - 1])
            } else {
                guard actualRelevantItems.indices.contains(actualIndex + 1) else {
                    Logger.layoutBar.info("No right step target for \(item.logString); using actual menu bar order")
                    return
                }
                itemToMove = actualRelevantItems[actualIndex + 1]
                destination = .leftOfItem(sourceItem)
            }

            Logger.layoutBar.debug(
                "Applying hidden layout step \(step + 1) for \(itemToMove.logString) to \(destination.logString)"
            )
            await moveHiddenItemUsingBestAvailablePath(
                appState: appState,
                item: itemToMove,
                destination: destination
            )

            let didAdvance = await cacheHiddenItemsUntilStepAdvances(
                appState: appState,
                itemWindowID: sourceItem.windowID,
                desiredWindowIDs: desiredWindowIDs,
                previousIndex: actualIndex
            )
            guard didAdvance else {
                logHiddenLayoutMismatch(
                    appState: appState,
                    item: sourceItem,
                    desiredWindowIDs: desiredWindowIDs,
                    reason: "step \(step + 1) did not advance"
                )
                Logger.layoutBar.info(
                    "Hidden layout step did not advance for \(sourceItem.logString); using actual menu bar order"
                )
                return
            }

            try? await Task.sleep(for: hiddenPhysicalStepCooldownDelay)
        }

        Logger.layoutBar.info("Stepwise layout move reached step limit for \(item.logString); using actual menu bar order")
    }

    private func hiddenLayoutMatchesDesiredOrder(
        appState: AppState,
        desiredWindowIDs: [CGWindowID]
    ) -> Bool {
        let actualWindowIDs = appState.itemManager.itemCache
            .managedItems(for: section.name)
            .map(\.windowID)
        let desiredPresentWindowIDs = desiredWindowIDs.filter { actualWindowIDs.contains($0) }
        let actualRelevantWindowIDs = actualWindowIDs.filter { desiredWindowIDs.contains($0) }
        return !desiredPresentWindowIDs.isEmpty && desiredPresentWindowIDs == actualRelevantWindowIDs
    }

    private func logHiddenLayoutMismatch(
        appState: AppState,
        item: MenuBarItem,
        desiredWindowIDs: [CGWindowID],
        reason: String
    ) {
        let actualItems = appState.itemManager.itemCache.managedItems(for: section.name)
        let actualWindowIDs = actualItems.map(\.windowID)
        let desiredPresentWindowIDs = desiredWindowIDs.filter { actualWindowIDs.contains($0) }
        let actualRelevantItems = actualItems.filter { desiredWindowIDs.contains($0.windowID) }
        let actualRelevantWindowIDs = actualRelevantItems.map(\.windowID)
        let desiredIndex = desiredPresentWindowIDs.firstIndex(of: item.windowID)
        let actualIndex = actualRelevantWindowIDs.firstIndex(of: item.windowID)
        let indexDelta: Int? = if let desiredIndex, let actualIndex {
            actualIndex - desiredIndex
        } else {
            nil
        }

        Logger.layoutBar.debug(
            """
            Hidden layout mismatch (\(reason)) item=\(item.logString) desiredIndex=\(String(describing: desiredIndex)) actualIndex=\(String(describing: actualIndex)) delta=\(String(describing: indexDelta)) desired=\(logString(for: desiredPresentWindowIDs, items: actualItems)) actual=\(actualRelevantItems.map(\.logString).joined(separator: " | "))
            """
        )
    }

    private func logString(for windowIDs: [CGWindowID], items: [MenuBarItem]) -> String {
        windowIDs
            .map { windowID in
                items.first { $0.windowID == windowID }?.logString ?? "#\(windowID)"
            }
            .joined(separator: " | ")
    }

    private func cacheHiddenItemsUntilDesiredOrder(
        appState: AppState,
        desiredWindowIDs: [CGWindowID]
    ) async -> Bool {
        for attempt in 0..<8 {
            if attempt > 0 {
                try? await Task.sleep(for: layoutConvergenceRetryDelay)
            }

            await appState.itemManager.cacheItemsRegardless()

            if hiddenLayoutMatchesDesiredOrder(appState: appState, desiredWindowIDs: desiredWindowIDs) {
                return true
            }
        }

        return false
    }

    private func cacheHiddenItemsUntilStepAdvances(
        appState: AppState,
        itemWindowID: CGWindowID,
        desiredWindowIDs: [CGWindowID],
        previousIndex: Int
    ) async -> Bool {
        for attempt in 0..<4 {
            if attempt > 0 {
                try? await Task.sleep(for: layoutConvergenceRetryDelay)
            }

            await appState.itemManager.cacheItemsRegardless()

            let actualItems = appState.itemManager.itemCache.managedItems(for: section.name)
            let actualRelevantItems = actualItems.filter { desiredWindowIDs.contains($0.windowID) }
            guard let actualIndex = actualRelevantItems.firstIndex(where: { $0.windowID == itemWindowID }) else {
                return false
            }

            if actualIndex != previousIndex {
                return true
            }
        }

        return false
    }

    private func refreshImagesAfterMove(
        appState: AppState,
        expectedItems: [ExpectedVisibleLayoutItem]
    ) async {
        if section.name != .visible {
            await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
        } else {
            await waitForVisibleLayoutToSettle(appState: appState, expectedItems: expectedItems)
            await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
        }
    }

    private func waitForVisibleLayoutToSettle(
        appState: AppState,
        expectedItems: [ExpectedVisibleLayoutItem]
    ) async {
        let startDate = Date.now
        var previousSnapshot: VisibleLayoutSnapshot?

        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(35))
            await appState.itemManager.cacheItemsRegardless()

            let visibleItems = appState.itemManager.itemCache.managedItems(for: .visible)
            let snapshot = VisibleLayoutSnapshot(visibleItems)
            let expectedItemsArePresent = expectedItems.allSatisfy { expectedItem in
                visibleItems.contains { expectedItem.matches($0) }
            }

            if expectedItemsArePresent, snapshot == previousSnapshot {
                let elapsedMilliseconds = Int(Date.now.timeIntervalSince(startDate) * 1000)
                Logger.layoutBar.debug("Visible layout settled after \(elapsedMilliseconds)ms")
                return
            }

            previousSnapshot = snapshot
        }

        Logger.layoutBar.debug("Visible layout settle wait timed out; refreshing images with latest cache")
    }
}
