//
//  MenuBarItem.swift
//  Ice
//

import Cocoa

// MARK: - MenuBarItem

/// A representation of an item in the menu bar.
struct MenuBarItem {
    /// The item's window.
    let window: WindowInfo

    /// The menu bar item info associated with this item.
    let info: MenuBarItemInfo

    /// The identifier of the item's window.
    var windowID: CGWindowID {
        window.windowID
    }

    /// The frame of the item's window.
    var frame: CGRect {
        window.frame
    }

    /// The title of the item's window.
    var title: String? {
        window.title
    }

    /// A Boolean value that indicates whether the item is on screen.
    var isOnScreen: Bool {
        window.isOnScreen
    }

    /// A Boolean value that indicates whether the item can be moved.
    var isMovable: Bool {
        let immovableItems = Set(MenuBarItemInfo.immovableItems)
        return !immovableItems.contains(info)
    }

    /// A Boolean value that indicates whether the item can be hidden.
    var canBeHidden: Bool {
        let nonHideableItems = Set(MenuBarItemInfo.nonHideableItems)
        return !nonHideableItems.contains(info)
    }

    /// A Boolean value that indicates whether the item's current window frame
    /// can safely be used as a live move destination.
    var hasUsableMoveDestinationFrame: Bool {
        guard
            isCurrentlyInMenuBar,
            let currentFrame = Bridging.getWindowFrame(for: windowID),
            !currentFrame.isNull,
            !currentFrame.isEmpty,
            currentFrame.width > 0,
            currentFrame.height > 0
        else {
            return false
        }

        return NSScreen.screens.contains { screen in
            let displayBounds = CGDisplayBounds(screen.displayID)
            let menuBarHeight = screen.getMenuBarHeight() ?? NSStatusBar.system.thickness
            let menuBarFrame = CGRect(
                x: displayBounds.minX,
                y: displayBounds.minY,
                width: displayBounds.width,
                height: menuBarHeight
            )
            return menuBarFrame.intersects(currentFrame)
        }
    }

    /// A Boolean value that indicates whether the item's current window frame
    /// can be used as a move destination, including offscreen hidden-section
    /// frames.
    var hasMoveDestinationFrame: Bool {
        guard
            let currentFrame = Bridging.getWindowFrame(for: windowID),
            !currentFrame.isNull,
            !currentFrame.isEmpty,
            currentFrame.width > 0,
            currentFrame.height > 0
        else {
            return false
        }

        return true
    }

    /// The process identifier of the application that owns the item.
    var ownerPID: pid_t {
        window.ownerPID
    }

    /// The name of the application that owns the item.
    ///
    /// This may have a value when ``owningApplication`` does not have
    /// a localized name.
    var ownerName: String? {
        window.ownerName
    }

    /// The application that owns the item.
    var owningApplication: NSRunningApplication? {
        window.owningApplication
    }

    /// A name associated with the item that is suited for display to
    /// the user.
    var displayName: String {
        if hasGenericIdentity {
            return "Control Center Item #\(windowID)"
        }

        var fallback: String { "Unknown" }
        guard let owningApplication else {
            return ownerName ?? title ?? fallback
        }
        var bestName: String {
            owningApplication.localizedName ??
            ownerName ??
            owningApplication.bundleIdentifier ??
            fallback
        }
        guard let title else {
            return bestName
        }
        // by default, use the application name, but handle a few special cases
        return switch MenuBarItemInfo.Namespace(owningApplication.bundleIdentifier) {
        case .controlCenter:
            switch title {
            case "AccessibilityShortcuts": "Accessibility Shortcuts"
            case "BentoBox": bestName // Control Center
            case "FocusModes": "Focus"
            case "KeyboardBrightness": "Keyboard Brightness"
            case "MusicRecognition": "Music Recognition"
            case "NowPlaying": "Now Playing"
            case "ScreenMirroring": "Screen Mirroring"
            case "StageManager": "Stage Manager"
            case "UserSwitcher": "Fast User Switching"
            case "WiFi": "Wi-Fi"
            default: title
            }
        case .systemUIServer:
            switch title {
            case "TimeMachine.TMMenuExtraHost"/*Sonoma*/, "TimeMachineMenuExtra.TMMenuExtraHost"/*Sequoia*/: "Time Machine"
            default: title
            }
        case MenuBarItemInfo.Namespace("com.apple.Passwords.MenuBarExtra"): "Passwords"
        default:
            bestName
        }
    }

