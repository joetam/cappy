import CappyClientState
import Foundation
import QuotaContracts

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("cappy-client-state-selftest: \(message)\n".utf8))
        exit(1)
    }
}

let idleRefresh = AccountRefreshState.idle
expect(!idleRefresh.isRefreshing, "idle refresh state must not be marked active")
expect(!idleRefresh.isUpdating(profileID: "account-a"), "idle refresh state must not mark an account as updating")

let activeRefresh = AccountRefreshState.refreshing(profileIDs: Set(["account-a", "account-b"]))
expect(activeRefresh.isRefreshing, "active refresh state must not be marked idle")
expect(activeRefresh.isUpdating(profileID: "account-a"), "an account included in the refresh must be marked updating")
expect(!activeRefresh.isUpdating(profileID: "account-c"), "an account outside the refresh must remain unchanged")

expect(
    AccountReadingPhase(freshness: .fresh, isUpdating: true) == .updating,
    "an active client refresh must take precedence over persisted freshness"
)
expect(
    AccountReadingPhase(freshness: .pending, isUpdating: false) == .waitingForQuota,
    "a provider response without quota must remain visibly provisional"
)
expect(
    AccountReadingPhase(freshness: .stale, isUpdating: false) == .cached,
    "a failed refresh must identify the retained reading as cached"
)
expect(AccountReadingPhase.cached.deemphasizesReading, "cached readings must be visually deemphasized")
expect(!AccountReadingPhase.current.deemphasizesReading, "current readings must retain normal emphasis")

let first = recognizeCLIAccount(currentIdentityKey: "openai-codex|new@example.com|", remembered: nil)
expect(first == .firstDiscovery, "a provider without remembered identity must enter first discovery")

let unchangedAccount = RememberedCLIAccount(
    identityKey: "openai-codex|same@example.com|",
    displayIdentity: "same@example.com",
    wasKept: false
)
let unchanged = recognizeCLIAccount(currentIdentityKey: unchangedAccount.identityKey, remembered: unchangedAccount)
expect(unchanged == .unchanged, "an acknowledged identity must not repeatedly enter onboarding")

let previousAccount = RememberedCLIAccount(
    identityKey: "anthropic-claude|old@example.com|",
    displayIdentity: "old@example.com",
    wasKept: true
)
let changed = recognizeCLIAccount(
    currentIdentityKey: "anthropic-claude|new@example.com|",
    remembered: previousAccount
)
expect(
    changed == .changed(from: previousAccount),
    "an identity switch must retain the previous display identity and preservation status"
)

func connectionProfile(
    id: String,
    label: String,
    managed: Bool,
    isDefault: Bool = false
) -> ProfileSummary {
    ProfileSummary(
        Profile(
            id: id,
            providerID: "anthropic-claude",
            label: label,
            configPath: "/tmp/\(id)",
            isManaged: managed,
            isDefault: isDefault
        )
    )
}

func connectionSnapshot(
    profileID: String,
    label: String,
    email: String? = "same@example.com",
    organization: String? = "Shared Workspace",
    stableID: String? = "workspace-1"
) -> AccountSnapshot {
    AccountSnapshot(
        profileID: profileID,
        provider: ProviderDescriptor(id: "anthropic-claude", displayName: "Claude"),
        profileLabel: label,
        authenticationState: .authenticated,
        identity: AccountIdentity(email: email, organization: organization, stableID: stableID),
        freshness: .fresh
    )
}

let cliProfile = connectionProfile(id: "claude-default", label: "Claude", managed: false, isDefault: true)
let managedProfile = connectionProfile(id: "claude-managed", label: "Claude", managed: true)
var publicCLISnapshot = connectionSnapshot(profileID: cliProfile.id, label: cliProfile.label)
publicCLISnapshot.accountReconciliationID = "opaque-shared-workspace"
publicCLISnapshot.identity?.stableID = nil
var publicManagedSnapshot = connectionSnapshot(
    profileID: managedProfile.id,
    label: managedProfile.label,
    organization: "Renamed Shared Workspace"
)
publicManagedSnapshot.accountReconciliationID = "opaque-shared-workspace"
publicManagedSnapshot.identity?.stableID = nil
let sameAccountConnections = [
    AccountConnectionReading(
        profile: cliProfile,
        snapshot: publicCLISnapshot
    ),
    AccountConnectionReading(
        profile: managedProfile,
        snapshot: publicManagedSnapshot
    ),
]
let sameAccountPresentation = reconcileAccounts(sameAccountConnections)
expect(sameAccountPresentation.count == 1, "two connections to one account/workspace must produce one account row")
expect(
    sameAccountPresentation.first?.primaryConnection.profile.id == managedProfile.id,
    "a managed connection must own presentation when it also reaches the provider-CLI account"
)
expect(
    sameAccountPresentation.first?.connections.map(\.profile.id) == [cliProfile.id, managedProfile.id],
    "account reconciliation must retain both independently manageable connections"
)

