import SwiftUI
import Sparkle

final class UpdaterController {
    /// Retain the controller itself — it owns the standard user driver that
    /// presents the update UI. Keeping only `.updater` would let the driver
    /// deallocate and the update dialogs would never appear.
    private let controller: SPUStandardUpdaterController
    private let delegate = UpdaterDelegate()

    var updater: SPUUpdater { controller.updater }

    init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

private class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://github.com/shkumbinhasani/wave/releases/latest/download/appcast.xml"
    }

    /// Allow updates without matching code signatures.
    /// We rely on EdDSA (SUPublicEDKey) for update validation instead.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        []
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // Allow all update checks
    }
}
