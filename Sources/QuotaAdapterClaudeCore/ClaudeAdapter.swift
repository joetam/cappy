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

// Versioned independently of the old CLI-email binding: unverified legacy
// cache entries must never be adopted as verified account readings.
package func cacheBinding(account: ClaudeOAuthAccount) -> String {
    let parts = ["claude-oauth-profile-v1", account.accountID, account.organizationID]
    let data = Data(parts.map { "\($0.utf8.count):\($0)" }.joined().utf8)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

package func refresh(profile: Profile, context: AdapterContext, client: ClaudeOAuthUsageClient) async throws -> AccountSnapshot {
    let result: ClaudeUsageFetchResult
    do {
        result = try await client.fetch(profile: profile)
    } catch ClaudeUsageClientError.credentialsUnavailable {
        return unavailableSnapshot(profile: profile, authenticationState: .unauthenticated)
    } catch ClaudeUsageClientError.unauthorized {
        return unavailableSnapshot(profile: profile, authenticationState: .expired)
    }
    let binding = cacheBinding(account: result.account)
    let cached = loadMeterCache(profile: profile, context: context, accountBinding: binding)
    let liveMeters = result.value.map { ClaudeNormalizer.meters(fromOAuthUsage: $0, observedAt: result.observedAt) } ?? []
    let hasLiveMeters = !liveMeters.isEmpty
    let meters = hasLiveMeters ? liveMeters : (cached?.meters ?? [])
    let observedAt = hasLiveMeters ? result.observedAt : cached?.observedAt
    if hasLiveMeters {
        saveMeterCache(profile: profile, context: context, accountBinding: binding, meters: liveMeters, observedAt: result.observedAt)
    }
    return ClaudeNormalizer.snapshot(
        profile: profile,
        account: result.account,
        cachedMeters: meters,
        cacheObservedAt: observedAt,
        usageResult: result.value,
        usageUnavailable: !hasLiveMeters
    )
}

private func unavailableSnapshot(profile: Profile, authenticationState: AuthenticationState) -> AccountSnapshot {
    AccountSnapshot(
        profileID: profile.id,
        provider: BuiltinProviders.claude,
        profileLabel: profile.label,
        authenticationState: authenticationState,
        meters: [],
        freshness: .unavailable,
        message: "Sign in to Claude to read account details."
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
        do {
            return AdapterResponse(
                ok: true, snapshot: try await refresh(profile: profile, context: request.context, client: ClaudeOAuthUsageClient()))
        } catch {
            return AdapterResponse(ok: false, message: error.localizedDescription)
        }
    case .primeQuota:
        return AdapterResponse(ok: false, message: "Quota priming is only supported for Codex")
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

public enum ClaudeAdapter {
    public static func run() async {
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
