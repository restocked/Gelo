//
//  MenuBarItemImageCache.swift
//  Ice
//

import Cocoa
import Combine

/// Cache for menu bar item images.
final class MenuBarItemImageCache: ObservableObject {
    /// Captured menu bar item images keyed by both stable item identity and
    /// current window identity.
    private struct CapturedImages {
        var imagesByInfo = [MenuBarItemInfo: CGImage]()
        var imagesByWindowID = [CGWindowID: CGImage]()
    }

    /// A key for the last good image rendered for a layout item.
    private enum VisualImageKey: Hashable {
        case identified(info: MenuBarItemInfo, ownerPID: pid_t)
        case generic(info: MenuBarItemInfo, ownerPID: pid_t, widthBucket: Int, heightBucket: Int)
    }

    /// A recently captured image that can be reused while macOS recreates a
    /// status item window after a move.
    private struct RetainedVisualImage {
        let image: CGImage
        let capturedAt: Date
    }

    /// The cached item images.
    @Published private(set) var images = [MenuBarItemInfo: CGImage]()

    /// The cached item images keyed by their current window IDs.
    ///
    /// On macOS 26, multiple menu bar windows can share the same app/title
    /// identity, so UI rendering must prefer this cache to avoid reusing one
    /// captured image for several distinct windows.
    @Published private(set) var windowImages = [CGWindowID: CGImage]()

    /// A monotonically increasing value that notifies views when visual fallback
    /// images are updated.
    @Published private(set) var visualImagesRevision = 0

    /// The screen of the cached item images.
    private(set) var screen: NSScreen?

    /// The height of the menu bar of the cached item images.
    private(set) var menuBarHeight: CGFloat?

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Recently captured images keyed by stable visual identity.
    private var visualImages = [VisualImageKey: RetainedVisualImage]()

    /// Runtime window IDs to include in short-lived layout debug logs.
    private var layoutDebugWindowIDs = Set<CGWindowID>()

    /// The amount of time to retain visual fallbacks for recreated item windows.
    private let visualImageRetentionInterval: TimeInterval = 10

    /// Creates a cache with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Sets up the cache.
    @MainActor
    func performSetup() {
        configureCancellables()
    }

