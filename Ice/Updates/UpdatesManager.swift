//
//  UpdatesManager.swift
//  Ice
//

import Combine
import Foundation

/// Manager for app updates.
@MainActor
final class UpdatesManager: NSObject, ObservableObject {
    /// A Boolean value that indicates whether app updates are enabled.
    static let isEnabled = false

    /// A Boolean value that indicates whether the user can check for updates.
    @Published var canCheckForUpdates = false

    /// The date of the last update check.
    @Published var lastUpdateCheckDate: Date?

    /// A Boolean value that indicates whether to automatically check for updates.
    var automaticallyChecksForUpdates: Bool {
        get { false }
        set { _ = newValue }
    }

    /// A Boolean value that indicates whether to automatically download updates.
    var automaticallyDownloadsUpdates: Bool {
        get { false }
        set { _ = newValue }
    }

    /// Creates an updates manager with the given app state.
    init(appState: AppState) {
        super.init()
    }

    /// Sets up the manager.
    func performSetup() { }

    /// Checks for app updates.
    @objc func checkForUpdates() { }
}

// MARK: UpdatesManager: BindingExposable
extension UpdatesManager: BindingExposable { }
