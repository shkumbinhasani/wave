import SwiftUI
import Sparkle

/// Wraps SUUpdater for SwiftUI access.
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
        // Points to the appcast hosted on GitHub Releases
        "https://github.com/shkumbinhasani/wave/releases/latest/download/appcast.xml"
    }
}
