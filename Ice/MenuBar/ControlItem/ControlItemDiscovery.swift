//
//  ControlItemDiscovery.swift
//  Ice
//

import Cocoa

/// Discovers the `CGWindowID` corresponding to each of Gelo's own control items.
///
/// On macOS 26 (Tahoe), the window list reports all menu bar items as owned by
/// Control Center with `nil` titles, so the previous identification path
/// (filtering by bundle identifier and title) cannot recognize Gelo's own
/// control items. Frame matching against the underlying `NSStatusItem` windows
/// remains reliable across macOS versions, so this type provides a fallback
/// path that does not rely on window list metadata.
enum ControlItemDiscovery {
    /// Tolerance used when matching the x-origin of a frame.
    ///
    /// Tahoe occasionally rounds layout coordinates by a fraction of a point
    /// between the AppKit and CG coordinate spaces.
    private static let xTolerance: CGFloat = 1.0

    /// Tolerance used when matching the width of a frame.
    private static let widthTolerance: CGFloat = 2.0

    /// Builds a mapping from `CGWindowID` to the corresponding control item
    /// identifier for each control item that is currently placed in the menu
    /// bar.
    ///
    /// May be empty if no control items have been placed yet (e.g. very early
    /// during launch). Callers should treat an empty map as "no information"
    /// rather than "no control items present" and fall back to existing
    /// metadata-based identification.
    @MainActor
    static func buildMap(for sections: [MenuBarSection]) -> [CGWindowID: ControlItem.Identifier] {
        let menuBarWindowIDs = Bridging.getWindowList(option: [.menuBarItems])
        guard !menuBarWindowIDs.isEmpty else {
            return [:]
        }

        var map: [CGWindowID: ControlItem.Identifier] = [:]

        for section in sections {
            let controlItem = section.controlItem
            guard
                controlItem.isAddedToMenuBar,
                let nsWindow = controlItem.window
            else {
                continue
            }

            // Cheap path: on macOS prior to Tahoe, NSWindow.windowNumber
            // matches the CGWindowID directly. Verify by confirming the
            // ID is in the menu bar window list and has a usable frame.
            let directID = CGWindowID(nsWindow.windowNumber)
            if menuBarWindowIDs.contains(directID),
               Bridging.getWindowFrame(for: directID) != nil {
                map[directID] = controlItem.identifier
                continue
            }

            // Fallback path: match by frame. AppKit window frame is in
            // Cocoa screen coordinates (bottom-left origin); the window list
            // returns CG screen coordinates (top-left origin).
            let cgFrame = convertToCGScreenFrame(nsWindow.frame)
            let xTarget = cgFrame.minX
            let widthTarget = cgFrame.width

            for windowID in menuBarWindowIDs {
                guard let candidateFrame = Bridging.getWindowFrame(for: windowID) else {
                    continue
                }
                if abs(candidateFrame.minX - xTarget) <= xTolerance,
                   abs(candidateFrame.width - widthTarget) <= widthTolerance {
                    map[windowID] = controlItem.identifier
                    break
                }
            }
        }

        return map
    }

    /// Converts a Cocoa-screen-coordinate frame (bottom-left origin, primary
    /// display height as reference) into the equivalent CG screen coordinate
    /// frame (top-left origin) used by the window list APIs.
    private static func convertToCGScreenFrame(_ nsFrame: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else {
            return nsFrame
        }
        let primaryHeight = primary.frame.height
        return CGRect(
            x: nsFrame.minX,
            y: primaryHeight - nsFrame.maxY,
            width: nsFrame.width,
            height: nsFrame.height
        )
    }
}