    /// A Boolean value that indicates whether the item is currently
    /// in the menu bar.
    var isCurrentlyInMenuBar: Bool {
        let list = Set(Bridging.getWindowList(option: .menuBarItems))
        return list.contains(windowID)
    }

    /// A Boolean value that indicates whether this item only has a generic
    /// menu bar identity and must be matched by runtime window identity.
    var hasGenericIdentity: Bool {
        info.isGenericControlCenterItem
    }

    /// A string to use for logging purposes.
    var logString: String {
        if hasGenericIdentity {
            return "\(info)#\(windowID)"
        }
        return String(describing: info)
    }

    /// Creates a menu bar item from the given window.
    ///
    /// This initializer does not perform any checks on the window to ensure that
    /// it is a valid menu bar item window. Only call this initializer if you are
    /// certain that the window is valid.
    private init(uncheckedItemWindow itemWindow: WindowInfo) {
        self.window = itemWindow
        self.info = MenuBarItemInfo(uncheckedItemWindow: itemWindow)
    }

    /// Creates a menu bar item.
    ///
    /// The parameters passed into this initializer are verified during the menu
    /// bar item's creation. If `itemWindow` does not represent a menu bar item,
    /// the initializer will fail.
    ///
    /// - Parameter itemWindow: A window that contains information about the item.
    init?(itemWindow: WindowInfo) {
        guard itemWindow.isMenuBarItem else {
            return nil
        }
        self.init(uncheckedItemWindow: itemWindow)
    }

    /// Creates a menu bar item with the given window identifier.
    ///
    /// The parameters passed into this initializer are verified during the menu
    /// bar item's creation. If `windowID` does not represent a menu bar item,
    /// the initializer will fail.
    ///
    /// - Parameter windowID: An identifier for a window that contains information
    ///   about the item.
    init?(windowID: CGWindowID) {
        guard let window = WindowInfo(windowID: windowID) else {
            return nil
        }
        self.init(itemWindow: window)
    }

    /// Creates a menu bar item using auxiliary identity sources.
    ///
    /// On macOS 26 (Tahoe), the window list APIs no longer expose per-item
    /// bundle identifier or window title, so the standard initializer assigns
    /// every item the same opaque identity. This initializer accepts two
    /// auxiliary maps that supply identity from sources that still work on
    /// Tahoe:
    ///
    /// - `controlItemMap` maps a window identifier to one of Gelo's own
    ///   control item identifiers, recovered by frame matching against the
    ///   underlying `NSStatusItem` windows.
    /// - `axMap` maps a frame in CG screen coordinates to the identity
    ///   recovered for that frame via the Accessibility API.
    ///
    /// Lookups proceed in priority order: control item map first, then AX map,
    /// then the window-list-derived identity. Passing empty maps reproduces
    /// the original behavior, so this initializer is safe to use on any
    /// macOS version.
    init?(
        windowID: CGWindowID,
        controlItemMap: [CGWindowID: ControlItem.Identifier],
        axMap: [AXFrameKey: AXMenuBarItemIdentity]
    ) {
        guard let itemWindow = WindowInfo(windowID: windowID) else {
            return nil
        }
        guard itemWindow.isMenuBarItem else {
            return nil
        }
        self.window = itemWindow

        if let controlIdentifier = controlItemMap[windowID] {
            self.info = MenuBarItemInfo(
                namespace: .ice,
                title: controlIdentifier.rawValue
            )
            return
        }

        if
            !axMap.isEmpty,
            let frame = Bridging.getWindowFrame(for: windowID),
            let axIdentity = AXMenuBarDiscovery.identity(in: axMap, matching: frame)
        {
            if let controlItemInfo = MenuBarItemInfo(controlItemTitle: axIdentity.bestTitle) {
                self.info = controlItemInfo
                return
            }

            self.info = MenuBarItemInfo(
                namespace: MenuBarItemInfo.Namespace(axIdentity.bundleIdentifier),
                title: axIdentity.bestTitle
            )
            return
        }

        if
            let title = itemWindow.title,
            let controlItemInfo = MenuBarItemInfo(controlItemTitle: title)
        {
            self.info = controlItemInfo
            return
        }

        if
            itemWindow.owningApplication?.bundleIdentifier == MenuBarItemInfo.Namespace.controlCenter.rawValue,
            itemWindow.title?.isEmpty != false
        {
            self.info = MenuBarItemInfo(
                namespace: MenuBarItemInfo.Namespace("CGWindow"),
                title: String(windowID)
            )
            return
        }

        self.info = MenuBarItemInfo(uncheckedItemWindow: itemWindow)
    }
}

