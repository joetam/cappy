import Foundation
import QuotaContracts

public struct WeeklyQuotaObservation: Codable, Equatable, Sendable {
    public var meterID: String
    public var observedAt: Date
    public var usedFraction: Double
    public var resetAt: Date?
    public var windowSeconds: Int

    public init(
        meterID: String,
        observedAt: Date,
        usedFraction: Double,
        resetAt: Date?,
        windowSeconds: Int
    ) {
        self.meterID = meterID
        self.observedAt = observedAt
        self.usedFraction = usedFraction
        self.resetAt = resetAt
        self.windowSeconds = windowSeconds
    }
}

/// Durable evidence for one logical Codex account. Provider timestamps remain
/// observations until a stable post-primer reset or nonzero usage verifies the
/// active cycle.
public struct QuotaPrimerRecord: Codable, Equatable, Sendable {
    public var observation: WeeklyQuotaObservation?
    public var verificationObservation: WeeklyQuotaObservation?
    public var lastAttemptAt: Date?
    public var retrySeriesStartedAt: Date?
    public var attemptCount: Int
    public var acceptedAt: Date?
    public var verifiedAt: Date?
    public var confirmedResetAt: Date?
    public var legacySuppressUntil: Date?

    public init(
        observation: WeeklyQuotaObservation? = nil,
        verificationObservation: WeeklyQuotaObservation? = nil,
        lastAttemptAt: Date? = nil,
        retrySeriesStartedAt: Date? = nil,
        attemptCount: Int = 0,
        acceptedAt: Date? = nil,
        verifiedAt: Date? = nil,
        confirmedResetAt: Date? = nil,
        legacySuppressUntil: Date? = nil
    ) {
        self.observation = observation
        self.verificationObservation = verificationObservation
        self.lastAttemptAt = lastAttemptAt
        self.retrySeriesStartedAt = retrySeriesStartedAt
        self.attemptCount = attemptCount
        self.acceptedAt = acceptedAt
        self.verifiedAt = verifiedAt
        self.confirmedResetAt = confirmedResetAt
        self.legacySuppressUntil = legacySuppressUntil
    }
}

public enum QuotaResetClockEvidence: Equatable, Sendable {
    case activeUsage
    case anchored(resetAt: Date)
    case sliding
    case inconclusive
}

public enum QuotaPrimerAction: Equatable, Sendable {
    case none
    case prime
}

public struct QuotaPrimerEvaluation: Equatable, Sendable {
    public var record: QuotaPrimerRecord?
    public var action: QuotaPrimerAction
    public var didVerify: Bool

    public init(record: QuotaPrimerRecord?, action: QuotaPrimerAction, didVerify: Bool = false) {
        self.record = record
        self.action = action
        self.didVerify = didVerify
    }
}

public enum QuotaPrimerPolicy {
    public static let enabledDefaultsKey = "quotaPrimer.enabled.v1"
    public static let attemptedResetsDefaultsKey = "quotaPrimer.attemptedResets.v1"
    public static let recordsDefaultsKey = "quotaPrimer.records.v3"
    public static let supportedProviderID = "openai-codex"
    public static let defaultWeeklyWindowSeconds = 7 * 24 * 60 * 60
    public static let automaticRetryDelay: TimeInterval = 30 * 60
    public static let maximumAutomaticAttempts = 3

    private static let zeroUsageTolerance = 0.000_001
    private static let timestampTolerance: TimeInterval = 2
    private static let expectedResetTolerance: TimeInterval = 5 * 60

    public static func recordKey(for snapshot: AccountSnapshot) -> String? {
        guard snapshot.provider.id == supportedProviderID else { return nil }
        return accountIdentity(for: snapshot)?.persistedValue
            ?? [snapshot.provider.id, "profile", snapshot.profileID].joined(separator: "|")
    }

    /// Returns the reset boundary that became eligible between two successful
    /// readings. Retained for compatibility with the original reset detector;
    /// new priming decisions are made by `evaluate(snapshot:record:)`.
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

