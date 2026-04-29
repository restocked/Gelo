//
//  ControlItemDiscovery.swift
//  Ice
//

import AXSwift
import Cocoa

/// Discovers the `CGWindowID` corresponding to each of Gelo's own control items.
///
/// On macOS 26 (Tahoe), menu bar item windows are reported as owned by Control
/// Center and no longer carry useful per-item titles. Gelo's own status item
/// buttons are stamped with accessibility identifiers, so we recover their
/// rendered frames from this app's AX extras menu bar and match those frames to
/// the CG menu bar window list.
enum ControlItemDiscovery {
    /// Tolerance for matching AX frames to CG window frames.
    private static let frameTolerance: CGFloat = 2

    /// Minimum width used to recognize Ice's hidden-section spacer windows.
    private static let spacerWidthThreshold = NSStatusBar.system.thickness * 20

    /// Builds a mapping from `CGWindowID` to the corresponding control item
    /// identifier for each control item present in the menu bar.
    @MainActor
    static func buildMap(for sections: [MenuBarSection]) -> [CGWindowID: ControlItem.Identifier] {
        let menuBarWindowIDs = Bridging.getWindowList(option: [.menuBarItems])
        guard !menuBarWindowIDs.isEmpty else {
            return [:]
        }

        var map: [CGWindowID: ControlItem.Identifier] = [:]

        for section in sections {
            let controlItem = section.controlItem
            guard controlItem.isAddedToMenuBar else {
                continue
            }

            if
                let directID = controlItem.windowID,
                menuBarWindowIDs.contains(directID),
                Bridging.getWindowFrame(for: directID) != nil
            {
                map[directID] = controlItem.identifier
            }
        }

        guard map.count < sections.filter({ $0.controlItem.isAddedToMenuBar }).count else {
            return map
        }

        let windowFrames = menuBarWindowIDs.compactMap { windowID -> (CGWindowID, CGRect)? in
            guard map[windowID] == nil, let frame = Bridging.getWindowFrame(for: windowID) else {
                return nil
            }
            return (windowID, frame)
        }

        let axItems = controlItemAXItems()

        for axItem in axItems {
            guard
                let rawIdentifier = axItem.identifier,
                let identifier = ControlItem.Identifier(rawValue: rawIdentifier),
                map.values.contains(identifier) == false,
                let windowID = bestMatchingWindowID(for: axItem.frame, in: windowFrames)
            else {
                continue
            }
            map[windowID] = identifier
        }

        guard map.count < sections.filter({ $0.controlItem.isAddedToMenuBar }).count else {
            return map
        }

        for (identifier, frame) in fallbackControlItemFrames(from: axItems, sections: sections) {
            guard
                map.values.contains(identifier) == false,
                let windowID = bestMatchingWindowID(for: frame, in: windowFrames)
            else {
                continue
            }
            map[windowID] = identifier
        }

        guard map.count < sections.filter({ $0.controlItem.isAddedToMenuBar }).count else {
            return map
        }

        for (identifier, windowID) in fallbackSpacerWindows(from: windowFrames, sections: sections) {
            guard map.values.contains(identifier) == false else {
                continue
            }
            map[windowID] = identifier
        }

        return map
    }

    private static func controlItemAXItems() -> [(identifier: String?, frame: CGRect)] {
        guard
            let application = Application(NSRunningApplication.current),
            let extrasMenuBar: UIElement = try? application.attribute(.extrasMenuBar),
            let children: [UIElement] = try? extrasMenuBar.arrayAttribute(.children)
        else {
            return []
        }

        return children.compactMap { child in
            guard
                let frame: CGRect = try? child.attribute(.frame)
            else {
                return nil
            }
            let identifier: String? = try? child.attribute(.identifier)
            return (identifier, frame)
        }
    }

    @MainActor
    private static func fallbackControlItemFrames(
        from axItems: [(identifier: String?, frame: CGRect)],
        sections: [MenuBarSection]
    ) -> [(ControlItem.Identifier, CGRect)] {
        let placedIdentifiers = sections
            .filter { $0.controlItem.isAddedToMenuBar }
            .map(\.controlItem.identifier)
        let visualOrder: [ControlItem.Identifier] = [.alwaysHidden, .hidden, .iceIcon]
        let expectedVisualOrder = visualOrder.filter { placedIdentifiers.contains($0) }

        let sortedItems = axItems.sorted { $0.frame.minX < $1.frame.minX }
        guard sortedItems.count == expectedVisualOrder.count else {
            return []
        }

        return zip(expectedVisualOrder, sortedItems.map(\.frame)).map { ($0, $1) }
    }

    @MainActor
    private static func fallbackSpacerWindows(
        from windowFrames: [(id: CGWindowID, frame: CGRect)],
        sections: [MenuBarSection]
    ) -> [(ControlItem.Identifier, CGWindowID)] {
        let placedIdentifiers = sections
            .filter { $0.controlItem.isAddedToMenuBar }
            .map(\.controlItem.identifier)
        let expectedSpacerOrder: [ControlItem.Identifier] = [.alwaysHidden, .hidden]
            .filter { placedIdentifiers.contains($0) }
        guard !expectedSpacerOrder.isEmpty else {
            return []
        }

        let spacerWindows = windowFrames
            .filter { $0.frame.width >= spacerWidthThreshold }
            .sorted { $0.frame.minX < $1.frame.minX }
            .suffix(expectedSpacerOrder.count)
        guard spacerWindows.count == expectedSpacerOrder.count else {
            return []
        }

        return zip(expectedSpacerOrder, spacerWindows.map(\.id)).map { ($0, $1) }
    }

    private static func bestMatchingWindowID(
        for axFrame: CGRect,
        in windowFrames: [(id: CGWindowID, frame: CGRect)]
    ) -> CGWindowID? {
        windowFrames
            .filter { framesMatch($0.frame, axFrame) }
            .min { $0.frame.centerDistance(to: axFrame) < $1.frame.centerDistance(to: axFrame) }?
            .id
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        lhs.centerDistance(to: rhs) <= frameTolerance &&
        abs(lhs.width - rhs.width) <= frameTolerance &&
        abs(lhs.height - rhs.height) <= frameTolerance
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func centerDistance(to other: CGRect) -> CGFloat {
        hypot(center.x - other.center.x, center.y - other.center.y)
    }
}
