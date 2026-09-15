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
    anchoredEvaluation.action == .none && anchoredEvaluation.record?.confirmedResetAt == projectedReset,
    "two fixed exact reset deadlines must prove that the weekly clock is already active"
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
let verified = QuotaPrimerPolicy.evaluate(
    snapshot: secondVerificationSnapshot,
    record: firstVerification.record
)
expect(
    verified.didVerify && verified.record?.confirmedResetAt == anchoredAfterPrimer,
    "two fixed post-primer deadlines must verify the active clock"
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

let cappedRecord = QuotaPrimerRecord(
    observation: QuotaPrimerPolicy.primaryWeeklyObservation(slidingAfterPrimerOne),
    lastAttemptAt: attemptedAt,
    retrySeriesStartedAt: attemptedAt,
    attemptCount: QuotaPrimerPolicy.maximumAutomaticAttempts,
    acceptedAt: acceptedAt
)
expect(
    QuotaPrimerPolicy.evaluate(snapshot: slidingAfterPrimerTwo, record: cappedRecord).action == .none,
    "automatic retries must stop after the per-cycle attempt cap"
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

let migratedAttempt = QuotaPrimerPolicy.migrateAttemptedReset(observationStart)
expect(
    migratedAttempt.legacySuppressUntil
        == observationStart.addingTimeInterval(TimeInterval(weeklySeconds)),
    "v1 attempt markers must preserve duplicate-send protection only for their historical cycle"
)

print("cappy-client-state-selftest: all checks passed")
