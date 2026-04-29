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
    let identifier: String?
    let description: String?
    let help: String?
    let valueDescription: String?
    let frame: CGRect

    var bestTitle: String {
        Self.bestTitle(
            title: title,
            identifier: identifier,
            description: description,
            help: help,
            valueDescription: valueDescription
        )
    }

    private static func bestTitle(
        title: String?,
        identifier: String?,
        description: String?,
        help: String?,
        valueDescription: String?
    ) -> String {
        let candidates = [
            title,
            description,
            valueDescription,
            help,
            identifier,
        ]

        let values = candidates.compactMap { $0?.nonEmptyTrimmedValue }

        if let meaningful = values.first(where: { !isGenericName($0) }) {
            return meaningful
        }

        return values.first ?? ""
    }

    private static func isGenericName(_ value: String) -> Bool {
        guard value.hasPrefix("Item-") else {
            return false
        }
        return value.dropFirst("Item-".count).allSatisfy(\.isNumber)
    }
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
    private static let frameTolerance: CGFloat = 2

    /// Builds an identity map keyed by integer-rounded CG frame.
    ///
    /// Returns an empty map when accessibility permission has not been granted
    /// or the menu bar element cannot be reached. Callers must fall back
    /// gracefully when an item is not present in the map.
    @MainActor
    static func buildIdentityMap() -> [AXFrameKey: AXMenuBarItemIdentity] {
        var map: [AXFrameKey: AXMenuBarItemIdentity] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard
                app.isFinishedLaunching,
                !app.isTerminated,
                app.activationPolicy != .prohibited,
                Bridging.responsivity(for: app.processIdentifier) != .unresponsive,
                let menuBarApp = Application(app),
                let extrasMenuBar: UIElement = try? menuBarApp.attribute(.extrasMenuBar),
                let children: [UIElement] = try? extrasMenuBar.arrayAttribute(.children)
            else {
                continue
            }

            let bundleIdentifier = app.bundleIdentifier ?? app.localizedName ?? "\(app.processIdentifier)"

            for child in children {
                let frame: CGRect? = try? child.attribute(.frame)
                guard let frame else {
                    continue
                }
                let title: String? = try? child.attribute(.title)
                let identifier: String? = try? child.attribute(.identifier)
                let description: String? = try? child.attribute(.description)
                let help: String? = try? child.attribute(.help)
                let valueDescription: String? = try? child.attribute(.valueDescription)

                map[AXFrameKey(frame)] = AXMenuBarItemIdentity(
                    bundleIdentifier: bundleIdentifier,
                    title: title,
                    identifier: identifier,
                    description: description,
                    help: help,
                    valueDescription: valueDescription,
                    frame: frame
                )
            }
        }

        return map
    }

    static func identity(
        in map: [AXFrameKey: AXMenuBarItemIdentity],
        matching frame: CGRect
    ) -> AXMenuBarItemIdentity? {
        if let exact = map[AXFrameKey(frame)] {
            return exact
        }

        return map.values
            .filter { framesMatch($0.frame, frame) }
            .min { $0.frame.centerDistance(to: frame) < $1.frame.centerDistance(to: frame) }
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        lhs.centerDistance(to: rhs) <= frameTolerance &&
        abs(lhs.width - rhs.width) <= frameTolerance &&
        abs(lhs.height - rhs.height) <= frameTolerance
    }
}

private extension String {
    var nonEmptyTrimmedValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