// MARK: MenuBarItem Getters
extension MenuBarItem {
    /// Returns an array of the current menu bar items in the menu bar on the given display.
    ///
    /// - Parameters:
    ///   - display: The display to retrieve the menu bar items on. Pass `nil` to return the
    ///     menu bar items across all displays.
    ///   - onScreenOnly: A Boolean value that indicates whether only the menu bar items that
    ///     are on screen should be returned.
    ///   - activeSpaceOnly: A Boolean value that indicates whether only the menu bar items
    ///     that are on the active space should be returned.
    static func getMenuBarItems(
        on display: CGDirectDisplayID? = nil,
        onScreenOnly: Bool,
        activeSpaceOnly: Bool,
        controlItemMap: [CGWindowID: ControlItem.Identifier] = [:],
        axMap: [AXFrameKey: AXMenuBarItemIdentity] = [:]
    ) -> [MenuBarItem] {
        var option: Bridging.WindowListOption = [.menuBarItems]

        var titlePredicate: (MenuBarItem) -> Bool = { _ in true }
        var boundsPredicate: (CGWindowID) -> Bool = { _ in true }

        if onScreenOnly {
            option.insert(.onScreen)
        }
        if activeSpaceOnly {
            option.insert(.activeSpace)
            titlePredicate = {
                $0.title != "" ||
                ($0.info.namespace != .null && $0.info.namespace != .controlCenter)
            }
        }
        if let display {
            let displayBounds = CGDisplayBounds(display)
            boundsPredicate = { windowID in
                guard let windowFrame = Bridging.getWindowFrame(for: windowID) else {
                    return false
                }
                return displayBounds.intersects(windowFrame)
            }
        }

        var windowIDs = Bridging.getWindowList(option: option)
        for windowID in controlItemMap.keys where !windowIDs.contains(windowID) {
            windowIDs.append(windowID)
        }

        var seenWindowIDs = Set<CGWindowID>()
        var items = [MenuBarItem]()
        for windowID in windowIDs where boundsPredicate(windowID) {
            guard
                let item = MenuBarItem(windowID: windowID, controlItemMap: controlItemMap, axMap: axMap),
                titlePredicate(item),
                seenWindowIDs.insert(item.windowID).inserted
            else {
                continue
            }
            items.append(item)
        }

        return items.sortedByOrderInMenuBar()
    }
}

// MARK: MenuBarItem: Equatable
extension MenuBarItem: Equatable {
    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool {
        lhs.window == rhs.window
    }
}

// MARK: MenuBarItem: Hashable
extension MenuBarItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(window)
    }
}

// MARK: MenuBarItemInfo Unchecked Item Window Initializer
private extension MenuBarItemInfo {
    /// Creates item info for one of Gelo's own control items when Tahoe reports
    /// it under Control Center's accessibility/window-list identity.
    init?(controlItemTitle title: String) {
        guard let identifier = ControlItem.Identifier(rawValue: title) else {
            return nil
        }
        self.init(namespace: .ice, title: identifier.rawValue)
    }

    /// Creates a simplified item from the given window.
    ///
    /// This initializer does not perform any checks on the window to ensure that
    /// it is a valid menu bar item window. Only call this initializer if you are
    /// certain that the window is valid.
    init(uncheckedItemWindow itemWindow: WindowInfo) {
        if let bundleIdentifier = itemWindow.owningApplication?.bundleIdentifier {
            self.namespace = Namespace(bundleIdentifier)
        } else {
            self.namespace = .null
        }
        if let title = itemWindow.title {
            self.title = title
        } else {
            self.title = ""
        }
    }
}
