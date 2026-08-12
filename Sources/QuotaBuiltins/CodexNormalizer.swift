import Foundation
import QuotaContracts

public enum CodexNormalizer {
    public static func snapshot(
        profile: Profile,
        accountResult: JSONValue,
        rateLimitResult: JSONValue,
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

        let plan = account["planType"]?.stringValue
        let nextBillingDate = NormalizerHelpers.nextBillingDate(in: [
            account["subscription"],
            accountResult["subscription"],
            .object(account),
            accountResult,
            rateLimitResult["subscription"],
            rateLimitResult,
        ])
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
}
