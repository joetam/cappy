import CappyClientState
import Foundation
import QuotaContracts
import QuotaProviderKit

/// Exercises the real AppModel refresh -> RPC -> adapter -> CLI -> verification
/// path against a local fake provider. It cannot run against the user's state.
@MainActor
enum QuotaPrimerSelfTest {
    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let testRoot = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path + "/cappy-primer-flow-test-"
        guard let statePath = environment["CAPPY_STATE_DIR"],
            URL(fileURLWithPath: statePath).resolvingSymlinksInPath().path.hasPrefix(testRoot),
            let executable = environment["CAPPY_CODEX_PATH"], executable.hasPrefix(statePath + "/")
        else { throw failure("An isolated fake-provider state directory is required.") }

        let client = LocalRPCClient(timeoutSeconds: 20)
        guard let initialValue = try client.call(method: "refresh.all") else { throw failure("Missing provider readings.") }
        let initialReadings = try initialValue.decode([AccountSnapshot].self)
        guard let initial = initialReadings.first(where: { $0.profileID == "codex-default" }),
            initial.identity?.email == "primer-fixture@example.com",
            let observation = QuotaPrimerPolicy.primaryWeeklyObservation(initial),
            let key = QuotaPrimerPolicy.recordKey(for: initial)
        else { throw failure("The provider fixture did not return its unused Codex quota.") }

        let suite = "ai.upriver.cappy.primer-selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw failure("Could not create test defaults.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        var oldObservation = observation
        oldObservation.observedAt.addTimeInterval(-300)
        oldObservation.resetAt = oldObservation.resetAt?.addingTimeInterval(-300)
        let oldAttempt = initial.observedAt.addingTimeInterval(-3 * 24 * 60 * 60)
        let oldRecord = QuotaPrimerRecord(
            observation: oldObservation,
            lastAttemptAt: oldAttempt,
            retrySeriesStartedAt: initial.observedAt.addingTimeInterval(-6 * 24 * 60 * 60),
            attemptCount: 3,
            acceptedAt: oldAttempt.addingTimeInterval(4)
        )
        defaults.set(try JSONEncoder().encode([key: oldRecord]), forKey: QuotaPrimerPolicy.recordsDefaultsKey)
        defaults.set(false, forKey: QuotaPrimerPolicy.enabledDefaultsKey)
        defaults.set(
            try JSONEncoder().encode(["openai-codex": true]), forKey: "connections.currentCLISignIns.v1"
        )
        let model = AppModel(defaults: defaults, startBackgroundTasks: false)
        guard let profileValue = try client.call(method: "profile.list") else { throw failure("Missing provider profiles.") }
        model.profiles = try profileValue.decode([ProfileSummary].self)
        model.refresh()
        try await waitUntil { !model.isRefreshing }
        guard try record(in: defaults, key: key)?.lastAttemptAt == oldAttempt else {
            throw failure("Priming ran despite the opt-in setting being disabled.")
        }

        // The ordinary refresh path must detect and prime the unused account;
        // the test never calls quota.prime or edits an active model's records.
        defaults.set(true, forKey: QuotaPrimerPolicy.enabledDefaultsKey)
        model.refresh()
        do {
            try await waitUntil { try record(in: defaults, key: key)?.lastCompletion != nil }
        } catch {
            let state = try record(in: defaults, key: key)
            throw failure(
                "No automatic completion receipt: \(state?.lastFailureMessage ?? model.errorMessage ?? "no request failure recorded").")
        }
        guard let completed = try record(in: defaults, key: key),
            let receipt = completed.lastCompletion,
            receipt.isValid, receipt.inputTokens == 101, receipt.outputTokens == 13,
            completed.attemptCount == 1, let lastAttempt = completed.lastAttemptAt, lastAttempt > oldAttempt
        else { throw failure("The new request did not persist a valid completion receipt and a renewed request budget.") }
        try await waitUntil { try record(in: defaults, key: key)?.verifiedAt != nil }
        guard model.snapshots.first(where: { $0.profileID == initial.profileID })?.meters.first?.usedFraction == 0.01 else {
            throw failure("The completed request was not verified against refreshed provider quota.")
        }
        model.refresh()
        try await waitUntil { !model.isRefreshing }
        guard try record(in: defaults, key: key)?.attemptCount == 1 else {
            throw failure("Refreshing active quota sent another primer.")
        }
        print("quota-primer-flow: opt-in, old capped records, automatic refresh, completion receipt, and provider verification passed")
    }

    private static func record(in defaults: UserDefaults, key: String) throws -> QuotaPrimerRecord? {
        guard let data = defaults.data(forKey: QuotaPrimerPolicy.recordsDefaultsKey) else { return nil }
        return try JSONDecoder().decode([String: QuotaPrimerRecord].self, from: data)[key]
    }

    private static func waitUntil(_ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !(try condition()) {
            guard Date() < deadline else { throw failure("Timed out waiting for the automatic primer flow.") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ai.upriver.cappy.primer-selftest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