    /// Configures the internal observers for the cache.
    @MainActor
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            Publishers.Merge3(
                // Update every 3 seconds at minimum.
                Timer.publish(every: 3, on: .main, in: .default).autoconnect().mapToVoid(),

                // Update when the active space or screen parameters change.
                Publishers.Merge(
                    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                )
                .mapToVoid(),

                // Update when the average menu bar color or cached items change.
                Publishers.Merge(
                    appState.menuBarManager.$averageColorInfo.removeDuplicates().mapToVoid(),
                    appState.itemManager.$itemCache.removeDuplicates().mapToVoid()
                )
            )
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                Task.detached {
                    if ScreenCapture.cachedCheckPermissions() {
                        await self.updateCache()
                    }
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    /// Logs a reason for skipping the cache.
    private func logSkippingCache(reason _: String) {
        // Normal state changes can trigger many skipped refreshes. Keep this
        // quiet so targeted identity diagnostics remain readable.
    }

    /// Returns the best currently available image for a menu bar item.
    func image(
        for item: MenuBarItem,
        windowImages: [CGWindowID: CGImage],
        images: [MenuBarItemInfo: CGImage]
    ) -> CGImage? {
        if let image = windowImages[item.windowID] {
            logImageLookup(item: item, source: "windowID", image: image)
            return image
        }
        if !item.hasGenericIdentity, let image = images[item.info] {
            logImageLookup(item: item, source: "stable info", image: image)
            return image
        }
        guard
            let visualImageKey = visualImageKey(for: item),
            let retainedImage = visualImages[visualImageKey]
        else {
            return nil
        }
        return retainedImage.image
    }

    /// Retains images that are already rendered in the layout UI. This keeps
    /// third-party status items visible while macOS recreates their backing
    /// windows during a menu bar reorder.
    func retainVisualImages(_ snapshots: [(item: MenuBarItem, image: CGImage)]) {
        guard !snapshots.isEmpty else {
            return
        }

        let now = Date()
        var didUpdate = false
        for snapshot in snapshots {
            guard
                snapshot.image.width > 0,
                snapshot.image.height > 0,
                let key = visualImageKey(for: snapshot.item)
            else {
                continue
            }
            visualImages[key] = RetainedVisualImage(
                image: snapshot.image,
                capturedAt: now
            )
            didUpdate = true
        }

        if didUpdate {
            visualImagesRevision += 1
        }
    }

    func setLayoutDebugWindowIDs(_ windowIDs: [CGWindowID]) {
        layoutDebugWindowIDs = Set(windowIDs)
    }

    func clearLayoutDebugWindowIDs() {
        layoutDebugWindowIDs.removeAll()
    }

    /// Returns a Boolean value that indicates whether caching menu bar items failed for
    /// the given section.
    @MainActor
    func cacheFailed(for section: MenuBarSection.Name) -> Bool {
        guard ScreenCapture.cachedCheckPermissions() else {
            return true
        }
        let items = appState?.itemManager.itemCache[section] ?? []
        guard !items.isEmpty else {
            return false
        }
        let imageWindowIDs = Set(windowImages.keys)
        let imageInfos = Set(images.keys)
        for item in items
            where imageWindowIDs.contains(item.windowID) ||
            (!item.hasGenericIdentity && imageInfos.contains(item.info))
        {
            return false
        }
        return true
    }

    /// Captures the images of the current menu bar items and returns a dictionary containing
    /// the images, keyed by the current menu bar item infos.
    private func createImages(for section: MenuBarSection.Name, screen: NSScreen) async -> CapturedImages {
        guard let appState else {
            return CapturedImages()
        }

        let items = await appState.itemManager.itemCache[section]

        var capturedImages = CapturedImages()
        let backingScaleFactor = screen.backingScaleFactor
        let displayBounds = CGDisplayBounds(screen.displayID)
        let menuBarHeight = screen.getMenuBarHeight() ?? NSStatusBar.system.thickness
        let menuBarFrame = CGRect(
            x: displayBounds.minX,
            y: displayBounds.minY,
            width: displayBounds.width,
            height: menuBarHeight
        )
        let option: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        let defaultItemThickness = NSStatusBar.system.thickness * backingScaleFactor

        var itemInfos = [CGWindowID: MenuBarItemInfo]()
        var itemFrames = [CGWindowID: CGRect]()
        var windowIDs = [CGWindowID]()
        var frame = CGRect.null

        for item in items {
            let windowID = item.windowID
            guard
                // Use the most up-to-date window frame.
                let itemFrame = Bridging.getWindowFrame(for: windowID),
                frameIsCapturable(itemFrame, in: menuBarFrame, for: section)
            else {
                continue
            }
            if !item.hasGenericIdentity {
                itemInfos[windowID] = item.info
            }
            itemFrames[windowID] = itemFrame
            windowIDs.append(windowID)
            frame = frame.union(itemFrame)
        }

        if
            let compositeImage = ScreenCapture.captureWindows(windowIDs, option: option),
            CGFloat(compositeImage.width) == frame.width * backingScaleFactor
        {
            for windowID in windowIDs {
                guard
                    let itemFrame = itemFrames[windowID]
                else {
                    continue
                }

                let frame = CGRect(
                    x: (itemFrame.origin.x - frame.origin.x) * backingScaleFactor,
                    y: (itemFrame.origin.y - frame.origin.y) * backingScaleFactor,
                    width: itemFrame.width * backingScaleFactor,
                    height: itemFrame.height * backingScaleFactor
                )

                guard let itemImage = compositeImage.cropping(to: frame) else {
                    continue
                }

                if let itemInfo = itemInfos[windowID] {
                    capturedImages.imagesByInfo[itemInfo] = itemImage
                }
                capturedImages.imagesByWindowID[windowID] = itemImage
            }
        } else {
            Logger.imageCache.warning("Composite image capture failed. Attempting to capturing items individually.")

            for windowID in windowIDs {
                guard
                    let itemFrame = itemFrames[windowID]
                else {
                    continue
                }

                let frame = CGRect(
                    x: 0,
                    y: ((itemFrame.height * backingScaleFactor) / 2) - (defaultItemThickness / 2),
                    width: itemFrame.width * backingScaleFactor,
                    height: defaultItemThickness
                )

                guard
                    let itemImage = ScreenCapture.captureWindow(windowID, option: option),
                    let croppedImage = itemImage.cropping(to: frame)
                else {
                    continue
                }

                if let itemInfo = itemInfos[windowID] {
                    capturedImages.imagesByInfo[itemInfo] = croppedImage
                }
                capturedImages.imagesByWindowID[windowID] = croppedImage
            }
        }

        return capturedImages
    }

    private func frameIsCapturable(
        _ frame: CGRect,
        in menuBarFrame: CGRect,
        for section: MenuBarSection.Name
    ) -> Bool {
        switch section {
        case .visible:
            return frame.intersects(menuBarFrame)
        case .hidden, .alwaysHidden:
            return frame.minY < menuBarFrame.maxY && frame.maxY > menuBarFrame.minY
        }
    }

    /// Updates the cache for the given sections, without checking whether caching is necessary.
    func updateCacheWithoutChecks(sections: [MenuBarSection.Name]) async {
        guard
            let appState,
            let screen = NSScreen.main
        else {
            return
        }

        var newImages = [MenuBarItemInfo: CGImage]()
        var newWindowImages = [CGWindowID: CGImage]()

        for section in sections {
            guard await !appState.itemManager.itemCache[section].isEmpty else {
                continue
            }
            let sectionImages = await createImages(for: section, screen: screen)
            guard !sectionImages.imagesByWindowID.isEmpty else {
                Logger.imageCache.warning("Update image cache failed for \(section.logString)")
                continue
            }
            newImages.merge(sectionImages.imagesByInfo) { (_, new) in new }
            newWindowImages.merge(sectionImages.imagesByWindowID) { (_, new) in new }
        }

        // Get the set of valid item infos from all sections to clean up stale entries
        let allItems = await appState.itemManager.itemCache.allItems
        let allValidInfos = Set(allItems.map(\.info))
        let allValidWindowIDs = Set(allItems.map(\.windowID))

        let menuBarHeight = screen.getMenuBarHeight()
        await MainActor.run { [newImages, newWindowImages, allItems, allValidInfos, allValidWindowIDs] in
            // Remove images for items that no longer exist in the item cache
            images = images.filter { allValidInfos.contains($0.key) }
            windowImages = windowImages.filter { allValidWindowIDs.contains($0.key) }
            // Merge in the new images
            images.merge(newImages) { (_, new) in new }
            windowImages.merge(newWindowImages) { (_, new) in new }
            self.screen = NSScreen.main
            self.menuBarHeight = menuBarHeight
            updateVisualImages(for: allItems)
        }
    }

    /// Updates the cache for the given sections, if necessary.
    func updateCache(sections: [MenuBarSection.Name]) async {
        guard let appState else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented

        if !isIceBarPresented && !isSearchPresented {
            guard await appState.navigationState.isAppFrontmost else {
                logSkippingCache(reason: "Ice Bar not visible, app not frontmost")
                return
            }
            guard await appState.navigationState.isSettingsPresented else {
                logSkippingCache(reason: "Ice Bar not visible, Settings not visible")
                return
            }
            guard case .menuBarLayout = await appState.navigationState.settingsNavigationIdentifier else {
                logSkippingCache(reason: "Ice Bar not visible, Settings visible but not on Menu Bar Layout")
                return
            }
        }

        guard await !appState.itemManager.isMovingItem else {
            logSkippingCache(reason: "an item is currently being moved")
            return
        }

        guard await !appState.itemManager.itemHasRecentlyMoved else {
            logSkippingCache(reason: "an item was recently moved")
            return
        }

        await updateCacheWithoutChecks(sections: sections)
    }

    /// Updates the cache for all sections, if necessary.
    func updateCache() async {
        guard let appState else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented
        let isSettingsPresented = await appState.navigationState.isSettingsPresented

        var sectionsNeedingDisplay = [MenuBarSection.Name]()
        if isSettingsPresented || isSearchPresented {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        } else if
            isIceBarPresented,
            let section = await appState.menuBarManager.iceBarPanel.currentSection
        {
            sectionsNeedingDisplay.append(section)
        }

        await updateCache(sections: sectionsNeedingDisplay)
    }
}

// MARK: - Visual Image Retention

private extension MenuBarItemImageCache {
    private func visualImageKey(for item: MenuBarItem) -> VisualImageKey? {
        guard item.hasGenericIdentity else {
            return .identified(info: item.info, ownerPID: item.ownerPID)
        }

        guard item.frame.width > 0, item.frame.height > 0 else {
            return nil
        }

        return .generic(
            info: item.info,
            ownerPID: item.ownerPID,
            widthBucket: Int((item.frame.width / 4).rounded()),
            heightBucket: Int((item.frame.height / 4).rounded())
        )
    }