let cliOnlyPresentation = reconcileAccounts([sameAccountConnections[0]])
expect(
    cliOnlyPresentation.first?.snapshot.profileLabel == "same@example.com",
    "a provider-CLI connection's internal label must not become the logical account display name"
)

let otherWorkspaceProfile = connectionProfile(id: "claude-other-workspace", label: "Other", managed: true)
let separateWorkspaces = reconcileAccounts([
    sameAccountConnections[0],
    AccountConnectionReading(
        profile: otherWorkspaceProfile,
        snapshot: connectionSnapshot(
            profileID: otherWorkspaceProfile.id,
            label: otherWorkspaceProfile.label,
            organization: "Other Workspace",
            stableID: "workspace-2"
        )
    ),
])
expect(separateWorkspaces.count == 2, "the same email in different workspaces must remain separate accounts")

let collidingManagedProfile = connectionProfile(id: "claude-named-email", label: "same@example.com", managed: true)
let disambiguatedNames = reconcileAccounts([
    AccountConnectionReading(
        profile: collidingManagedProfile,
        snapshot: connectionSnapshot(
            profileID: collidingManagedProfile.id,
            label: collidingManagedProfile.label,
            organization: "Other Workspace",
            stableID: "workspace-2"
        )
    ),
    sameAccountConnections[0],
])
expect(
    disambiguatedNames.map(\.snapshot.profileLabel) == ["same@example.com", "same@example.com · Shared Workspace"],
    "derived provider-CLI names must be disambiguated at presentation time without renaming managed connections"
)

func snapshot(observedAt: Date, reset: Date, usedFraction: Double, freshness: SnapshotFreshness = .fresh) -> AccountSnapshot {
    AccountSnapshot(
        profileID: "codex-default",
        provider: ProviderDescriptor(id: "openai-codex", displayName: "Codex"),
        profileLabel: "Codex",
        authenticationState: .authenticated,
        meters: [
            QuotaMeter(
                id: "codex.secondary",
                displayName: "Codex · secondary",
                kind: .rollingWindow,
                unit: .percent,
                scope: MeterScope(kind: "model-family", id: "codex"),
                usedFraction: usedFraction,
                resetsAt: reset,
                windowSeconds: 7 * 24 * 60 * 60,
                source: "selftest"
            )
        ],
        observedAt: observedAt,
        freshness: freshness
    )
}

func claudeSnapshot(from snapshot: AccountSnapshot) -> AccountSnapshot {
    var snapshot = snapshot
    snapshot.provider = ProviderDescriptor(id: "anthropic-claude", displayName: "Claude")
    return snapshot
}

let reset = Date(timeIntervalSince1970: 1_800_000_000)
let beforeReset = snapshot(observedAt: reset.addingTimeInterval(-60), reset: reset, usedFraction: 0.8)
let afterReset = snapshot(observedAt: reset.addingTimeInterval(60), reset: reset.addingTimeInterval(7 * 86_400), usedFraction: 0)
expect(
    QuotaPrimerPolicy.dueResetMarker(previous: beforeReset, refreshed: afterReset) == reset,
    "a successfully observed weekly reset must schedule one quota primer"
)
expect(
    QuotaPrimerPolicy.dueResetMarker(
        previous: claudeSnapshot(from: beforeReset),
        refreshed: claudeSnapshot(from: afterReset)
    ) == nil,
    "Claude's account-assigned weekly reset must not schedule a quota primer"
)

