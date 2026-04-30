//
//  MenuBarLayoutSettingsPane.swift
//  Ice
//

import SwiftUI

struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @State private var isWarmingLayoutCache = false

    var body: some View {
        if !ScreenCapture.cachedCheckPermissions() {
            missingScreenRecordingPermission
        } else if appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            cannotArrange
        } else {
            IceForm(alignment: .leading, spacing: 20) {
                header
                if isWarmingLayoutCache && appState.itemManager.itemCache.isEmpty {
                    loadingState
                }
                layoutBars
            }
            .task {
                await warmLayoutCache()
            }
        }
    }

    @ViewBuilder
    private var loadingState: some View {
        IceGroupBox {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading menu bar items")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private var header: some View {
        Text("Drag to arrange your menu bar items")
            .font(.title2)

        IceGroupBox {
            AnnotationView(
                alignment: .center,
                font: .callout.bold()
            ) {
                Label {
                    Text("Tip: you can also arrange menu bar items by Command + dragging them in the menu bar")
                } icon: {
                    Image(systemName: "lightbulb")
                }
            }
        }
    }

    @ViewBuilder
    private var layoutBars: some View {
        VStack(spacing: 25) {
            ForEach(MenuBarSection.Name.allCases, id: \.self) { section in
                layoutBar(for: section)
            }
        }
    }

    @ViewBuilder
    private var cannotArrange: some View {
        Text("Ice cannot arrange menu bar items in automatically hidden menu bars")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var missingScreenRecordingPermission: some View {
        VStack {
            Text("Menu bar layout requires screen recording permissions")
                .font(.title2)

            Button {
                appState.navigationState.settingsNavigationIdentifier = .advanced
            } label: {
                Text("Go to Advanced Settings")
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func layoutBar(for section: MenuBarSection.Name) -> some View {
        if
            let section = appState.menuBarManager.section(withName: section),
            section.isEnabled || section.name == .alwaysHidden
        {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(section.name.displayString) Section")
                    .font(.system(size: 14))
                    .padding(.leading, 2)

                LayoutBar(section: section, allowsDragging: section.isEnabled)
                    .environmentObject(appState.imageCache)
                    .opacity(section.isEnabled ? 1 : 0.55)
            }
        }
    }

    private func warmLayoutCache() async {
        // Let SwiftUI finish presenting the pane before doing AX/window-list
        // discovery and image capture for the layout bars.
        try? await Task.sleep(for: .milliseconds(100))
        isWarmingLayoutCache = true
        await appState.itemManager.warmLayoutCacheForSettings()
        if ScreenCapture.cachedCheckPermissions(reset: true) {
            await appState.imageCache.updateCache(sections: MenuBarSection.Name.allCases)
        }
        isWarmingLayoutCache = false
    }
}
