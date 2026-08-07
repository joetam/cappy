import CryptoKit
import Foundation
import QuotaBuiltins
import QuotaContracts
import QuotaProviderKit

private func loadMeterCache(profile: Profile, context: AdapterContext, accountBinding: String?) -> MeterCache? {
    guard let accountBinding,
        let path = context.quotaCachePath,
        let attributes = try? FileManager.default.attributesOfItem(atPath: path),
        attributes[.type] as? FileAttributeType == .typeRegular,
        ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576,
        let data = FileManager.default.contents(atPath: path),
        let cache = try? JSONDecoder.quota.decode(MeterCache.self, from: data),
        cache.contractVersion == quotaContractVersion,
        cache.profileID == profile.id,
        cache.accountBinding == accountBinding,
        cache.meters.count <= 100
    else { return nil }
    return cache
}

private func saveMeterCache(
    profile: Profile,
    context: AdapterContext,
    accountBinding: String?,
    meters: [QuotaMeter],
    observedAt: Date
) {
    guard !meters.isEmpty, meters.count <= 100, let accountBinding, let path = context.quotaCachePath else { return }
    let cache = MeterCache(
        profileID: profile.id,
        accountBinding: accountBinding,
        meters: meters,
        observedAt: observedAt
    )
    guard let data = try? JSONEncoder.quota.encode(cache), data.count <= 1_048_576 else { return }
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    } catch {
        // The server still receives this live snapshot. Cache failures are not
        // allowed to expose paths or credential-adjacent details to clients.
    }
}

private func cacheBinding(auth: JSONValue) -> String? {
    let parts = [auth["orgId"]?.stringValue, auth["email"]?.stringValue]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func refresh(profile: Profile, context: AdapterContext) async throws -> AccountSnapshot {
    guard
        let claude = VendorExecutable.resolve("claude", overrideEnvironmentKey: "CAPPY_CLAUDE_PATH")
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

    let binding = cacheBinding(auth: auth)
    let cached = loadMeterCache(profile: profile, context: context, accountBinding: binding)
    var meters = cached?.meters ?? []
    var observedAt = cached?.observedAt

    if auth["loggedIn"]?.boolValue == true {
        do {
            let usage = try await ClaudeOAuthUsageClient().fetch(profile: profile)
            let liveMeters = ClaudeNormalizer.meters(fromOAuthUsage: usage.value, observedAt: usage.observedAt)
            if !liveMeters.isEmpty {
                meters = liveMeters
                observedAt = usage.observedAt
                saveMeterCache(
                    profile: profile,
                    context: context,
                    accountBinding: binding,
                    meters: liveMeters,
                    observedAt: usage.observedAt
                )
            } else if meters.isEmpty {
                throw ClaudeUsageClientError.invalidResponse
            }
        } catch {
            guard !meters.isEmpty else { throw ClaudeUsageClientError.responseUnavailable }
        }
    }

    return ClaudeNormalizer.snapshot(
        profile: profile,
        authStatus: auth,
        cachedMeters: meters,
        cacheObservedAt: observedAt
    )
}

private func handle(_ request: AdapterRequest) async -> AdapterResponse {
    guard request.protocolVersion == adapterProtocolVersion else {
        return AdapterResponse(ok: false, message: "Unsupported adapter protocol version")
    }
    switch request.operation {
    case .describe:
        return AdapterResponse(ok: true, provider: BuiltinProviders.claude)
    case .refresh:
        guard let profile = request.profile else { return AdapterResponse(ok: false, message: "Profile is required") }
        do { return AdapterResponse(ok: true, snapshot: try await refresh(profile: profile, context: request.context)) } catch {
            return AdapterResponse(ok: false, message: error.localizedDescription)
        }
    case .prepareLogin:
        guard let profile = request.profile,
            let claude = VendorExecutable.resolve("claude", overrideEnvironmentKey: "CAPPY_CLAUDE_PATH")
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
        // OAuth usage is read directly; no status-line hook is required.
        return AdapterResponse(ok: true, message: "Claude usage refreshes automatically.")
    case .removeManagedCredentials:
        guard let profile = request.profile, profile.isManaged, !profile.isDefault else {
            return AdapterResponse(ok: false, message: "Only managed Claude credentials can be removed")
        }
        do {
            try ClaudeOAuthUsageClient.removeManagedCredentials(profile: profile)
            return AdapterResponse(ok: true)
        } catch {
            return AdapterResponse(ok: false, message: "Claude’s isolated Keychain credential could not be removed.")
        }
    }
}

@main
private struct ClaudeAdapterMain {
    static func main() async {
        do {
            let input = try BoundedInput.read()
            let request = try JSONDecoder.quota.decode(AdapterRequest.self, from: input)
            FileHandle.standardOutput.write(try JSONEncoder.quota.encode(await handle(request)))
        } catch {
            let response = AdapterResponse(ok: false, message: "Invalid adapter request: \(error.localizedDescription)")
            FileHandle.standardOutput.write((try? JSONEncoder.quota.encode(response)) ?? Data())
        }
    }
}