let staleAfterReset = snapshot(
    observedAt: reset.addingTimeInterval(60),
    reset: reset.addingTimeInterval(7 * 86_400),
    usedFraction: 0,
    freshness: .stale
)
expect(
    QuotaPrimerPolicy.dueResetMarker(previous: beforeReset, refreshed: staleAfterReset) == nil,
    "a stale reading must not trigger a quota primer"
)

var shortWindow = beforeReset
shortWindow.meters[0].windowSeconds = 5 * 60 * 60
expect(
    QuotaPrimerPolicy.dueResetMarker(previous: shortWindow, refreshed: afterReset) == nil,
    "a short quota window must not trigger the weekly primer"
)

var namedWeeklyMeter = shortWindow.meters[0]
namedWeeklyMeter.id = "claude.seven_day"
namedWeeklyMeter.windowSeconds = nil
expect(QuotaPrimerPolicy.isWeeklyWindow(namedWeeklyMeter), "provider-named seven-day windows must be recognized")

var inactiveWeeklyQuota = afterReset
inactiveWeeklyQuota.meters[0].resetsAt = nil
expect(
    QuotaPrimerPolicy.evaluate(snapshot: inactiveWeeklyQuota, record: nil).action == .prime,
    "a fresh weekly quota with no reset clock must be eligible immediately"
)
let expiredWeeklyQuota = snapshot(
    observedAt: reset.addingTimeInterval(60),
    reset: reset,
    usedFraction: 0
)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: expiredWeeklyQuota, record: nil).action == .prime,
    "a fresh zero-use weekly quota with an expired reset must be eligible immediately"
)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: claudeSnapshot(from: inactiveWeeklyQuota), record: nil).record == nil,
    "the Codex primer policy must ignore Claude weekly quota"
)

let observationStart = Date(timeIntervalSince1970: 1_900_000_000)
let weeklySeconds = QuotaPrimerPolicy.defaultWeeklyWindowSeconds
let projectedReset = observationStart.addingTimeInterval(TimeInterval(weeklySeconds))
let slidingFirstSnapshot = snapshot(observedAt: observationStart, reset: projectedReset, usedFraction: 0)
let firstEvaluation = QuotaPrimerPolicy.evaluate(snapshot: slidingFirstSnapshot, record: nil)
expect(
    firstEvaluation.action == .none && firstEvaluation.record?.observation?.resetAt == projectedReset,
    "one future reset timestamp must be stored as evidence instead of treated as activity or inactivity"
)

let slidingSecondSnapshot = snapshot(
    observedAt: observationStart.addingTimeInterval(6),
    reset: projectedReset.addingTimeInterval(6),
    usedFraction: 0
)
let slidingEvaluation = QuotaPrimerPolicy.evaluate(
    snapshot: slidingSecondSnapshot,
    record: firstEvaluation.record
)
expect(
    slidingEvaluation.action == .prime,
    "a reset deadline that advances with observation time must trigger one primer"
)
expect(slidingEvaluation.record != nil, "a primer decision must retain its supporting observations")

let anchoredSecondSnapshot = snapshot(
    observedAt: observationStart.addingTimeInterval(6),
    reset: projectedReset,
    usedFraction: 0
)
let anchoredEvaluation = QuotaPrimerPolicy.evaluate(
    snapshot: anchoredSecondSnapshot,
    record: firstEvaluation.record
)
expect(
    anchoredEvaluation.action == .none && anchoredEvaluation.record?.confirmedResetAt == nil,
    "fixed zero-use reset deadlines must remain provisional without sending another request"
)

var changedPrimaryMeter = anchoredSecondSnapshot
changedPrimaryMeter.meters[0].id = "codex.other-weekly"
expect(
    QuotaPrimerPolicy.evaluate(snapshot: changedPrimaryMeter, record: firstEvaluation.record).action == .none,
    "observations from different primary meters must not be compared as one sliding clock"
)

let nonzeroSnapshot = snapshot(
    observedAt: observationStart.addingTimeInterval(6),
    reset: projectedReset,
    usedFraction: 0.001
)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: nonzeroSnapshot, record: firstEvaluation.record).action == .none,
    "nonzero raw usage must prove that the weekly clock is active"
)

