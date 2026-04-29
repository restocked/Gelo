//
//  LayoutBarPaddingView.swift
//  Ice
//

import Cocoa
import Combine

/// A Cocoa view that manages the menu bar layout interface.
final class LayoutBarPaddingView: NSView {
    private let container: LayoutBarContainer

    /// Window IDs for layout moves currently being applied from this layout bar.
    private var movingWindowIDs = Set<CGWindowID>()

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
        guard allowsDragging, !isDragCoolingDown else {
            return []
        }
        isDraggingItem = true
        container.canSetArrangedViews = false
        return container.updateArrangedViewsForDrag(with: sender, phase: .entered)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard allowsDragging, !isDragCoolingDown else {
            return
        }
        if let sender {
            container.updateArrangedViewsForDrag(with: sender, phase: .exited)
        }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard allowsDragging, !isDragCoolingDown else {
            return []
        }
        return container.updateArrangedViewsForDrag(with: sender, phase: .updated)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard allowsDragging else {
            return
        }
        container.updateArrangedViewsForDrag(with: sender, phase: .ended)
        if isDraggingItem {
            isDraggingItem = false
            container.canSetArrangedViews = true
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard allowsDragging, !isDragCoolingDown else {
            return false
        }
        guard let draggingSource = sender.draggingSource as? LayoutBarItemView else {
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

        let desiredWindowIDs = arrangedViews.map(\.item.windowID)
        move(draggingSource, to: destination, desiredWindowIDs: desiredWindowIDs)
        return true
    }

    private func moveDestination(
        for sourceView: LayoutBarItemView,
        at index: Int
    ) -> MenuBarItemManager.MoveDestination? {
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
            let targetItem = arrangedViews[(index + 1)...].first(where: { $0.item.hasMoveDestinationFrame })?.item
        {
            return .leftOfItem(targetItem)
        }

        if arrangedViews.indices.contains(index - 1),
            let targetItem = arrangedViews[..<index].last(where: { $0.item.hasMoveDestinationFrame })?.item
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
        desiredWindowIDs: [CGWindowID]
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
        container.canSetArrangedViews = false
        sourceView.oldContainerInfo?.container.canSetArrangedViews = false

        Task { @MainActor in
            try await Task.sleep(for: .milliseconds(25))
            defer {
                self.movingWindowIDs.remove(item.windowID)
                self.dragCooldownEndDate = Date.now.addingTimeInterval(0.35)
                self.container.canSetArrangedViews = true
                sourceView.oldContainerInfo?.container.canSetArrangedViews = true
                self.container.setArrangedViews(items: appState.itemManager.itemCache.managedItems(for: self.section.name))
                if let oldContainer = sourceView.oldContainerInfo?.container {
                    oldContainer.setArrangedViews(items: appState.itemManager.itemCache.managedItems(for: oldContainer.section.name))
                }
                sourceView.oldContainerInfo = nil
            }
            do {
                try await appState.itemManager.move(
                    item: item,
                    to: destination,
                    maxAttempts: 2,
                    wakeUpOnFailure: false
                )
                appState.itemManager.removeTempShownItemFromCache(with: item)
                let didConverge = await self.convergeLayoutOrder(
                    appState: appState,
                    desiredWindowIDs: desiredWindowIDs,
                    maxCorrections: 2
                )
                if !didConverge {
                    Logger.layoutBar.warning("Layout move did not converge for \(item.logString)")
                }
                await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
            } catch {
                let didConverge = await self.convergeLayoutOrder(
                    appState: appState,
                    desiredWindowIDs: desiredWindowIDs,
                    maxCorrections: 2
                )
                if didConverge {
                    Logger.layoutBar.info("Layout move converged despite move error: \(error)")
                } else {
                    Logger.layoutBar.error("Error moving menu bar item: \(error)")
                    self.restoreOriginalPosition(of: sourceView)
                }
                await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
            }
        }
    }

    private func convergeLayoutOrder(
        appState: AppState,
        desiredWindowIDs: [CGWindowID],
        maxCorrections: Int
    ) async -> Bool {
        try? await Task.sleep(for: .milliseconds(250))
        await appState.itemManager.cacheItemsRegardless()

        for attempt in 0...maxCorrections {
            let actualItems = appState.itemManager.itemCache.managedItems(for: section.name)
            let actualWindowIDs = actualItems.map(\.windowID)
            let desiredPresentWindowIDs = desiredWindowIDs.filter { actualWindowIDs.contains($0) }
            let actualRelevantWindowIDs = actualWindowIDs.filter { desiredWindowIDs.contains($0) }

            guard desiredPresentWindowIDs.count == desiredWindowIDs.count else {
                guard attempt < maxCorrections else {
                    Logger.layoutBar.warning("Some desired items are missing after layout move in \(section.name.logString)")
                    return false
                }
                try? await Task.sleep(for: .milliseconds(200))
                await appState.itemManager.cacheItemsRegardless()
                continue
            }

            if desiredPresentWindowIDs == actualRelevantWindowIDs {
                Logger.layoutBar.debug("Layout order converged for \(section.name.logString)")
                return true
            }

            guard attempt < maxCorrections else {
                Logger.layoutBar.warning("Layout order did not converge for \(section.name.logString)")
                return false
            }

            guard let correction = correctionMove(
                actualItems: actualItems,
                desiredWindowIDs: desiredPresentWindowIDs,
                actualWindowIDs: actualRelevantWindowIDs
            ) else {
                Logger.layoutBar.warning("No correction move available for \(section.name.logString)")
                return false
            }

            Logger.layoutBar.debug(
                "Applying layout correction \(attempt + 1) for \(correction.item.logString) to \(correction.destination.logString)"
            )

            do {
                try await appState.itemManager.move(
                    item: correction.item,
                    to: correction.destination,
                    maxAttempts: 1,
                    wakeUpOnFailure: false
                )
            } catch {
                Logger.layoutBar.debug("Layout correction reported an event error: \(error)")
            }

            try? await Task.sleep(for: .milliseconds(200))
            await appState.itemManager.cacheItemsRegardless()
        }

        return false
    }

    private func correctionMove(
        actualItems: [MenuBarItem],
        desiredWindowIDs: [CGWindowID],
        actualWindowIDs: [CGWindowID]
    ) -> (item: MenuBarItem, destination: MenuBarItemManager.MoveDestination)? {
        guard let mismatchIndex = desiredWindowIDs.indices.first(where: { index in
            actualWindowIDs.indices.contains(index) &&
            actualWindowIDs[index] != desiredWindowIDs[index]
        }) else {
            return nil
        }

        let itemWindowID = desiredWindowIDs[mismatchIndex]
        guard let item = actualItems.first(where: { $0.windowID == itemWindowID }) else {
            return nil
        }

        if
            desiredWindowIDs.indices.contains(mismatchIndex + 1),
            let targetItem = actualItems.first(where: { $0.windowID == desiredWindowIDs[mismatchIndex + 1] }),
            targetItem.windowID != item.windowID
        {
            return (item, .leftOfItem(targetItem))
        }

        if
            desiredWindowIDs.indices.contains(mismatchIndex - 1),
            let targetItem = actualItems.first(where: { $0.windowID == desiredWindowIDs[mismatchIndex - 1] }),
            targetItem.windowID != item.windowID
        {
            return (item, .rightOfItem(targetItem))
        }

        return nil
    }
}

// MARK: - Logger
private extension Logger {
    static let layoutBar = Logger(category: "LayoutBar")
}
