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
    QuotaPrimerPolicy.hasInactiveWeeklyWindow(inactiveWeeklyQuota),
    "enabling the setting must recognize a fresh weekly quota whose reset clock has not started"
)
expect(
    !QuotaPrimerPolicy.hasInactiveWeeklyWindow(claudeSnapshot(from: inactiveWeeklyQuota)),
    "enabling the setting must not prime an inactive Claude weekly quota"
)
expect(
    !QuotaPrimerPolicy.hasInactiveWeeklyWindow(afterReset),
    "an already-running weekly reset clock must not receive an enable-time primer"
)

print("cappy-client-state-selftest: all checks passed")
