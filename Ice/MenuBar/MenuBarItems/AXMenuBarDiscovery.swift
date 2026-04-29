//
//  AXMenuBarDiscovery.swift
//  Ice
//

import AXSwift
import Cocoa

/// Identity recovered for an external menu bar item via the Accessibility API.
///
/// On macOS 26 (Tahoe), the window list APIs no longer expose per-item bundle
/// identifier or window title. The Accessibility tree, however, still reports
/// per-item frames, owning processes, and titles. This type carries the
/// identity recovered from that traversal so it can substitute for the data
/// the window list would normally provide.
struct AXMenuBarItemIdentity {
    let bundleIdentifier: String?
    let title: String?
    let frame: CGRect
}

/// A frame-based key used to look up an `AXMenuBarItemIdentity` from a
/// `CGWindowList` frame.
///
/// Frames coming from the Accessibility API and from the window list APIs are
/// in the same (CG screen) coordinate space, but may differ by sub-pixel
/// rounding. Rounding both to the nearest integer point on insertion and
/// lookup makes the key stable across that jitter.
struct AXFrameKey: Hashable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ frame: CGRect) {
        self.x = Int(frame.origin.x.rounded())
        self.y = Int(frame.origin.y.rounded())
        self.width = Int(frame.width.rounded())
        self.height = Int(frame.height.rounded())
    }
}

/// Discovers menu bar items via the system-wide Accessibility tree and exposes
/// a frame-keyed lookup table mapping CG-coordinate frames to identity records.
enum AXMenuBarDiscovery {
    /// Builds an identity map keyed by integer-rounded CG frame.
    ///
    /// Returns an empty map when accessibility permission has not been granted
    /// or the menu bar element cannot be reached. Callers must fall back
    /// gracefully when an item is not present in the map.
    @MainActor
    static func buildIdentityMap() -> [AXFrameKey: AXMenuBarItemIdentity] {
        guard let primary = NSScreen.screens.first else {
            return [:]
        }
        guard
            let menuBar = try? systemWideElement.elementAtPosition(
                Float(primary.frame.minX),
                Float(primary.frame.minY)
            ),
            let role = try? menuBar.role(),
            role == .menuBar,
            let children: [UIElement] = try? menuBar.arrayAttribute(.children)
        else {
            return [:]
        }

        var map: [AXFrameKey: AXMenuBarItemIdentity] = [:]

        for child in children {
            let frame: CGRect? = try? child.attribute(.frame)
            guard let frame else {
                continue
            }
            let title: String? = try? child.attribute(.title)
            let pid = (try? child.pid()) ?? 0
            let bundleIdentifier = pid > 0
                ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                : nil

            map[AXFrameKey(frame)] = AXMenuBarItemIdentity(
                bundleIdentifier: bundleIdentifier,
                title: title,
                frame: frame
            )
        }

        return map
    }
}