let attemptedAt = slidingSecondSnapshot.observedAt.addingTimeInterval(1)
let attemptedRecord = QuotaPrimerPolicy.recordingAttempt(
    record: slidingEvaluation.record ?? QuotaPrimerRecord(),
    at: attemptedAt
)
expect(
    attemptedRecord.attemptCount == 1 && attemptedRecord.lastAttemptAt == attemptedAt,
    "starting a primer must persist its retry-series guard before sending"
)
let acceptedAt = attemptedAt.addingTimeInterval(1)
let acceptedRecord = QuotaPrimerPolicy.recordingAcceptance(
    record: attemptedRecord,
    attemptedAt: attemptedAt,
    acceptedAt: acceptedAt
)
expect(
    acceptedRecord?.acceptedAt == acceptedAt && acceptedRecord?.confirmedResetAt == nil,
    "an accepted primer must remain unverified and must not invent a cycle end"
)

let anchoredAfterPrimer = acceptedAt.addingTimeInterval(TimeInterval(weeklySeconds))
let firstVerificationSnapshot = snapshot(
    observedAt: acceptedAt.addingTimeInterval(4),
    reset: anchoredAfterPrimer,
    usedFraction: 0
)
let firstVerification = QuotaPrimerPolicy.evaluate(
    snapshot: firstVerificationSnapshot,
    record: acceptedRecord
)
expect(
    !firstVerification.didVerify && firstVerification.record?.verificationObservation != nil
        && firstVerification.record?.confirmedResetAt == nil,
    "one zero-use post-primer reading must remain pending"
)
let secondVerificationSnapshot = snapshot(
    observedAt: acceptedAt.addingTimeInterval(8),
    reset: anchoredAfterPrimer,
    usedFraction: 0
)
let zeroUsePlateau = QuotaPrimerPolicy.evaluate(
    snapshot: secondVerificationSnapshot,
    record: firstVerification.record
)
expect(
    !zeroUsePlateau.didVerify && zeroUsePlateau.record?.confirmedResetAt == nil,
    "two fixed zero-use post-primer deadlines must not verify the active clock"
)
let cachedPlateauSnapshot = snapshot(
    observedAt: acceptedAt.addingTimeInterval(10 * 60),
    reset: anchoredAfterPrimer,
    usedFraction: 0
)
let cachedPlateau = QuotaPrimerPolicy.evaluate(snapshot: cachedPlateauSnapshot, record: zeroUsePlateau.record)
expect(
    !cachedPlateau.didVerify && cachedPlateau.record?.confirmedResetAt == nil,
    "a zero-use deadline stable for ten minutes can still be a cached projection"
)
let resumedProjectionAt = acceptedAt.addingTimeInterval(2 * 60 * 60)
let resumedProjection = snapshot(
    observedAt: resumedProjectionAt,
    reset: resumedProjectionAt.addingTimeInterval(TimeInterval(weeklySeconds)),
    usedFraction: 0
)
let resumedProjectionEvaluation = QuotaPrimerPolicy.evaluate(
    snapshot: resumedProjection, record: cachedPlateau.record
)
let nextProjectionAt = resumedProjectionAt.addingTimeInterval(300)
let nextProjection = snapshot(
    observedAt: nextProjectionAt,
    reset: nextProjectionAt.addingTimeInterval(TimeInterval(weeklySeconds)),
    usedFraction: 0
)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: nextProjection, record: resumedProjectionEvaluation.record).action == .prime,
    "a cached plateau must not suppress a bounded retry when the zero-use clock resumes sliding"
)
let reportedQuotaUse = snapshot(
    observedAt: acceptedAt.addingTimeInterval(9),
    reset: anchoredAfterPrimer,
    usedFraction: 0.01
)
let verified = QuotaPrimerPolicy.evaluate(snapshot: reportedQuotaUse, record: zeroUsePlateau.record)
expect(
    verified.didVerify && verified.record?.confirmedResetAt == anchoredAfterPrimer,
    "provider-reported weekly quota use must verify an accepted primer's active clock"
)

