import SwiftUI
import Sparkle

final class UpdaterController: ObservableObject {
    let updater: SPUUpdater
    private let delegate = UpdaterDelegate()

    init() {
        self.updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        ).updater
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
