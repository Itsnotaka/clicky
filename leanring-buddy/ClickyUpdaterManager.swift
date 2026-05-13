//
//  ClickyUpdaterManager.swift
//  leanring-buddy
//
//  Dashboard-facing Sparkle updater state and actions.
//

import Combine
import Foundation
import Sparkle

@MainActor
final class ClickyUpdaterManager: NSObject, ObservableObject {
    @Published private(set) var updateStatusText = "Starting"

    private let updaterController: SPUStandardUpdaterController
    private var didStartUpdater = false

    var canCheckForUpdates: Bool {
        didStartUpdater && updaterController.updater.canCheckForUpdates
    }

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        startUpdater()
    }

    func refreshUpdateAvailability() {
        if canCheckForUpdates {
            updateStatusText = "Ready"
        } else if didStartUpdater {
            updateStatusText = "Busy"
        } else {
            updateStatusText = "Unavailable"
        }
    }

    func checkForUpdates(_ sender: Any?) {
        refreshUpdateAvailability()
        guard canCheckForUpdates else { return }

        updaterController.checkForUpdates(sender)
        updateStatusText = "Checking"
    }

    private func startUpdater() {
        do {
            try updaterController.updater.start()
            didStartUpdater = true
            refreshUpdateAvailability()
        } catch {
            didStartUpdater = false
            updateStatusText = "Unavailable"
            ClickyMessageLogStore.shared.append(
                lane: "updater",
                direction: "event",
                event: "updater.start_failed",
                fields: ["error": error.localizedDescription]
            )
        }
    }
}
