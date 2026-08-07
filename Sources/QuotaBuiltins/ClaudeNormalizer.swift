import Foundation
import QuotaContracts

public enum ClaudeNormalizer {
    /// Normalizes Claude's server-side OAuth usage payload. Meter discovery is
    /// intentionally data-driven so newly added model and feature limits do not
    /// require an app update.
    public static func meters(fromOAuthUsage value: JSONValue, observedAt: Date = Date()) -> [QuotaMeter] {
        guard let root = value.objectValue else { return [] }
        var meters: [QuotaMeter] = []

        for (key, rawValue) in root {
            guard !Self.nonRateLimitKeys.contains(key), let window = rawValue.objectValue else { continue }
            guard let rawPercent = NormalizerHelpers.number(window["utilization"] ?? window["percent"]) else { continue }
            let percent = min(max(rawPercent, 0), 100)
            let fraction = percent / 100
            let label = displayName(for: key)
            meters.append(
                QuotaMeter(
                    id: "claude.\(key)",
                    displayName: label,
                    kind: .rollingWindow,
                    unit: .percent,
                    scope: MeterScope(kind: scopeKind(for: key), id: key, displayName: label),
                    used: percent,
                    limit: 100,
                    remaining: max(0, 100 - percent),
                    usedFraction: fraction,
                    resetsAt: NormalizerHelpers.date(window["resets_at"]),
                    status: NormalizerHelpers.meterStatus(usedFraction: fraction),
                    priority: priority(for: key),
                    source: "claude.oauth.usage"
                ))
        }

        // Newer payloads also expose a normalized list. Treat it as a fallback
        // for shapes that do not yet have a top-level bucket.
        if let limits = root["limits"]?.arrayValue {
            for rawLimit in limits {
                guard let limit = rawLimit.objectValue,
                    let rawPercent = NormalizerHelpers.number(limit["percent"] ?? limit["utilization"])
                else { continue }
                let key = limitKey(limit)
                guard !meters.contains(where: { $0.id == "claude.\(key)" }) else { continue }
                let percent = min(max(rawPercent, 0), 100)
                let fraction = percent / 100
                let label = limitDisplayName(limit, key: key)
                meters.append(
                    QuotaMeter(
                        id: "claude.\(key)",
                        displayName: label,
                        kind: .rollingWindow,
                        unit: .percent,
                        scope: MeterScope(kind: scopeKind(for: key), id: key, displayName: label),
                        used: percent,
                        limit: 100,
                        remaining: max(0, 100 - percent),
                        usedFraction: fraction,
                        resetsAt: NormalizerHelpers.date(limit["resets_at"]),
                        status: NormalizerHelpers.meterStatus(usedFraction: fraction),
                        priority: priority(for: key),
                        source: "claude.oauth.usage.limits"
                    ))
            }
        }

        if let spend = spendMeter(root) { meters.append(spend) }
        return meters.sorted { ($0.priority, $0.displayName) < ($1.priority, $1.displayName) }
    }

    public static func snapshot(
        profile: Profile,
        authStatus: JSONValue,
        cachedMeters: [QuotaMeter],
        cacheObservedAt: Date? = nil,
        observedAt: Date = Date()
    ) -> AccountSnapshot {
        let loggedIn = authStatus["loggedIn"]?.boolValue == true
        guard loggedIn else {
            return AccountSnapshot(
                profileID: profile.id,
                provider: BuiltinProviders.claude,
                profileLabel: profile.label,
                authenticationState: .unauthenticated,
                authenticationMethod: authStatus["authMethod"]?.stringValue,
                meters: [],
                observedAt: observedAt,
                freshness: .unavailable,
                message: "Sign in to Claude to read account details."
            )
        }

        let plan = authStatus["subscriptionType"]?.stringValue
        let identity = AccountIdentity(
            displayName: nil,
            email: authStatus["email"]?.stringValue,
            organization: authStatus["orgName"]?.stringValue,
            stableID: authStatus["orgId"]?.stringValue
        )
        let cacheDate = cacheObservedAt ?? observedAt
        let cacheIsStale = observedAt.timeIntervalSince(cacheDate) > 30 * 60
        let meters = cachedMeters.map { meter -> QuotaMeter in
            var copy = meter
            if cacheIsStale { copy.status = .stale }
            return copy
        }
        let emptyMessage = meters.isEmpty ? "Claude usage is temporarily unavailable." : nil
        return AccountSnapshot(
            profileID: profile.id,
            provider: BuiltinProviders.claude,
            profileLabel: profile.label,
            authenticationState: .authenticated,
            authenticationMethod: authStatus["authMethod"]?.stringValue,
            identity: identity,
            subscription: Subscription(planName: plan),
            meters: meters,
            observedAt: cacheObservedAt ?? observedAt,
            freshness: meters.isEmpty ? .unavailable : (cacheIsStale ? .stale : .fresh),
            message: emptyMessage
        )
    }

