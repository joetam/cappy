import Foundation
import QuotaBuiltins
import QuotaContracts
import QuotaProviderKit

enum SelfTestError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { message } else { nil }
    }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SelfTestError.failed(message) }
}

func json(_ source: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
}

do {
    let meter = QuotaMeter(
        id: "future-provider.never-seen-before",
        displayName: "Moonshot · month",
        kind: .rollingWindow,
        unit: .percent,
        scope: MeterScope(kind: "model-family", id: "moonshot"),
        used: 12.5,
        limit: 100,
        remaining: 87.5,
        usedFraction: 0.125,
        resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
        windowSeconds: 2_592_000,
        source: "fixture"
    )
    let snapshot = AccountSnapshot(
        profileID: "future-default",
        provider: ProviderDescriptor(id: "future", displayName: "Future"),
        profileLabel: "Future",
        authenticationState: .authenticated,
        subscription: Subscription(planName: "Ultra"),
        meters: [meter],
        freshness: .fresh
    )
    let roundTrip = try JSONDecoder().decode(AccountSnapshot.self, from: JSONEncoder().encode(snapshot))
    try check(roundTrip.meters == [meter], "Arbitrary meter round-trip failed")
    try check(roundTrip.subscription?.planName == "Ultra", "Plan round-trip failed")

    let legacyProvider = try JSONDecoder().decode(
        ProviderDescriptor.self,
        from: Data(#"{"id":"legacy","displayName":"Legacy","symbolName":"circle","accentHex":"112233"}"#.utf8)
    )
    try check(legacyProvider.icon == nil, "Provider icon addition broke legacy descriptor decoding")
    try check(
        BuiltinProviders.codex.icon?.bundledAssetName == "ProviderCodex"
            && BuiltinProviders.codex.icon?.applicationBundleIdentifier == "com.openai.codex"
            && BuiltinProviders.codex.icon?.applicationResourceName == "icon-codex-light"
            && BuiltinProviders.codex.icon?.renderingMode == nil
            && BuiltinProviders.claude.icon?.bundledAssetName == "ProviderClaude",
        "Built-in adapters did not declare their provider icons")

    let clamped = QuotaMeter(
        id: "clamped", displayName: "Clamped", kind: .rollingWindow, unit: .percent, scope: .init(kind: "account", id: "a"),
        usedFraction: 1.5, source: "test")
    try check(clamped.usedFraction == 1, "Fraction was not clamped")

    let privateProfile = Profile(id: "private", providerID: "future", label: "Private", configPath: "/private/provider", isManaged: true)
    let publicProfileJSON = String(decoding: try JSONEncoder.quota.encode(ProfileSummary(privateProfile)), as: UTF8.self)
    try check(
        !publicProfileJSON.contains("configPath") && !publicProfileJSON.contains("/private/provider"),
        "Public profile metadata leaked its configuration path")

    let cleanEnvironment = ProcessEnvironment.sanitized([
        "HOME": "/tmp/home",
        "PATH": "/usr/bin:/bin",
        "OPENAI_API_KEY": "secret",
        "ANTHROPIC_API_KEY": "secret",
        "CAPPY_STATE_DIR": "/tmp/state",
        "QUOTABAR_STATE_DIR": "/tmp/legacy-state",
    ])
    try check(cleanEnvironment["HOME"] == "/tmp/home", "Safe HOME was removed from the process environment")
    try check(cleanEnvironment["CAPPY_STATE_DIR"] == "/tmp/state", "Cappy override was removed from the process environment")
    try check(
        cleanEnvironment["QUOTABAR_STATE_DIR"] == "/tmp/legacy-state",
        "Legacy state override was removed from the process environment"
    )
    try check(
        cleanEnvironment["OPENAI_API_KEY"] == nil && cleanEnvironment["ANTHROPIC_API_KEY"] == nil,
        "Shell credentials leaked into an adapter environment")

    let legacyCacheData = Data(
        #"{"contractVersion":1,"profileID":"legacy","meters":[],"observedAt":"2026-08-07T00:00:00Z"}"#.utf8)
    let legacyCache = try JSONDecoder.quota.decode(MeterCache.self, from: legacyCacheData)
    try check(legacyCache.accountBinding == nil, "Legacy meter-cache decoding was broken")

    let largeOutput = try ProcessRunner.run(
        "/bin/sh",
        arguments: ["-c", "/usr/bin/head -c 200000 /dev/zero"],
        timeout: 5,
        maxOutputBytes: 32_768
    )
    try check(largeOutput.status == 0 && largeOutput.stdout.count == 32_768, "Large subprocess output was not drained and bounded")

    let claude = try json(
        #"""
        {
          "rate_limits": {
            "five_hour": {"used_percentage": 23.5, "resets_at": 1800000000},
            "seven_day_fable": {"used_percentage": 51, "resets_at": 1800100000},
            "cinder_cove": {"used_percentage": 7, "resets_at": 1800200000}
          }
        }
        """#)
    let claudeMeters = ClaudeNormalizer.meters(fromStatusLine: claude)
    try check(claudeMeters.count == 3, "Claude dynamic meter discovery failed")
    try check(claudeMeters.first { $0.id == "claude.seven_day_fable" }?.displayName == "Fable · week", "Fable meter normalization failed")
    try check(claudeMeters.first { $0.id == "claude.cinder_cove" }?.displayName == "Cinder Cove", "Unknown Claude meter was dropped")

    let claudeOAuth = try json(
        #"""
        {
          "five_hour": {"utilization": 23.5, "resets_at": "2027-01-15T12:30:00.123456+00:00"},
          "seven_day": {"utilization": 51, "resets_at": "2027-01-21T12:30:00+00:00"},
          "seven_day_fable": {"utilization": 7, "resets_at": "2027-01-21T12:30:00+00:00"},
          "cinder_cove": {"utilization": 12, "resets_at": "2027-01-21T12:30:00+00:00"},
          "extra_usage": {"is_enabled": false},
          "spend": {"enabled": true, "percent": 15},
          "limits": [
            {"kind": "session", "group": "session", "percent": 23.5, "resets_at": "2027-01-15T12:30:00+00:00"},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 9, "scope": {"model": {"display_name": "Future Model"}}}
          ]
        }
        """#)
    let oauthMeters = ClaudeNormalizer.meters(fromOAuthUsage: claudeOAuth)
    try check(oauthMeters.first { $0.id == "claude.five_hour" }?.resetsAt != nil, "Claude ISO reset parsing failed")
    try check(
        oauthMeters.first { $0.id == "claude.seven_day_fable" }?.displayName == "Fable · week",
        "OAuth model meter normalization failed")
    try check(oauthMeters.first { $0.id == "claude.cinder_cove" }?.displayName == "Cinder Cove", "OAuth dynamic bucket was dropped")
    try check(
        oauthMeters.first { $0.id == "claude.seven_day_future_model" }?.displayName == "Future Model · week",
        "OAuth limits fallback failed")
    try check(oauthMeters.first { $0.id == "claude.usage_credits" }?.usedFraction == 0.15, "Claude usage-credit meter failed")
    try check(oauthMeters.filter { $0.id == "claude.five_hour" }.count == 1, "Claude OAuth meters were duplicated")

    let claudeProfile = Profile(
        id: "claude-team", providerID: "anthropic-claude", label: "Team", configPath: "/tmp/claude-team", isManaged: true)
    let teamAuth = try json(#"{"loggedIn":true,"subscriptionType":"team","email":"team@example.com"}"#)
    let teamSnapshot = ClaudeNormalizer.snapshot(profile: claudeProfile, authStatus: teamAuth, cachedMeters: oauthMeters)
    try check(teamSnapshot.authenticationState == .authenticated, "Claude Team authentication was lost")
    try check(teamSnapshot.subscription?.planName == "team", "Claude Team plan was lost")
    try check(teamSnapshot.freshness == .fresh, "Claude Team OAuth usage was not accepted")
    try check(!teamSnapshot.meters.isEmpty, "Claude Team quota meters are missing")

    let profile = Profile(
        id: "codex", providerID: "openai-codex", label: "Personal", configPath: "/tmp/codex", isManaged: false, isDefault: true)
    let account = try json(#"{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro"},"requiresOpenaiAuth":true}"#)
    let limits = try json(
        #"""
        {
          "rateLimitsByLimitId": {
            "codex": {"limitId":"codex","primary":{"usedPercent":14,"windowDurationMins":10080,"resetsAt":1800000000}},
            "codex_spark": {"limitId":"codex_spark","limitName":"Codex Spark","primary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1800000100}}
          }
        }
        """#)
    let codex = CodexNormalizer.snapshot(profile: profile, accountResult: account, rateLimitResult: limits)
    try check(codex.subscription?.planName == "pro", "Codex plan normalization failed")
    try check(Set(codex.meters.map(\.id)) == Set(["codex.primary", "codex_spark.primary"]), "Codex dynamic bucket normalization failed")

    let numericCredits = try json(#"{"rateLimits":{"limitId":"codex","credits":{"balance":12.5,"hasCredits":true}}}"#)
    let codexWithCredits = CodexNormalizer.snapshot(profile: profile, accountResult: account, rateLimitResult: numericCredits)
    try check(
        codexWithCredits.meters.first(where: { $0.id == "codex.credits" })?.remaining == 12.5,
        "Numeric Codex credit balance was not normalized")

    print("quota-selftest: all checks passed")
} catch {
    FileHandle.standardError.write(Data("quota-selftest: \(error.localizedDescription)\n".utf8))
    exit(1)
}