    /// Selects the account's primary weekly reset while preserving the strongest
    /// usage evidence across every weekly bucket. Nonzero supplemental usage is
    /// enough to prove that the shared weekly clock is active.
    public static func primaryWeeklyObservation(_ snapshot: AccountSnapshot) -> WeeklyQuotaObservation? {
        guard snapshot.provider.id == supportedProviderID,
            snapshot.authenticationState == .authenticated,
            snapshot.freshness == .fresh
        else { return nil }
        let weeklyMeters = snapshot.meters.filter { isWeeklyWindow($0) && $0.usedFraction != nil }
        guard
            let meter = weeklyMeters.sorted(by: {
                $0.priority == $1.priority ? $0.id < $1.id : $0.priority < $1.priority
            }).first,
            let usedFraction = weeklyMeters.compactMap(\.usedFraction).max()
        else { return nil }
        return WeeklyQuotaObservation(
            meterID: meter.id,
            observedAt: snapshot.observedAt,
            usedFraction: usedFraction,
            resetAt: meter.resetsAt,
            windowSeconds: meter.windowSeconds ?? defaultWeeklyWindowSeconds
        )
    }

    /// Reduces one fresh snapshot and the account's durable evidence into the
    /// next record plus an optional primer action. A lone future deadline is
    /// deliberately inconclusive; a second comparable reading must show that
    /// the deadline slides with observation time.
    public static func evaluate(
        snapshot: AccountSnapshot,
        record: QuotaPrimerRecord?
    ) -> QuotaPrimerEvaluation {
        guard let current = primaryWeeklyObservation(snapshot) else {
            return QuotaPrimerEvaluation(record: record, action: .none)
        }

        var next = record ?? QuotaPrimerRecord()
        var previous = next.observation
        let now = current.observedAt

        if let confirmedResetAt = next.confirmedResetAt,
            now >= confirmedResetAt.addingTimeInterval(-timestampTolerance)
        {
            next = QuotaPrimerRecord()
            previous = nil
        }

        var didVerify = false
        if let acceptedAt = next.acceptedAt,
            next.verifiedAt == nil,
            current.observedAt >= acceptedAt
        {
            if current.usedFraction > zeroUsageTolerance {
                next.verifiedAt = current.observedAt
                next.confirmedResetAt = current.resetAt
                didVerify = true
            } else if let verificationPrevious = next.verificationObservation,
                case .anchored(let resetAt) = resetClockEvidence(
                    previous: verificationPrevious,
                    current: current
                )
            {
                next.verifiedAt = current.observedAt
                next.confirmedResetAt = resetAt
                didVerify = true
            }
            next.verificationObservation = current
        }

        if current.usedFraction > zeroUsageTolerance {
            next.observation = current
            if let resetAt = current.resetAt { next.confirmedResetAt = resetAt }
            return QuotaPrimerEvaluation(record: next, action: .none, didVerify: didVerify)
        }

        if didVerify {
            next.observation = current
            return QuotaPrimerEvaluation(record: next, action: .none, didVerify: true)
        }

        if let confirmedResetAt = next.confirmedResetAt,
            now < confirmedResetAt.addingTimeInterval(-timestampTolerance)
        {
            next.observation = current
            return QuotaPrimerEvaluation(record: next, action: .none)
        }

        if let suppressUntil = next.legacySuppressUntil {
            if now < suppressUntil {
                next.observation = current
                return QuotaPrimerEvaluation(record: next, action: .none)
            }
            next.legacySuppressUntil = nil
            next.lastAttemptAt = nil
            next.retrySeriesStartedAt = nil
            next.attemptCount = 0
            next.acceptedAt = nil
            next.verificationObservation = nil
        }

        if next.attemptCount >= maximumAutomaticAttempts,
            let seriesStartedAt = next.retrySeriesStartedAt
        {
            let retrySeriesEnds = seriesStartedAt.addingTimeInterval(TimeInterval(defaultWeeklyWindowSeconds))
            if now < retrySeriesEnds {
                next.observation = current
                return QuotaPrimerEvaluation(record: next, action: .none)
            }
            next.lastAttemptAt = nil
            next.retrySeriesStartedAt = nil
            next.attemptCount = 0
            next.acceptedAt = nil
            next.verificationObservation = nil
        }

        let evidence = previous.map { resetClockEvidence(previous: $0, current: current) } ?? .inconclusive
        let resetExpired =
            current.resetAt.map {
                $0 <= now.addingTimeInterval(timestampTolerance)
            } ?? true
        let inactive = resetExpired || evidence == .sliding

        // An accepted RPC is not a verified cycle. While it is pending, only
        // post-attempt evidence can confirm success; preflight observations may
        // still be used to decide a bounded retry.
        if next.acceptedAt != nil {
            guard inactive else {
                next.observation = current
                return QuotaPrimerEvaluation(record: next, action: .none)
            }
            if let attemptedAt = next.lastAttemptAt,
                now < attemptedAt.addingTimeInterval(automaticRetryDelay)
            {
                next.observation = current
                return QuotaPrimerEvaluation(record: next, action: .none)
            }
            next.observation = current
            return QuotaPrimerEvaluation(record: next, action: .prime)
        }

        if case .anchored(let resetAt) = evidence, !resetExpired {
            next.confirmedResetAt = resetAt
            next.observation = current
            return QuotaPrimerEvaluation(record: next, action: .none)
        }

        guard inactive else {
            next.observation = current
            return QuotaPrimerEvaluation(record: next, action: .none)
        }

        if let attemptedAt = next.lastAttemptAt,
            now < attemptedAt.addingTimeInterval(automaticRetryDelay)
        {
            next.observation = current
            return QuotaPrimerEvaluation(record: next, action: .none)
        }

        next.observation = current
        return QuotaPrimerEvaluation(record: next, action: .prime)
    }

