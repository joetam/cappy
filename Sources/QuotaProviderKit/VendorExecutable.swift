import Darwin
import Foundation

public enum VendorExecutable {
    enum CodexInstallationMethod: String, Sendable {
        case openAIStandaloneInstaller = "OpenAI standalone installer"
        case homebrew = "Homebrew"
        case npmGlobal = "npm global install"
    }

    struct CodexInstallationLocation: Equatable, Sendable {
        let installationMethods: [CodexInstallationMethod]
        let executablePath: String
    }

    private static let cachedInteractiveLoginShellPATH = readInteractiveLoginShellPATH()

    /// Resolves the Codex CLI in the same order a user would expect:
    /// an explicit override, the app's PATH, the login shell's PATH, then
    /// deterministic locations used by common Codex installation methods.
    public static func resolveCodex() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = resolveExecutableFromExplicitOverride(
            environmentKey: "CAPPY_CODEX_PATH",
            environment: environment
        ) {
            return override
        }
        if let inherited = resolveExecutableFromInheritedPATH("codex", environment: environment) {
            return inherited
        }
        if let shell = resolveExecutableFromInteractiveLoginShellPATH("codex") {
            return shell
        }
        return resolveCodexFromCommonInstallationLocations()
    }

    public static func resolve(
        _ name: String,
        overrideEnvironmentKey: String
    ) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = resolveExecutableFromExplicitOverride(
            environmentKey: overrideEnvironmentKey,
            environment: environment
        ) {
            return override
        }
        if let direct = resolveExecutableFromInheritedPATH(name, environment: environment) { return direct }

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

    static func resolveExecutableFromExplicitOverride(
        environmentKey: String,
        environment: [String: String]
    ) -> String? {
        guard let override = environment[environmentKey], override.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: override)
        else {
            return nil
        }
        return override
    }

    static func resolveExecutableFromInheritedPATH(
        _ executableName: String,
        environment: [String: String]
    ) -> String? {
        resolveExecutableFromPATH(executableName, path: environment["PATH"])
    }

    static func resolveExecutableFromInteractiveLoginShellPATH(_ executableName: String) -> String? {
        resolveExecutableFromPATH(executableName, path: cachedInteractiveLoginShellPATH)
    }

    static func resolveExecutableFromPATH(_ executableName: String, path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return ProcessRunner.resolveExecutable(executableName, environment: ["PATH": path])
    }

    static func commonCodexInstallationLocations(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [CodexInstallationLocation] {
        // Version managers (nvm, Volta, asdf, mise) and custom CODEX_INSTALL_DIR
        // values are intentionally resolved from PATH instead of guessed here.
        [
            CodexInstallationLocation(
                installationMethods: [.openAIStandaloneInstaller],
                executablePath: homeDirectory.appendingPathComponent(".local/bin/codex").path
            ),
            CodexInstallationLocation(
                installationMethods: [.homebrew, .npmGlobal],
                executablePath: "/opt/homebrew/bin/codex"
            ),
            CodexInstallationLocation(
                installationMethods: [.homebrew, .npmGlobal],
                executablePath: "/usr/local/bin/codex"
            ),
            CodexInstallationLocation(
                installationMethods: [.npmGlobal],
                executablePath: homeDirectory.appendingPathComponent(".npm-global/bin/codex").path
            ),
        ]
    }

    static func resolveCodexFromCommonInstallationLocations(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        commonCodexInstallationLocations(homeDirectory: homeDirectory)
            .map(\.executablePath)
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    static func readInteractiveLoginShellPATH() -> String? {
        guard let shellPath = configuredLoginShellPath() else { return nil }
        let marker = "__CAPPY_LOGIN_SHELL_PATH_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let command = "printf '\\n\(marker)%s\(marker)\\n' \"$PATH\""

        guard
            let result = try? ProcessRunner.run(
                shellPath,
                arguments: ["-ilc", command],
                timeout: 5,
                maxOutputBytes: 64 * 1024
            ),
            result.status == 0
        else {
            return nil
        }
        return extractInteractiveLoginShellPATH(from: result.stdoutString, marker: marker)
    }

    static func extractInteractiveLoginShellPATH(from output: String, marker: String) -> String? {
        guard let openingMarker = output.range(of: marker) else { return nil }
        let remainder = output[openingMarker.upperBound...]
        guard let closingMarker = remainder.range(of: marker) else { return nil }
        let path = String(remainder[..<closingMarker.lowerBound])
        guard !path.isEmpty, !path.contains("\n"), !path.contains("\r") else { return nil }
        return path
    }

    private static func configuredLoginShellPath() -> String? {
        if let passwordEntry = getpwuid(getuid()), let shell = passwordEntry.pointee.pw_shell {
            let path = String(cString: shell)
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        if let path = ProcessInfo.processInfo.environment["SHELL"], path.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: path)
        {
            return path
        }
        return nil
    }
}
