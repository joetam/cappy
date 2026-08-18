import AppKit
import Sparkle

@MainActor
final class SoftwareUpdateController: NSObject {
    private static let releasesURL = URL(string: "https://github.com/joetam/cappy/releases/latest")

    private let updaterController: SPUStandardUpdaterController?

    override init() {
        if Bundle.main.object(forInfoDictionaryKey: "CappyEnableSoftwareUpdates") as? Bool == true {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            updaterController = nil
        }
        super.init()
    }

    static func validateConfiguration() throws {
        guard Bundle.main.object(forInfoDictionaryKey: "CappyEnableSoftwareUpdates") as? Bool == true else {
            throw NSError(
                domain: "ai.upriver.cappy.SoftwareUpdates",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Software updates are not enabled in this bundle."]
            )
        }

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        try updaterController.updater.start()
        withExtendedLifetime(updaterController) {}
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
        if let updaterController {
            item.target = updaterController
            item.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
            item.isEnabled = updaterController.updater.canCheckForUpdates
        } else {
            item.target = self
            item.action = #selector(showSourceBuildUpdateInstructions(_:))
        }
        return item
    }

    @objc private func showSourceBuildUpdateInstructions(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Automatic Updates Aren’t Available in This Build"
        alert.informativeText =
            "This copy of Cappy was built from source. Download an official signed release to use automatic updates."
        alert.addButton(withTitle: "View Releases")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let releasesURL = Self.releasesURL {
            NSWorkspace.shared.open(releasesURL)
        }
    }
}
