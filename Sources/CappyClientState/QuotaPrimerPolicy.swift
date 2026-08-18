import Foundation
import QuotaContracts

public enum QuotaPrimerPolicy {
    public static let enabledDefaultsKey = "quotaPrimer.enabled.v1"
    public static let attemptedResetsDefaultsKey = "quotaPrimer.attemptedResets.v1"
    public static let supportedProviderID = "openai-codex"

    /// Returns the reset boundary that became eligible between two successful
    /// readings. A single marker per profile lets the caller collapse several
    /// weekly meters that reset together into one primer message.
    public static func dueResetMarker(
        previous: AccountSnapshot,
        refreshed: AccountSnapshot
    ) -> Date? {
        guard previous.provider.id == supportedProviderID,
            refreshed.provider.id == supportedProviderID,
            previous.profileID == refreshed.profileID,
            previous.authenticationState == .authenticated,
            refreshed.authenticationState == .authenticated,
            refreshed.freshness == .fresh,
            refreshed.observedAt > previous.observedAt
        else { return nil }

        let refreshedByID = Dictionary(uniqueKeysWithValues: refreshed.meters.map { ($0.id, $0) })
        return previous.meters.compactMap { meter -> Date? in
            guard isWeeklyWindow(meter), let reset = meter.resetsAt,
                reset <= refreshed.observedAt
            else { return nil }

            let crossedBoundary = previous.observedAt < reset
            let current = refreshedByID[meter.id]
            let providerAdvancedWindow = current?.resetsAt.map { $0 > reset.addingTimeInterval(60) } == true
            let utilizationDropped =
                meter.usedFraction.flatMap { oldValue in
                    current?.usedFraction.map { $0 + 0.001 < oldValue }
                } == true
            return crossedBoundary || providerAdvancedWindow || utilizationDropped ? reset : nil
        }.max()
    }

    public static func isWeeklyWindow(_ meter: QuotaMeter) -> Bool {
        guard meter.kind == .rollingWindow else { return false }
        if let seconds = meter.windowSeconds, seconds >= 6 * 24 * 60 * 60 { return true }
        let fingerprint = [meter.id, meter.displayName, meter.scope.id, meter.scope.displayName ?? ""]
            .joined(separator: " ")
            .lowercased()
        return ["seven_day", "seven-day", "7-day", "weekly", "week"].contains { fingerprint.contains($0) }
    }

    public static func hasInactiveWeeklyWindow(_ snapshot: AccountSnapshot) -> Bool {
        guard snapshot.provider.id == supportedProviderID,
            snapshot.authenticationState == .authenticated,
            snapshot.freshness == .fresh
        else { return false }
        return snapshot.meters.contains { meter in
            guard isWeeklyWindow(meter), (meter.usedFraction ?? 1) <= 0.001 else { return false }
            return meter.resetsAt.map { $0 <= snapshot.observedAt } ?? true
        }
    }
}