let historicalConfirmation = QuotaPrimerRecord(
    observation: QuotaPrimerPolicy.primaryWeeklyObservation(slidingFirstSnapshot),
    verifiedAt: slidingFirstSnapshot.observedAt,
    confirmedResetAt: projectedReset
)
let reconsideredConfirmation = QuotaPrimerPolicy.evaluate(
    snapshot: slidingSecondSnapshot, record: historicalConfirmation
)
expect(
    reconsideredConfirmation.action == .prime && reconsideredConfirmation.record?.verifiedAt == nil,
    "historical zero-use confirmations must be discarded when fresh reset observations slide"
)

let slidingAfterPrimerOne = snapshot(
    observedAt: acceptedAt.addingTimeInterval(60),
    reset: acceptedAt.addingTimeInterval(TimeInterval(weeklySeconds + 60)),
    usedFraction: 0
)
let pendingAfterPrimer = QuotaPrimerPolicy.evaluate(
    snapshot: slidingAfterPrimerOne,
    record: acceptedRecord
)
expect(
    pendingAfterPrimer.action == .none && pendingAfterPrimer.record?.confirmedResetAt == nil,
    "a still-sliding clock must not be mistaken for successful verification"
)
let retryObservedAt = attemptedAt.addingTimeInterval(QuotaPrimerPolicy.automaticRetryDelay + 1)
let slidingAfterPrimerTwo = snapshot(
    observedAt: retryObservedAt,
    reset: retryObservedAt.addingTimeInterval(TimeInterval(weeklySeconds)),
    usedFraction: 0
)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: slidingAfterPrimerTwo, record: pendingAfterPrimer.record).action == .prime,
    "an accepted but unverified primer may retry after the bounded delay"
)

let firstUnexpectedReset = QuotaPrimerPolicy.evaluate(snapshot: slidingAfterPrimerOne, record: verified.record)
expect(
    firstUnexpectedReset.action == .none && firstUnexpectedReset.record?.verifiedAt == nil,
    "a fresh full-window projection after quota drops to zero must invalidate the old confirmation while honoring cooldown"
)
let unexpectedReset = QuotaPrimerPolicy.evaluate(snapshot: slidingAfterPrimerTwo, record: firstUnexpectedReset.record)
expect(
    unexpectedReset.action == .prime && unexpectedReset.record?.confirmedResetAt == nil
        && unexpectedReset.record?.attemptCount == verified.record?.attemptCount,
    "a provider reset must allow a paced retry without discarding recent request history"
)
var cappedVerifiedRecord = firstUnexpectedReset.record ?? QuotaPrimerRecord()
cappedVerifiedRecord.attemptCount = QuotaPrimerPolicy.maximumAutomaticAttempts
expect(
    QuotaPrimerPolicy.evaluate(snapshot: slidingAfterPrimerTwo, record: cappedVerifiedRecord).action == .none,
    "invalidating a clock confirmation must not bypass the current request budget"
)
let replacementAttemptedAt = retryObservedAt.addingTimeInterval(1)
let replacementAttempt = QuotaPrimerPolicy.recordingAttempt(
    record: unexpectedReset.record ?? QuotaPrimerRecord(), at: replacementAttemptedAt
)
let replacementAccepted = QuotaPrimerPolicy.recordingAcceptance(
    record: replacementAttempt, attemptedAt: replacementAttemptedAt, acceptedAt: replacementAttemptedAt.addingTimeInterval(1)
)
let replacementReset = replacementAttemptedAt.addingTimeInterval(TimeInterval(weeklySeconds))
let replacementFirst = QuotaPrimerPolicy.evaluate(
    snapshot: snapshot(observedAt: replacementAttemptedAt.addingTimeInterval(5), reset: replacementReset, usedFraction: 0),
    record: replacementAccepted
)
let replacementVerified = QuotaPrimerPolicy.evaluate(
    snapshot: snapshot(observedAt: replacementAttemptedAt.addingTimeInterval(10), reset: replacementReset, usedFraction: 0.01),
    record: replacementFirst.record
)
expect(
    !replacementFirst.didVerify && replacementVerified.didVerify,
    "a replacement request must verify against new provider quota usage"
)