    func visualImageKeyDescription(for item: MenuBarItem) -> String {
        switch visualImageKey(for: item) {
        case .identified(let info, let ownerPID):
            return "\(info)|pid=\(ownerPID)"
        case .generic(let info, let ownerPID, let widthBucket, let heightBucket):
            return "\(info)|pid=\(ownerPID)|w=\(widthBucket)|h=\(heightBucket)"
        case nil:
            return "\(item.info)|pid=\(item.ownerPID)|unkeyed"
        }
    }

    func logImageLookup(item _: MenuBarItem, source _: String, image _: CGImage) {
        // Cache hits are intentionally quiet. Post-move health diagnostics in
        // LayoutBarPaddingView now report the moved item's actual render state.
    }

    func updateVisualImages(for items: [MenuBarItem]) {
        let now = Date()
        let validInterval = now.addingTimeInterval(-visualImageRetentionInterval)
        visualImages = visualImages.filter { _, retainedImage in
            retainedImage.capturedAt >= validInterval
        }

        var didUpdate = false
        for item in items {
            guard
                let image = windowImages[item.windowID] ?? (!item.hasGenericIdentity ? images[item.info] : nil),
                image.width > 0,
                image.height > 0,
                let key = visualImageKey(for: item)
            else {
                continue
            }

            visualImages[key] = RetainedVisualImage(
                image: image,
                capturedAt: now
            )
            didUpdate = true
        }

        if didUpdate {
            visualImagesRevision += 1
        }
    }

    func shouldLogIdentityDebug(for item: MenuBarItem) -> Bool {
        if layoutDebugWindowIDs.contains(item.windowID) {
            return true
        }

        let values = [
            item.logString,
            item.title ?? "",
            item.ownerName ?? "",
            item.owningApplication?.bundleIdentifier ?? "",
            item.owningApplication?.localizedName ?? "",
        ].joined(separator: " ").lowercased()

        return ["stats", "ram", "mini", "exelban"].contains { values.contains($0) }
    }
}

// MARK: - Logger

private extension Logger {
    static let imageCache = Logger(category: "MenuBarItemImageCache")
}
