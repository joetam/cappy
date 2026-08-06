import Foundation
import QuotaBuiltins
import QuotaContracts
import QuotaProviderKit

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func refresh(profile: Profile, context: AdapterContext) throws -> AccountSnapshot {
    guard
        let claude = VendorExecutable.resolve(
            "claude",
            overrideEnvironmentKey: "CAPPY_CLAUDE_PATH",
            legacyOverrideEnvironmentKey: "QUOTABAR_CLAUDE_PATH"
        )
    else {
        throw ProcessRunnerError.executableNotFound("claude")
    }
    let result = try ProcessRunner.run(
        claude,
        arguments: ["auth", "status", "--json"],
        environment: profile.isDefault ? [:] : ["CLAUDE_CONFIG_DIR": profile.configPath],
        timeout: 15
    )
    guard let auth = try? JSONDecoder.quota.decode(JSONValue.self, from: result.stdout) else {
        throw NSError(
            domain: "ai.upriver.cappy.Claude", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Claude returned invalid authentication status"])
    }
    var meters: [QuotaMeter] = []
    var cacheDate: Date?
    if let path = context.quotaCachePath,
        let attributes = try? FileManager.default.attributesOfItem(atPath: path),
        attributes[.type] as? FileAttributeType == .typeRegular,
        ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576,
        let data = FileManager.default.contents(atPath: path),
        let cache = try? JSONDecoder.quota.decode(MeterCache.self, from: data),
        cache.contractVersion == quotaContractVersion,
        cache.profileID == profile.id,
        cache.meters.count <= 100
    {
        meters = cache.meters
        cacheDate = cache.observedAt
    }
    return ClaudeNormalizer.snapshot(profile: profile, authStatus: auth, cachedMeters: meters, cacheObservedAt: cacheDate)
}

private func configure(profile: Profile, context: AdapterContext) throws -> [String] {
    guard let executable = context.clientExecutablePath else {
        return ["Quota bridge was not installed because the client path is unavailable."]
    }
    let directory = URL(fileURLWithPath: profile.configPath, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let settingsURL = directory.appendingPathComponent("settings.json")
    var settings: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: settingsURL.path) {
        let attributes = try FileManager.default.attributesOfItem(atPath: settingsURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576
        else {
            throw NSError(
                domain: "ai.upriver.cappy.Claude", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Claude settings are not a regular JSON file of a safe size; they were left unchanged."
                ])
        }
        let data = try Data(contentsOf: settingsURL)
        guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "ai.upriver.cappy.Claude", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Claude settings could not be read as a JSON object; they were left unchanged."])
        }
        settings = existing
    }
    if let existingValue = settings["statusLine"] {
        let command = (existingValue as? [String: Any])?["command"] as? String
        let ownedSuffix = " bridge capture --profile \(shellQuote(profile.id))"
        guard command?.hasSuffix(ownedSuffix) == true else {
            return ["Claude already has a status line, so it was left unchanged."]
        }
    }
    let command = "\(shellQuote(executable)) bridge capture --profile \(shellQuote(profile.id))"
    settings["statusLine"] = ["type": "command", "command": command, "padding": 0]
    let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: settingsURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    return []
}

private func handle(_ request: AdapterRequest) -> AdapterResponse {
    guard request.protocolVersion == adapterProtocolVersion else {
        return AdapterResponse(ok: false, message: "Unsupported adapter protocol version")
    }
    switch request.operation {
    case .describe:
        return AdapterResponse(ok: true, provider: BuiltinProviders.claude)
    case .refresh:
        guard let profile = request.profile else { return AdapterResponse(ok: false, message: "Profile is required") }
        do { return AdapterResponse(ok: true, snapshot: try refresh(profile: profile, context: request.context)) } catch {
            return AdapterResponse(ok: false, message: error.localizedDescription)
        }
    case .prepareLogin:
        guard let profile = request.profile,
            let claude = VendorExecutable.resolve(
                "claude",
                overrideEnvironmentKey: "CAPPY_CLAUDE_PATH",
                legacyOverrideEnvironmentKey: "QUOTABAR_CLAUDE_PATH"
            )
        else {
            return AdapterResponse(ok: false, message: "Claude CLI is not installed")
        }
        return AdapterResponse(
            ok: true,
            loginCommand: LoginCommand(
                executable: claude,
                arguments: ["auth", "login", "--claudeai"],
                environment: profile.isDefault ? [:] : ["CLAUDE_CONFIG_DIR": profile.configPath],
                requiresPTY: true
            ))
    case .configure:
        guard let profile = request.profile else { return AdapterResponse(ok: false, message: "Profile is required") }
        do {
            let warnings = try configure(profile: profile, context: request.context)
            return AdapterResponse(
                ok: true,
                message: warnings.isEmpty ? "Quota capture is set up. Claude Code will update it as you use it." : nil,
                warnings: warnings
            )
        } catch { return AdapterResponse(ok: false, message: "Could not configure Claude quota bridge: \(error.localizedDescription)") }
    }
}

do {
    let input = try BoundedInput.read()
    let request = try JSONDecoder.quota.decode(AdapterRequest.self, from: input)
    FileHandle.standardOutput.write(try JSONEncoder.quota.encode(handle(request)))
} catch {
    let response = AdapterResponse(ok: false, message: "Invalid adapter request: \(error.localizedDescription)")
    FileHandle.standardOutput.write((try? JSONEncoder.quota.encode(response)) ?? Data())
}
