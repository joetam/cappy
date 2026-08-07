import Foundation

public enum VendorExecutable {
    public static func resolve(
        _ name: String,
        overrideEnvironmentKey: String
    ) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[overrideEnvironmentKey], override.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: override)
        {
            return override
        }
        if let direct = ProcessRunner.resolveExecutable(name) { return direct }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let fixed = [
            home.appendingPathComponent(".local/bin/\(name)").path,
            home.appendingPathComponent(".npm-global/bin/\(name)").path,
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        if let match = fixed.first(where: FileManager.default.isExecutableFile(atPath:)) { return match }

        let nvm = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            let candidates =
                versions
                .map { $0.appendingPathComponent("bin/\(name)").path }
                .filter { FileManager.default.isExecutableFile(atPath: $0) }
                .sorted()
            return candidates.last
        }
        return nil
    }
}
