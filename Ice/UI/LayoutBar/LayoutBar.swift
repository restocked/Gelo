//
//  LayoutBar.swift
//  Ice
//

import SwiftUI

struct LayoutBar: View {
    private struct Representable: NSViewRepresentable {
        let appState: AppState
        let section: MenuBarSection
        let spacing: CGFloat
        let allowsDragging: Bool

        func makeNSView(context: Context) -> LayoutBarScrollView {
            LayoutBarScrollView(
                appState: appState,
                section: section,
                spacing: spacing,
                allowsDragging: allowsDragging
            )
        }

        func updateNSView(_ nsView: LayoutBarScrollView, context: Context) {
            nsView.spacing = spacing
            nsView.allowsDragging = allowsDragging
        }
    }

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var imageCache: MenuBarItemImageCache

    let section: MenuBarSection
    let spacing: CGFloat
    let allowsDragging: Bool

    private var menuBarManager: MenuBarManager {
        appState.menuBarManager
    }

    private var backgroundShape: some InsettableShape {
        RoundedRectangle(cornerRadius: 9, style: .circular)
    }

    init(section: MenuBarSection, spacing: CGFloat = 0, allowsDragging: Bool = true) {
        self.section = section
        self.spacing = spacing
        self.allowsDragging = allowsDragging
    }

    var body: some View {
        conditionalBody
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .layoutBarStyle(appState: appState, averageColorInfo: menuBarManager.averageColorInfo)
            .clipShape(backgroundShape)
            .overlay {
                backgroundShape
                    .stroke(.quaternary)
            }
    }

    @ViewBuilder
    private var conditionalBody: some View {
        if imageCache.cacheFailed(for: section.name) {
            Text("Unable to display menu bar items")
                .foregroundStyle(menuBarManager.averageColorInfo?.color.brightness ?? 0 > 0.67 ? .black : .white)
        } else {
            Representable(
                appState: appState,
                section: section,
                spacing: spacing,
                allowsDragging: allowsDragging
            )
        }
    }
}
