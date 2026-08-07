import Foundation
import QuotaContracts

public enum ClaudeNormalizer {
    public static func meters(fromStatusLine value: JSONValue, observedAt: Date = Date()) -> [QuotaMeter] {
        guard let rateLimits = value["rate_limits"]?.objectValue else { return [] }
        return rateLimits.compactMap { key, rawValue in
            guard let window = rawValue.objectValue else { return nil }
            let percent = NormalizerHelpers.number(window["used_percentage"])
            let fraction = percent.map { $0 / 100 }
            let label = displayName(for: key)
            return QuotaMeter(
                id: "claude.\(key)",
                displayName: label,
                kind: .rollingWindow,
                unit: .percent,
                scope: MeterScope(kind: scopeKind(for: key), id: key, displayName: label),
                used: percent,
                limit: 100,
                remaining: percent.map { max(0, 100 - $0) },
                usedFraction: fraction,
                resetsAt: NormalizerHelpers.date(epoch: NormalizerHelpers.number(window["resets_at"])),
                status: NormalizerHelpers.meterStatus(usedFraction: fraction),
                priority: priority(for: key),
                source: "claude.statusLine.rate_limits"
            )
        }.sorted { ($0.priority, $0.displayName) < ($1.priority, $1.displayName) }
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
        let normalizedPlan = plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let quotaIsDocumentedForPlan = normalizedPlan.map { $0.contains("pro") || $0.contains("max") } ?? false
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
        let emptyMessage: String?
        if meters.isEmpty, let plan, !quotaIsDocumentedForPlan {
            emptyMessage = "Claude Code doesn’t expose \(plan.capitalized) quota through its documented status-line feed."
        } else if meters.isEmpty {
            emptyMessage = "Set up quota capture, then use Claude Code normally."
        } else {
            emptyMessage = nil
        }
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
            freshness: meters.isEmpty ? (quotaIsDocumentedForPlan ? .pending : .unavailable) : (cacheIsStale ? .stale : .fresh),
            message: emptyMessage
        )
    }

    private static func displayName(for key: String) -> String {
        let lower = key.lowercased()
        if lower == "five_hour" { return "Current session" }
        if lower == "seven_day" { return "Current week" }
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
        return lower.contains("fable") || lower.contains("opus") || lower.contains("sonnet") ? "model-family" : "account"
    }

    private static func priority(for key: String) -> Int {
        switch key {
        case "five_hour": 0
        case "seven_day": 10
        default: 20
        }
    }
}