let cappedRecord = QuotaPrimerRecord(
    observation: QuotaPrimerPolicy.primaryWeeklyObservation(slidingAfterPrimerOne),
    lastAttemptAt: attemptedAt,
    retrySeriesStartedAt: attemptedAt,
    attemptCount: QuotaPrimerPolicy.maximumAutomaticAttempts,
    acceptedAt: acceptedAt
)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: slidingAfterPrimerTwo, record: cappedRecord).action == .none,
    "automatic retries must stop after the attempt cap"
)

var oldCappedRecord = cappedRecord
oldCappedRecord.observation = QuotaPrimerPolicy.primaryWeeklyObservation(slidingFirstSnapshot)
oldCappedRecord.retrySeriesStartedAt = observationStart.addingTimeInterval(-6 * 86_400)
oldCappedRecord.lastAttemptAt = observationStart.addingTimeInterval(-3 * 86_400)
oldCappedRecord.acceptedAt = oldCappedRecord.lastAttemptAt?.addingTimeInterval(4)
let recoveredBudget = QuotaPrimerPolicy.evaluate(snapshot: slidingSecondSnapshot, record: oldCappedRecord)
expect(
    recoveredBudget.action == .prime && recoveredBudget.record?.attemptCount == 0,
    "days-old attempts must not block a fresh inactive clock for the remainder of a week"
)
var lateCappedRecord = oldCappedRecord
lateCappedRecord.lastAttemptAt = slidingSecondSnapshot.observedAt.addingTimeInterval(-60)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: slidingSecondSnapshot, record: lateCappedRecord).action == .none,
    "renewing the daily budget must still respect the last request's cooldown"
)
let expiredClockAt = attemptedAt.addingTimeInterval(120)
let expiredClock = snapshot(observedAt: expiredClockAt, reset: expiredClockAt.addingTimeInterval(-1), usedFraction: 0)
var cappedExpiredClock = cappedRecord
cappedExpiredClock.confirmedResetAt = expiredClockAt.addingTimeInterval(-1)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: expiredClock, record: cappedExpiredClock).action == .none,
    "a provider window expiring must not discard the independent request budget"
)
var recentExpiredClock = cappedExpiredClock
recentExpiredClock.attemptCount = 1
expect(
    QuotaPrimerPolicy.evaluate(snapshot: expiredClock, record: recentExpiredClock).action == .none,
    "a provider window expiring must not discard the request cooldown"
)
let renewedClockAt = attemptedAt.addingTimeInterval(QuotaPrimerPolicy.automaticRetryWindow + 1)
let renewedClock = snapshot(observedAt: renewedClockAt, reset: renewedClockAt.addingTimeInterval(-1), usedFraction: 0)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: renewedClock, record: cappedExpiredClock).action == .prime,
    "an expired provider clock may be primed once the request budget independently renews"
)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: slidingFirstSnapshot, record: firstEvaluation.record).action == .none,
    "replaying the same provider observation must not send another primer"
)
var jitteredProjection = slidingSecondSnapshot
jitteredProjection.meters[0].resetsAt = jitteredProjection.meters[0].resetsAt?.addingTimeInterval(-3)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: jitteredProjection, record: firstEvaluation.record).action == .prime,
    "provider latency must not hide an advancing full-window projection"
)
let earlyReset = snapshot(
    observedAt: beforeReset.observedAt.addingTimeInterval(10),
    reset: beforeReset.observedAt.addingTimeInterval(10 + TimeInterval(weeklySeconds)),
    usedFraction: 0
)
let earlyResetRecord = QuotaPrimerRecord(
    observation: QuotaPrimerPolicy.primaryWeeklyObservation(beforeReset),
    confirmedResetAt: beforeReset.meters[0].resetsAt
)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: earlyReset, record: earlyResetRecord).action == .prime,
    "an early provider reset must supersede a previously confirmed active deadline"
)