    /// Compares exact provider timestamps. A fixed deadline is active; a
    /// deadline that advances with observation time is an inactive projection.
    public static func resetClockEvidence(
        previous: WeeklyQuotaObservation,
        current: WeeklyQuotaObservation
    ) -> QuotaResetClockEvidence {
        if current.usedFraction > zeroUsageTolerance { return .activeUsage }
        guard current.observedAt > previous.observedAt,
            current.meterID == previous.meterID,
            current.windowSeconds == previous.windowSeconds,
            let previousReset = previous.resetAt,
            let currentReset = current.resetAt
        else { return .inconclusive }

        let observedShift = current.observedAt.timeIntervalSince(previous.observedAt)
        let resetShift = currentReset.timeIntervalSince(previousReset)
        guard observedShift > timestampTolerance else { return .inconclusive }

        let previousRemaining = previousReset.timeIntervalSince(previous.observedAt)
        let currentRemaining = currentReset.timeIntervalSince(current.observedAt)
        let expectedWindow = TimeInterval(current.windowSeconds)
        if abs(resetShift - observedShift) <= timestampTolerance,
            abs(previousRemaining - expectedWindow) <= expectedResetTolerance,
            abs(currentRemaining - expectedWindow) <= expectedResetTolerance
        {
            return .sliding
        }
        if abs(resetShift) <= timestampTolerance {
            return .anchored(resetAt: currentReset)
        }
        return .inconclusive
    }

    public static func recordingAttempt(
        record: QuotaPrimerRecord,
        at attemptedAt: Date
    ) -> QuotaPrimerRecord {
        var next = record
        if next.retrySeriesStartedAt == nil {
            next.retrySeriesStartedAt = attemptedAt
            next.attemptCount = 1
        } else {
            next.attemptCount += 1
        }
        next.lastAttemptAt = attemptedAt
        next.acceptedAt = nil
        next.verifiedAt = nil
        next.confirmedResetAt = nil
        next.verificationObservation = nil
        next.legacySuppressUntil = nil
        return next
    }

    public static func recordingAcceptance(
        record: QuotaPrimerRecord,
        attemptedAt: Date,
        acceptedAt: Date
    ) -> QuotaPrimerRecord? {
        guard record.lastAttemptAt == attemptedAt else { return nil }
        var next = record
        next.acceptedAt = acceptedAt
        return next
    }

    /// V1 could not distinguish an attempt from a verified active clock. Keep
    /// its duplicate-send guard for the remainder of that historical cycle,
    /// then let current evidence decide what to do next.
    public static func migrateAttemptedReset(_ attemptedAt: Date) -> QuotaPrimerRecord {
        QuotaPrimerRecord(
            lastAttemptAt: attemptedAt,
            retrySeriesStartedAt: attemptedAt,
            attemptCount: 1,
            legacySuppressUntil: attemptedAt.addingTimeInterval(TimeInterval(defaultWeeklyWindowSeconds))
        )
    }
}
