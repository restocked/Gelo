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

        var logString: String {
            if hasGenericIdentity {
                return "\(info)#\(windowID)|pid=\(ownerPID)"
            }
            return "\(info)|pid=\(ownerPID)"
        }

        func matches(_ item: MenuBarItem) -> Bool {
            if hasGenericIdentity {
                return item.windowID == windowID
            }
            return item.info == info && item.ownerPID == ownerPID
        }
    }

    private struct VisualHealthMetrics {
        let width: Int
        let height: Int
        let alphaCoverage: Double
        let meanLuma: Double
        let lumaStandardDeviation: Double

        var logString: String {
            "size=\(width)x\(height) " +
            "alpha=\(String(format: "%.2f", alphaCoverage)) " +
            "luma=\(String(format: "%.1f", meanLuma)) " +
            "stdev=\(String(format: "%.1f", lumaStandardDeviation))"
        }
    }

    private struct MovedItemMatch {
        let item: MenuBarItem
        let method: String
    }

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
        case .hidden, .alwaysHidden: .milliseconds(200)
        }
    }

    private var maxLayoutCorrections: Int {
        switch section.name {
        case .visible: 0
        case .hidden, .alwaysHidden: 2
        }
    }

    private var physicalMoveMaxAttempts: Int {
        switch section.name {
        case .visible: 1
        case .hidden, .alwaysHidden: 2
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
        guard allowsDragging, !isDragCoolingDown, !container.isSettlingMove else {
            return []
        }
        isDraggingItem = true
        container.canSetArrangedViews = false
        return container.updateArrangedViewsForDrag(with: sender, phase: .entered)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard allowsDragging, !isDragCoolingDown, !container.isSettlingMove else {
            return
        }
        if let sender {
            container.updateArrangedViewsForDrag(with: sender, phase: .exited)
        }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard allowsDragging, !isDragCoolingDown, !container.isSettlingMove else {
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
        container.dragMoveIntent = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard allowsDragging, !isDragCoolingDown, !container.isSettlingMove else {
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

    private func isUsableCorrectionTarget(_ item: MenuBarItem) -> Bool {
        guard isUsableMoveTarget(item) else {
            return false
        }

        // Visible-section correction should not use Gelo's own boundary items
        // as normal anchors; they can be transient while sections are being
        // shown or hidden. Direct drops can still use them when needed.
        if section.name == .visible, item.info.namespace == .ice {
            return false
        }

        return true
    }

    private func isUsableCorrectionSource(_ item: MenuBarItem) -> Bool {
        guard item.isMovable, isUsableMoveTarget(item) else {
            return false
        }

        // Gelo's own section boundary/control items are anchors for the layout
        // algorithm, not user items that correction should shuffle around.
        if section.name == .visible, item.info.namespace == .ice {
            return false
        }

        return true
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
        var preMoveImage: CGImage?
        if section.name == .visible {
            let debugWindowIDs = uniqueWindowIDs(from: [item.windowID, targetItem.windowID])
            appState.imageCache.setLayoutDebugWindowIDs(debugWindowIDs)
            Logger.layoutBar.debug(
                "Visible move debug source=\(item.logString) target=\(targetItem.logString) expected=\(expectedItems.map(\.logString).joined(separator: " | "))"
            )
            let visualSnapshots = container.freezeCurrentImages()
            preMoveImage = visualSnapshots.first { $0.item.windowID == item.windowID }?.image
            appState.imageCache.retainVisualImages(visualSnapshots)
        }
        container.canSetArrangedViews = false
        if section.name == .visible {
            container.isSettlingMove = true
        }
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
                self.container.isSettlingMove = false
                sourceView.oldContainerInfo = nil
                appState.imageCache.clearLayoutDebugWindowIDs()
            }
            do {
                if self.section.name == .visible {
                    Logger.layoutBar.debug("Applying direct visible move for dragged item \(item.logString)")
                    do {
                        try await appState.itemManager.moveVisibleItem(
                            item: item,
                            to: destination,
                            maxAttempts: self.physicalMoveMaxAttempts,
                            wakeUpOnFailure: false
                        )
                    } catch {
                        Logger.layoutBar.info(
                            "Visible direct move reported an event error; waiting for menu bar state: \(error)"
                        )
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                    await appState.itemManager.cacheItemsRegardless()
                    Logger.layoutBar.debug("Visible direct move completed; using actual menu bar order")
                    await self.refreshImagesAfterMove(appState: appState, expectedItems: expectedItems)
                    self.logPostMoveHealth(
                        appState: appState,
                        originalItem: item,
                        preMoveImage: preMoveImage,
                        desiredWindowIDs: desiredWindowIDs
                    )
                    return
                }

                try await appState.itemManager.move(
                    item: item,
                    to: destination,
                    maxAttempts: self.physicalMoveMaxAttempts,
                    wakeUpOnFailure: false
                )
                appState.itemManager.removeTempShownItemFromCache(with: item)
                let didConverge = await self.convergeLayoutOrder(
                    appState: appState,
                    desiredWindowIDs: desiredWindowIDs,
                    maxCorrections: self.maxLayoutCorrections
                )
                if !didConverge {
                    if self.section.name == .visible {
                        Logger.layoutBar.info(
                            "Visible layout move did not converge immediately for \(item.logString); using actual menu bar order"
                        )
                    } else {
                        Logger.layoutBar.warning("Layout move did not converge for \(item.logString)")
                    }
                }
                await self.refreshImagesAfterMove(appState: appState, expectedItems: expectedItems)
            } catch {
                if self.section.name == .visible {
                    Logger.layoutBar.info("Visible layout move reported an event error: \(error)")
                    await self.refreshImagesAfterMove(appState: appState, expectedItems: expectedItems)
                    return
                }

                let didConverge = await self.convergeLayoutOrder(
                    appState: appState,
                    desiredWindowIDs: desiredWindowIDs,
                    maxCorrections: self.maxLayoutCorrections
                )
                if didConverge {
                    Logger.layoutBar.info("Layout move converged despite move error: \(error)")
                } else if self.section.name == .visible {
                    Logger.layoutBar.info(
                        "Visible layout move reported an event error before convergence; using actual menu bar order: \(error)"
                    )
                } else {
                    Logger.layoutBar.error("Error moving menu bar item: \(error)")
                    self.restoreOriginalPosition(of: sourceView)
                }
                await self.refreshImagesAfterMove(appState: appState, expectedItems: expectedItems)
            }
        }
    }

    private func logPostMoveHealth(
        appState: AppState,
        originalItem: MenuBarItem,
        preMoveImage: CGImage?,
        desiredWindowIDs: [CGWindowID]
    ) {
        guard section.name == .visible else {
            return
        }

        guard
            let match = movedItemMatch(
                appState: appState,
                originalItem: originalItem,
                desiredWindowIDs: desiredWindowIDs
            )
        else {
            Logger.layoutBar.info(
                "Post-move health source=\(originalItem.logString) status=missing match=none"
            )
            return
        }

        let postImage = appState.imageCache.windowImages[match.item.windowID] ??
            (!match.item.hasGenericIdentity ? appState.imageCache.images[match.item.info] : nil)
        guard let postImage else {
            Logger.layoutBar.info(
                "Post-move health source=\(originalItem.logString) matched=\(match.item.logString) match=\(match.method) status=missing-image"
            )
            return
        }

        let preMetrics = preMoveImage.flatMap(visualHealthMetrics)
        guard let postMetrics = visualHealthMetrics(for: postImage) else {
            Logger.layoutBar.info(
                "Post-move health source=\(originalItem.logString) matched=\(match.item.logString) match=\(match.method) status=unreadable-image"
            )
            return
        }

        let status = postMoveHealthStatus(preMetrics: preMetrics, postMetrics: postMetrics)
        let preLog = preMetrics.map { " pre=[\($0.logString)]" } ?? " pre=missing"
        Logger.layoutBar.info(
            "Post-move health source=\(originalItem.logString) matched=\(match.item.logString) match=\(match.method) status=\(status) post=[\(postMetrics.logString)]\(preLog)"
        )
    }

    private func movedItemMatch(
        appState: AppState,
        originalItem: MenuBarItem,
        desiredWindowIDs: [CGWindowID]
    ) -> MovedItemMatch? {
        let visibleItems = appState.itemManager.itemCache.managedItems(for: .visible)
        if let exact = visibleItems.first(where: { $0.windowID == originalItem.windowID }) {
            return MovedItemMatch(item: exact, method: "windowID")
        }

        if !originalItem.hasGenericIdentity,
            let stable = visibleItems.first(where: {
                $0.info == originalItem.info && $0.ownerPID == originalItem.ownerPID
            })
        {
            return MovedItemMatch(item: stable, method: "stable-info")
        }

        let genericCandidates = visibleItems.filter {
            $0.info == originalItem.info &&
            $0.ownerPID == originalItem.ownerPID &&
            abs($0.frame.width - originalItem.frame.width) <= 8
        }
        if genericCandidates.count == 1, let candidate = genericCandidates.first {
            return MovedItemMatch(item: candidate, method: "generic-size")
        }

        let actualWindowIDs = visibleItems.map(\.windowID)
        let relevantItems = visibleItems.filter { desiredWindowIDs.contains($0.windowID) }
        let relevantDesiredWindowIDs = desiredWindowIDs.filter { actualWindowIDs.contains($0) }
        if
            let desiredIndex = relevantDesiredWindowIDs.firstIndex(of: originalItem.windowID),
            relevantItems.indices.contains(desiredIndex)
        {
            return MovedItemMatch(
                item: relevantItems[desiredIndex],
                method: "expected-index candidates=\(genericCandidates.count)"
            )
        }

        return nil
    }

    private func postMoveHealthStatus(
        preMetrics: VisualHealthMetrics?,
        postMetrics: VisualHealthMetrics
    ) -> String {
        if let preMetrics, preMetrics.alphaCoverage > 0.03 {
            let alphaRatio = postMetrics.alphaCoverage / preMetrics.alphaCoverage
            if alphaRatio < 0.35 {
                return "blank-alpha-drop"
            }
            if alphaRatio < 0.70 {
                return "degraded-alpha"
            }
        } else if postMetrics.alphaCoverage < 0.02 {
            return "blank-alpha"
        }

        // Menu bar template images are often pure black alpha masks, so luma
        // variance is only useful for non-template images.
        if
            let preMetrics,
            preMetrics.lumaStandardDeviation > 4,
            postMetrics.lumaStandardDeviation < preMetrics.lumaStandardDeviation * 0.35
        {
            return "degraded-detail"
        }
        return "healthy"
    }

    private func visualHealthMetrics(for image: CGImage) -> VisualHealthMetrics? {
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue

        let didDraw = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let context = CGContext(
                    data: bytes.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else {
            return nil
        }

        var lumas = [Double]()
        lumas.reserveCapacity(width * height)
        var visiblePixelCount = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.03 else {
                continue
            }
            visiblePixelCount += 1
            let red = Double(pixels[index])
            let green = Double(pixels[index + 1])
            let blue = Double(pixels[index + 2])
            lumas.append((0.2126 * red) + (0.7152 * green) + (0.0722 * blue))
        }

        guard !lumas.isEmpty else {
            return VisualHealthMetrics(
                width: image.width,
                height: image.height,
                alphaCoverage: 0,
                meanLuma: 0,
                lumaStandardDeviation: 0
            )
        }

        let mean = lumas.reduce(0, +) / Double(lumas.count)
        let variance = lumas.reduce(0) { partialResult, luma in
            let difference = luma - mean
            return partialResult + (difference * difference)
        } / Double(lumas.count)

        return VisualHealthMetrics(
            width: image.width,
            height: image.height,
            alphaCoverage: Double(visiblePixelCount) / Double(width * height),
            meanLuma: mean,
            lumaStandardDeviation: sqrt(variance)
        )
    }

    private func refreshImagesAfterMove(
        appState: AppState,
        expectedItems: [ExpectedVisibleLayoutItem]
    ) async {
        if section.name != .visible {
            await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
            try? await Task.sleep(for: .milliseconds(700))
            await appState.itemManager.cacheItemsRegardless()
        } else {
            await waitForVisibleLayoutToSettle(appState: appState, expectedItems: expectedItems)
        }
        await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
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

    private func convergeLayoutOrder(
        appState: AppState,
        desiredWindowIDs: [CGWindowID],
        maxCorrections: Int
    ) async -> Bool {
        try? await Task.sleep(for: initialLayoutConvergenceDelay)
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
                try? await Task.sleep(for: layoutConvergenceRetryDelay)
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

            try? await Task.sleep(for: layoutConvergenceRetryDelay)
            await appState.itemManager.cacheItemsRegardless()
        }

        return false
    }

    private func correctionMove(
        actualItems: [MenuBarItem],
        desiredWindowIDs: [CGWindowID],
        actualWindowIDs: [CGWindowID]
    ) -> (item: MenuBarItem, destination: MenuBarItemManager.MoveDestination)? {
        let mismatchIndices = desiredWindowIDs.indices.filter { index in
            actualWindowIDs.indices.contains(index) &&
            actualWindowIDs[index] != desiredWindowIDs[index]
        }

        for mismatchIndex in mismatchIndices {
            let itemWindowID = desiredWindowIDs[mismatchIndex]
            guard
                let item = actualItems.first(where: { $0.windowID == itemWindowID }),
                isUsableCorrectionSource(item)
            else {
                continue
            }

            if
                desiredWindowIDs.indices.contains(mismatchIndex + 1),
                let targetItem = actualItems.first(where: {
                    $0.windowID == desiredWindowIDs[mismatchIndex + 1] &&
                    isUsableCorrectionTarget($0)
                }),
                targetItem.windowID != item.windowID
            {
                return (item, .leftOfItem(targetItem))
            }

            if
                desiredWindowIDs.indices.contains(mismatchIndex - 1),
                let targetItem = actualItems.first(where: {
                    $0.windowID == desiredWindowIDs[mismatchIndex - 1] &&
                    isUsableCorrectionTarget($0)
                }),
                targetItem.windowID != item.windowID
            {
                return (item, .rightOfItem(targetItem))
            }
        }

        return nil
    }
}
