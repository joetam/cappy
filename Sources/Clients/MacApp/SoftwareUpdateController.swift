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