    private static let nonRateLimitKeys: Set<String> = [
        "extra_usage", "limits", "member_dashboard_available", "spend",
    ]

    private static func spendMeter(_ root: [String: JSONValue]) -> QuotaMeter? {
        if let spend = root["spend"]?.objectValue,
            spend["enabled"]?.boolValue == true,
            let rawPercent = NormalizerHelpers.number(spend["percent"])
        {
            return percentageSpendMeter(percent: rawPercent, source: "claude.oauth.usage.spend")
        }
        if let extra = root["extra_usage"]?.objectValue,
            extra["is_enabled"]?.boolValue == true,
            let rawPercent = NormalizerHelpers.number(extra["utilization"])
        {
            return percentageSpendMeter(percent: rawPercent, source: "claude.oauth.usage.extra_usage")
        }
        return nil
    }

    private static func percentageSpendMeter(percent rawPercent: Double, source: String) -> QuotaMeter {
        let percent = min(max(rawPercent, 0), 100)
        let fraction = percent / 100
        return QuotaMeter(
            id: "claude.usage_credits",
            displayName: "Usage credits",
            kind: .spend,
            unit: .percent,
            scope: MeterScope(kind: "account", id: "usage_credits", displayName: "Usage credits"),
            used: percent,
            limit: 100,
            remaining: max(0, 100 - percent),
            usedFraction: fraction,
            status: NormalizerHelpers.meterStatus(usedFraction: fraction),
            priority: 50,
            source: source
        )
    }

    private static func limitKey(_ limit: [String: JSONValue]) -> String {
        let kind = limit["kind"]?.stringValue?.lowercased() ?? "usage"
        switch kind {
        case "session": return "five_hour"
        case "weekly_all": return "seven_day"
        default:
            if let model = limit["scope"]?["model"]?["display_name"]?.stringValue {
                return "seven_day_\(slug(model))"
            }
            return slug(kind)
        }
    }

    private static func limitDisplayName(_ limit: [String: JSONValue], key: String) -> String {
        if let model = limit["scope"]?["model"]?["display_name"]?.stringValue, !model.isEmpty {
            return "\(model) · week"
        }
        return displayName(for: key)
    }

    private static func slug(_ value: String) -> String {
        let parts = value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let result = parts.joined(separator: "_")
        return result.isEmpty ? "usage" : String(result.prefix(80))
    }

    private static func displayName(for key: String) -> String {
        let lower = key.lowercased()
        if lower == "five_hour" { return "Current session" }
        if lower == "seven_day" { return "Current week" }
        if lower == "seven_day_oauth_apps" { return "OAuth apps · week" }
        if lower == "seven_day_cowork" { return "Cowork · week" }
        let model: String?
        if lower.contains("fable") {
            model = "Fable"
        } else if lower.contains("opus") {
            model = "Opus"
        } else if lower.contains("sonnet") {
            model = "Sonnet"
        } else {
            model = nil
        }
        if lower.hasPrefix("seven_day"), let model { return "\(model) · week" }
        if lower.hasPrefix("five_hour"), let model { return "\(model) · session" }
        return NormalizerHelpers.humanize(key)
    }

    private static func scopeKind(for key: String) -> String {
        let lower = key.lowercased()
        if lower == "five_hour" || lower == "seven_day" { return "account" }
        return lower.hasPrefix("seven_day_") ? "model-family" : "account"
    }

    private static func priority(for key: String) -> Int {
        switch key {
        case "five_hour": 0
        case "seven_day": 10
        default: 20
        }
    }
}
