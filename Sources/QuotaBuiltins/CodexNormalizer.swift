import Foundation
import QuotaContracts

public enum CodexNormalizer {
    public static func snapshot(
        profile: Profile,
        accountResult: JSONValue,
        rateLimitResult: JSONValue,
        billingResult: JSONValue? = nil,
        observedAt: Date = Date()
    ) -> AccountSnapshot {
        let account = accountResult["account"]?.objectValue
        guard let account else {
            return AccountSnapshot(
                profileID: profile.id,
                provider: BuiltinProviders.codex,
                profileLabel: profile.label,
                authenticationState: .unauthenticated,
                meters: [],
                observedAt: observedAt,
                freshness: .unavailable,
                message: "Sign in to Codex to read quota."
            )
        }

        let entitlement = billingResult?["entitlement"]
        let hasActiveSubscription = entitlement?["has_active_subscription"]?.boolValue
        let accountPlan = account["planType"]?.stringValue
        let billingPlan = hasActiveSubscription == true
            ? entitlement?["subscription_plan"]?.stringValue
            : nil
        let plan = displayPlanName(accountPlan: accountPlan, billingPlan: billingPlan)
        let willRenew = billingResult?["last_active_subscription"]?["will_renew"]?.boolValue
        let verifiedRenewalDate =
            hasActiveSubscription == false || willRenew == false
            ? nil
            : NormalizerHelpers.date(entitlement?["renews_at"])
        let fallbackBillingDate = NormalizerHelpers.nextBillingDate(in: [
            account["subscription"],
            accountResult["subscription"],
            .object(account),
            accountResult,
            rateLimitResult["subscription"],
            rateLimitResult,
        ])
        let nextBillingDate = willRenew == false ? nil : (verifiedRenewalDate ?? fallbackBillingDate)
        let identity = AccountIdentity(email: account["email"]?.stringValue)
        let method = account["type"]?.stringValue
        let root = rateLimitResult.objectValue ?? [:]
        var limits: [(String, [String: JSONValue])] = []
        if let map = root["rateLimitsByLimitId"]?.objectValue, !map.isEmpty {
            limits = map.compactMap { key, value in value.objectValue.map { (key, $0) } }
        } else if let value = root["rateLimits"]?.objectValue {
            limits = [(value["limitId"]?.stringValue ?? "codex", value)]
        }

        var meters: [QuotaMeter] = []
        for (fallbackID, limit) in limits {
            let limitID = limit["limitId"]?.stringValue ?? fallbackID
            let rawName = limit["limitName"]?.stringValue
            let baseName =
                (rawName?.isEmpty == false ? rawName : nil) ?? (limitID == "codex" ? "Codex" : NormalizerHelpers.humanize(limitID))
            for (index, windowName) in ["primary", "secondary"].enumerated() {
                guard let window = limit[windowName]?.objectValue else { continue }
                let percent = NormalizerHelpers.number(window["usedPercent"])
                let fraction = percent.map { $0 / 100 }
                let durationMinutes = NormalizerHelpers.integer(window["windowDurationMins"], range: 0...(10 * 365 * 24 * 60))
                let suffix = windowName == "primary" ? "" : " · secondary"
                meters.append(
                    QuotaMeter(
                        id: "\(limitID).\(windowName)",
                        displayName: baseName + suffix,
                        kind: .rollingWindow,
                        unit: .percent,
                        scope: MeterScope(kind: "model-family", id: limitID, displayName: baseName),
                        used: percent,
                        limit: 100,
                        remaining: percent.map { max(0, 100 - $0) },
                        usedFraction: fraction,
                        resetsAt: NormalizerHelpers.date(epoch: NormalizerHelpers.number(window["resetsAt"])),
                        windowSeconds: durationMinutes.map { $0 * 60 },
                        status: NormalizerHelpers.meterStatus(usedFraction: fraction),
                        priority: index * 10 + (limitID == "codex" ? 0 : 20),
                        source: "codex.account/rateLimits/read",
                        details: plan.map { ["plan": $0] }
                    ))
            }

            if let credits = limit["credits"]?.objectValue {
                let unlimited = credits["unlimited"]?.boolValue == true
                let balance = NormalizerHelpers.number(credits["balance"])
                if unlimited || balance != nil || credits["hasCredits"]?.boolValue == true {
                    meters.append(
                        QuotaMeter(
                            id: "\(limitID).credits",
                            displayName: "Usage credits",
                            kind: .balance,
                            unit: .credits,
                            scope: MeterScope(kind: "credits", id: limitID),
                            remaining: balance,
                            status: unlimited ? .unlimited : ((balance ?? 0) > 0 ? .available : .exhausted),
                            priority: 80,
                            source: "codex.account/rateLimits/read"
                        ))
                }
            }
        }

        if let resetCredits = root["rateLimitResetCredits"]?.objectValue,
            let count = NormalizerHelpers.number(resetCredits["availableCount"]), count > 0
        {
            meters.append(
                QuotaMeter(
                    id: "codex.reset-credits",
                    displayName: "Rate-limit resets",
                    kind: .count,
                    unit: .count,
                    scope: MeterScope(kind: "credits", id: "rate-limit-resets"),
                    remaining: count,
                    status: .available,
                    priority: 90,
                    source: "codex.account/rateLimits/read"
                ))
        }

        return AccountSnapshot(
            profileID: profile.id,
            provider: BuiltinProviders.codex,
            profileLabel: profile.label,
            authenticationState: .authenticated,
            authenticationMethod: method,
            identity: identity,
            subscription: Subscription(planName: plan, nextBillingDate: nextBillingDate),
            meters: meters,
            observedAt: observedAt,
            freshness: meters.isEmpty ? .pending : .fresh,
            message: meters.isEmpty ? "Codex did not return quota buckets." : nil
        )
    }

    private static func displayPlanName(accountPlan: String?, billingPlan: String?) -> String? {
        // Codex app-server versions that predate a plan decode it as "unknown".
        // The active ChatGPT entitlement retains the specific subscription code.
        proTierName(billingPlan) ?? proTierName(accountPlan) ?? accountPlan
    }

    /// Maps Pro plan codes to their tier names. Billing codes carry a
    /// "chatgpt" prefix ("chatgptpro"); Codex plan types do not ("pro").
    /// Older subscriptions keep their original codes: "pro" is the original
    /// Pro plan (now Pro 200) and "prolite" is Pro 100.
    private static func proTierName(_ code: String?) -> String? {
        guard var code = code?.lowercased() else { return nil }
        if code.hasPrefix("chatgpt") { code.removeFirst("chatgpt".count) }
        switch code {
        case "prolite": return "Pro 100"
        case "pro": return "Pro 200"
        case "promax": return "Pro 500"
        default: return nil
        }
    }
}
