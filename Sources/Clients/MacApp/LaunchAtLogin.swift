import Foundation
import OSLog
import ServiceManagement

@MainActor
final class LaunchAtLoginController {
    private let logger = Logger(subsystem: "ai.upriver.cappy", category: "LaunchAtLogin")
    private let service = SMAppService.mainApp
    private let defaults = UserDefaults.standard
    private let configuredKey = "launchAtLoginDefaultConfigured"

    var isEnabled: Bool { service.status == .enabled }

    func enableByDefaultIfNeeded() {
        guard !defaults.bool(forKey: configuredKey) else { return }
        switch service.status {
        case .enabled, .requiresApproval:
            defaults.set(true, forKey: configuredKey)
        case .notFound, .notRegistered:
            do {
                try service.register()
                defaults.set(true, forKey: configuredKey)
            } catch {
                logger.error("Could not enable Open at Login by default: \(error.localizedDescription, privacy: .public)")
            }
        @unknown default:
            return
        }
    }

    func toggle() throws {
        defaults.set(true, forKey: configuredKey)
        switch service.status {
        case .enabled:
            try service.unregister()
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        case .notFound, .notRegistered:
            try service.register()
        @unknown default:
            try service.register()
        }
    }
}