let failedRecord = QuotaPrimerPolicy.recordingFailure(
    record: attemptedRecord,
    attemptedAt: attemptedAt,
    failedAt: acceptedAt,
    message: "Codex quota primer reported a failed model turn."
)
var tinyPositiveUsage = slidingSecondSnapshot
tinyPositiveUsage.meters[0].usedFraction = 0.000_000_01
expect(
    QuotaPrimerPolicy.evaluate(snapshot: tinyPositiveUsage, record: firstEvaluation.record).action == .none,
    "any positive provider-reported quota usage must prevent automatic priming"
)
var monthlyQuota = slidingSecondSnapshot
monthlyQuota.meters[0].windowSeconds = 30 * 86_400
expect(
    QuotaPrimerPolicy.evaluate(snapshot: monthlyQuota, record: nil).action == .none,
    "monthly windows must not be mistaken for weekly quota"
)
expect(
    failedRecord?.lastFailureAt == acceptedAt && failedRecord?.lastFailureMessage != nil,
    "failed primer diagnostics must be retained without marking the request accepted"
)
if let failedRecord {
    let restoredFailure = try JSONDecoder().decode(
        QuotaPrimerRecord.self, from: JSONEncoder().encode(failedRecord)
    )
    expect(restoredFailure == failedRecord, "primer failure diagnostics must survive persistence")
} else {
    expect(false, "failed primer diagnostics must be available for persistence")
}
let receipt = QuotaPrimerReceipt(
    threadID: "00000000-0000-4000-8000-000000000001", inputTokens: 101, outputTokens: 13, completedAt: acceptedAt
)
let acceptedWithReceipt = QuotaPrimerPolicy.recordingAcceptance(
    record: attemptedRecord, attemptedAt: attemptedAt, acceptedAt: acceptedAt, receipt: receipt
)
expect(
    acceptedWithReceipt?.lastCompletion == receipt && acceptedWithReceipt?.verifiedAt == nil,
    "request completion evidence must persist separately from quota activation"
)
if let acceptedWithReceipt {
    let restoredReceipt = try JSONDecoder().decode(
        QuotaPrimerRecord.self, from: JSONEncoder().encode(acceptedWithReceipt)
    )
    expect(restoredReceipt.lastCompletion == receipt, "completion evidence must survive restarting the app")
} else {
    expect(false, "an accepted primer must retain its completion evidence")
}
expect(
    QuotaPrimerPolicy.recordingFailure(
        record: attemptedRecord,
        attemptedAt: attemptedAt.addingTimeInterval(-1),
        failedAt: acceptedAt,
        message: "outdated failure"
    ) == nil,
    "an outdated failure must not overwrite a newer attempt"
)

var sharedAccountFirst = slidingFirstSnapshot
sharedAccountFirst.accountReconciliationID = "same-logical-account"
var sharedAccountSecond = slidingFirstSnapshot
sharedAccountSecond.profileID = "codex-managed"
sharedAccountSecond.accountReconciliationID = "same-logical-account"
expect(
    QuotaPrimerPolicy.recordKey(for: sharedAccountFirst) == QuotaPrimerPolicy.recordKey(for: sharedAccountSecond),
    "connections reconciled to one logical account must share primer evidence and duplicate-send protection"
)

var activePrimaryWithUnusedSupplement = beforeReset
activePrimaryWithUnusedSupplement.meters.append(
    QuotaMeter(
        id: "codex.spark-weekly",
        displayName: "Codex Spark · week",
        kind: .rollingWindow,
        unit: .percent,
        scope: MeterScope(kind: "model-family", id: "codex-spark"),
        usedFraction: 0,
        resetsAt: projectedReset,
        windowSeconds: weeklySeconds,
        priority: 20,
        source: "selftest"
    )
)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: activePrimaryWithUnusedSupplement, record: nil).action == .none,
    "an unused supplemental bucket must not prime an account with nonzero weekly usage"
)

var unusedPrimaryWithBusySupplement = slidingSecondSnapshot
var busySupplement = activePrimaryWithUnusedSupplement.meters[1]
busySupplement.usedFraction = 0.5
unusedPrimaryWithBusySupplement.meters.append(busySupplement)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: unusedPrimaryWithBusySupplement, record: firstEvaluation.record).action == .prime,
    "independent supplemental usage must not conceal the inactive Codex weekly clock"
)

let migratedAttempt = QuotaPrimerPolicy.migrateAttemptedReset(observationStart)
expect(
    migratedAttempt.legacySuppressUntil
        == observationStart.addingTimeInterval(QuotaPrimerPolicy.automaticRetryDelay),
    "v1 attempt markers must preserve the request cooldown without claiming an active weekly cycle"
)

print("cappy-client-state-selftest: all checks passed")
