import AppKit
import CappyClientState
import Foundation
import QuotaContracts
import QuotaProviderKit

struct CurrentCLIAccountContext: Identifiable, Equatable {
    let profile: ProfileSummary
    let snapshot: AccountSnapshot

    var id: String { profile.id }
    var displayIdentity: String {
        snapshot.identity?.email
            ?? snapshot.identity?.displayName
            ?? snapshot.identity?.organization
            ?? snapshot.provider.displayName
    }
}

struct CLIAccountChangeNotice: Identifiable, Equatable {
    let current: CurrentCLIAccountContext
    let previousIdentity: String
    let previousAccountWasKept: Bool

    var id: String { current.profile.id }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshots: [AccountSnapshot] = []
    @Published var profiles: [ProfileSummary] = []
    @Published var providers: [ProviderDescriptor] = []
    @Published var isRefreshing = false
    @Published private(set) var isReorderingAccounts = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published var addAccountMessage: String?
    @Published private(set) var activeAddJobID: String?
    @Published private(set) var activeLoginJobIDs: [String: String] = [:]
    @Published private var rememberedCLIAccounts: [String: RememberedCLIAccount]
    @Published private var currentCLISignInSelections: [String: Bool]
    private var attemptedQuotaPrimerResets: [String: Date]
    private var serverProcess: Process?

    private static let rememberedCLIAccountsKey = "accounts.rememberedCLIAccounts.v1"
    private static let currentCLISignInSelectionsKey = "connections.currentCLISignIns.v1"

    var managedProfiles: [ProfileSummary] { profiles.filter(\.isManaged) }
    var defaultProfiles: [ProfileSummary] { profiles.filter(\.isDefault) }

    var dashboardSnapshots: [AccountSnapshot] {
        profiles.compactMap { profile in
            guard let snapshot = snapshot(profileID: profile.id) else { return nil }
            if profile.isDefault {
                guard profile.isEnabled,
                    usesCurrentCLISignIn(providerID: profile.providerID),
                    snapshot.authenticationState == .authenticated,
                    matchingManagedProfile(for: snapshot) == nil
                else { return nil }
            }
            return snapshot
        }
    }

    var hasUnmanagedCurrentCLIAccount: Bool {
        defaultProfiles.contains { profile in
            guard profile.isEnabled,
                usesCurrentCLISignIn(providerID: profile.providerID),
                let snapshot = snapshot(profileID: profile.id), snapshot.authenticationState == .authenticated
            else { return false }
            return matchingManagedProfile(for: snapshot) == nil
        }
    }

    var initialCLIAccountChoices: [CurrentCLIAccountContext] {
        currentCLIAccounts.filter { context in
            guard let currentKey = identityKey(context.snapshot) else { return false }
            return currentCLISignInSelections[context.profile.providerID] == nil
                && recognizeCLIAccount(
                    currentIdentityKey: currentKey,
                    remembered: rememberedCLIAccounts[context.profile.providerID]
                ) == .firstDiscovery
                && matchingManagedProfile(for: context.snapshot) == nil
        }
    }

    var cliAccountChangeNotices: [CLIAccountChangeNotice] {
        currentCLIAccounts.compactMap { context in
            guard usesCurrentCLISignIn(providerID: context.profile.providerID),
                let currentKey = identityKey(context.snapshot),
                case .changed(let remembered) = recognizeCLIAccount(
                    currentIdentityKey: currentKey,
                    remembered: rememberedCLIAccounts[context.profile.providerID]
                )
            else { return nil }
            let previousAccountWasKept =
                remembered.wasKept
                || managedProfiles.contains { profile in
                    guard let snapshot = snapshot(profileID: profile.id) else { return false }
                    return identityKey(snapshot) == remembered.identityKey
                }
            return CLIAccountChangeNotice(
                current: context,
                previousIdentity: remembered.displayIdentity,
                previousAccountWasKept: previousAccountWasKept
            )
        }
    }

    var duplicateWarning: String? {
        let managedIDs = Set(managedProfiles.map(\.id))
        let identityKeys = snapshots.compactMap { snapshot -> String? in
            guard managedIDs.contains(snapshot.profileID) else { return nil }
            guard snapshot.authenticationState == .authenticated, let identity = snapshot.identity else { return nil }
            let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let stableID = identity.stableID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !email.isEmpty || !stableID.isEmpty else { return nil }
            return [snapshot.provider.id, email, stableID].joined(separator: "|")
        }
        if Dictionary(grouping: identityKeys, by: { $0 }).values.contains(where: { $0.count > 1 }) {
            return "A provider account has more than one connection through Cappy. Use Connections to remove the duplicate."
        }
        let labelKeys = managedProfiles.map {
            [$0.providerID, $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()].joined(separator: "|")
        }
        if Dictionary(grouping: labelKeys, by: { $0 }).values.contains(where: { $0.count > 1 }) {
            return
                "Multiple connections through Cappy share the same name. They are unchanged so you can choose which ones to remove."
        }
        return nil
    }

    init() {
        let remembered = Self.loadRememberedCLIAccounts()
        rememberedCLIAccounts = remembered
        currentCLISignInSelections = Self.loadCurrentCLISignInSelections(migrating: remembered)
        attemptedQuotaPrimerResets = Self.loadAttemptedQuotaPrimerResets()
        Task {
            await ensureServerAndLoad()
            await backgroundRefresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await backgroundRefresh()
            }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            do {
                let value = try await rpc("refresh.all")
                replaceSnapshots(try value?.decode([AccountSnapshot].self) ?? [])
                let profileValue = try await rpc("profile.list")
                profiles = try profileValue?.decode([ProfileSummary].self) ?? profiles
                reconcileRememberedCLIAccounts()
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
            isRefreshing = false
        }
    }

    func primeInactiveWeeklyQuotas() {
        guard UserDefaults.standard.bool(forKey: QuotaPrimerPolicy.enabledDefaultsKey) else { return }
        for snapshot in snapshots where attemptedQuotaPrimerResets[snapshot.profileID] == nil {
            guard QuotaPrimerPolicy.hasInactiveWeeklyWindow(snapshot) else { continue }
            attemptedQuotaPrimerResets[snapshot.profileID] = snapshot.observedAt
            persistAttemptedQuotaPrimerResets()
            Task { await sendQuotaPrimer(profileID: snapshot.profileID) }
        }
    }

    func addAccount(
        providerID: String,
        label: String? = nil,
        sourceProfileID: String? = nil,
        expectedSourceEmail: String? = nil
    ) async -> Bool {
        addAccountMessage = "Preparing a secure sign-in…"
        do {
            var params: [String: JSONValue] = ["providerID": .string(providerID)]
            if let label { params["label"] = .string(label) }
            if let sourceProfileID { params["sourceProfileID"] = .string(sourceProfileID) }
            if let expectedSourceEmail { params["expectedSourceEmail"] = .string(expectedSourceEmail) }
            let value = try await rpc("profile.enroll", .object(params))
            var job = try require(value, as: LoginJob.self)
            activeAddJobID = job.id
            if sourceProfileID == nil {
                addAccountMessage =
                    "Finish signing in with the provider. Cappy will name the connection after the verified account."
            } else {
                addAccountMessage =
                    "Sign in with the same account. Cappy will verify the identity before adding the connection."
            }
            while job.state == .running || job.state == .verifying {
                try await Task.sleep(for: .milliseconds(500))
                let status = try await rpc("login.status", .object(["jobID": .string(job.id)]))
                job = try require(status, as: LoginJob.self)
                if job.state == .verifying { addAccountMessage = "Verifying the signed-in account…" }
            }
            activeAddJobID = nil
            addAccountMessage = job.message ?? (job.state == .succeeded ? "Connection added." : "Sign-in did not complete.")
            await loadAccountState()
            if job.state == .succeeded, let sourceProfileID {
                rememberCurrentCLIAccount(profileID: sourceProfileID, wasKept: true)
            }
            return job.state == .succeeded
        } catch {
            activeAddJobID = nil
            addAccountMessage = error.localizedDescription
            return false
        }
    }

    func cancelAddAccount() async {
        guard let id = activeAddJobID else { return }
        do {
            let value = try await rpc("login.cancel", .object(["jobID": .string(id)]))
            let job = try require(value, as: LoginJob.self)
            addAccountMessage = job.message ?? "Sign-in cancelled."
        } catch {
            addAccountMessage = error.localizedDescription
        }
        activeAddJobID = nil
        await loadAccountState()
    }

    func login(profileID: String) {
        guard activeLoginJobIDs[profileID] == nil else { return }
        Task {
            do {
                let value = try await rpc("profile.login", .object(["profileID": .string(profileID)]))
                var job = try require(value, as: LoginJob.self)
                activeLoginJobIDs[profileID] = job.id
                errorMessage = nil
                while job.state == .running || job.state == .verifying {
                    try await Task.sleep(for: .milliseconds(500))
                    let status = try await rpc("login.status", .object(["jobID": .string(job.id)]))
                    job = try require(status, as: LoginJob.self)
                }
                if activeLoginJobIDs[profileID] == job.id {
                    activeLoginJobIDs.removeValue(forKey: profileID)
                }
                await loadAccountState()
                if job.state == .succeeded {
                    errorMessage = nil
                } else if job.state == .cancelled {
                    noticeMessage = job.message
                    errorMessage = nil
                } else {
                    errorMessage = job.message ?? "Sign-in did not complete."
                }
            } catch {
                activeLoginJobIDs.removeValue(forKey: profileID)
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelLogin(profileID: String) {
        guard let jobID = activeLoginJobIDs[profileID] else { return }
        Task {
            do {
                let value = try await rpc("login.cancel", .object(["jobID": .string(jobID)]))
                let job = try require(value, as: LoginJob.self)
                if activeLoginJobIDs[profileID] == jobID {
                    activeLoginJobIDs.removeValue(forKey: profileID)
                }
                noticeMessage = job.message ?? "Sign-in cancelled."
                errorMessage = nil
                await loadAccountState()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func isSigningIn(profileID: String) -> Bool {
        activeLoginJobIDs[profileID] != nil
    }

    func removeAccount(profileID: String) async -> Bool {
        do {
            let value = try await rpc("profile.remove", .object(["profileID": .string(profileID)]))
            let result = try require(value, as: ProfileRemovalResult.self)
            profiles.removeAll { $0.id == profileID }
            snapshots.removeAll { $0.profileID == profileID }
            attemptedQuotaPrimerResets.removeValue(forKey: profileID)
            persistAttemptedQuotaPrimerResets()
            errorMessage = nil
            noticeMessage = result.warning
            await loadAccountState()
            return true
        } catch {
            let message = error.localizedDescription
            await loadAccountState()
            errorMessage = message
            return false
        }
    }

    func setAccountDisplayName(profileID: String, displayName: String?) async -> Bool {
        do {
            var params: [String: JSONValue] = ["profileID": .string(profileID)]
            if let displayName {
                params["label"] = .string(displayName)
            }
            let value = try await rpc(
                "profile.rename",
                .object(params)
            )
            let renamed = try require(value, as: ProfileSummary.self)
            if let index = profiles.firstIndex(where: { $0.id == profileID }) {
                profiles[index] = renamed
            }
            if let index = snapshots.firstIndex(where: { $0.profileID == profileID }) {
                snapshots[index].profileLabel = renamed.label
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func configure(profileID: String) {
        Task {
            do {
                let value = try await rpc("profile.configure", .object(["profileID": .string(profileID)]))
                let response = try require(value, as: AdapterResponse.self)
                guard response.ok else {
                    throw NSError(
                        domain: "ai.upriver.cappy.Menu", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: response.message ?? "Could not set up quota."])
                }
                noticeMessage = response.warnings.first ?? response.message ?? "Quota capture is enabled."
                errorMessage = nil
                await loadAccountState()
            } catch {
                noticeMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func quit() {
        shutdownServer()
        NSApplication.shared.terminate(nil)
    }

    func shutdownServer() {
        _ = try? LocalRPCClient(timeoutSeconds: 1).call(method: "system.shutdown")
    }

    func reorderAccounts(profileIDs: [String]) {
        guard !isReorderingAccounts else { return }
        let currentIDs = profiles.map(\.id)
        guard profileIDs.count == currentIDs.count,
            Set(profileIDs).count == profileIDs.count,
            Set(profileIDs) == Set(currentIDs),
            profileIDs != currentIDs
        else { return }

        applyOrder(profileIDs)
        isReorderingAccounts = true
        Task {
            do {
                let params: JSONValue = .object(["profileIDs": .array(profileIDs.map(JSONValue.string))])
                let value = try await rpc("profile.reorder", params)
                profiles = try require(value, as: [ProfileSummary].self)
                applyOrder(profiles.map(\.id))
                errorMessage = nil
            } catch {
                let message = error.localizedDescription
                await loadAccountState()
                errorMessage = message
            }
            isReorderingAccounts = false
        }
    }

    func reorderDashboardAccounts(profileIDs: [String]) {
        let dashboardIDs = dashboardSnapshots.map(\.profileID)
        guard profileIDs.count == dashboardIDs.count,
            Set(profileIDs) == Set(dashboardIDs),
            profileIDs != dashboardIDs
        else { return }

        let dashboardIDSet = Set(dashboardIDs)
        var remaining = profileIDs.makeIterator()
        let fullOrder = profiles.map { profile in
            dashboardIDSet.contains(profile.id) ? (remaining.next() ?? profile.id) : profile.id
        }
        reorderAccounts(profileIDs: fullOrder)
    }

    func snapshot(profileID: String) -> AccountSnapshot? {
        snapshots.first { $0.profileID == profileID }
    }

    func matchingManagedProfile(for defaultSnapshot: AccountSnapshot) -> ProfileSummary? {
        guard let key = identityKey(defaultSnapshot) else { return nil }
        return managedProfiles.first { profile in
            guard let candidate = snapshot(profileID: profile.id), candidate.authenticationState == .authenticated else { return false }
            return identityKey(candidate) == key
        }
    }

    func useCurrentCLISignIn(profileID: String) {
        guard let profile = defaultProfiles.first(where: { $0.id == profileID }) else { return }
        setCurrentCLISignInSelection(providerID: profile.providerID, enabled: true)
        let hasSpecificConnection = snapshot(profileID: profileID).flatMap(matchingManagedProfile(for:)) != nil
        rememberCurrentCLIAccount(profileID: profileID, wasKept: hasSpecificConnection)
    }

    func useSpecificAccountConnection(profileID: String) {
        guard let profile = defaultProfiles.first(where: { $0.id == profileID }) else { return }
        setCurrentCLISignInSelection(providerID: profile.providerID, enabled: false)
        let hasSpecificConnection = snapshot(profileID: profileID).flatMap(matchingManagedProfile(for:)) != nil
        rememberCurrentCLIAccount(profileID: profileID, wasKept: hasSpecificConnection)
    }

    func stopUsingCurrentCLISignIn(providerID: String) {
        setCurrentCLISignInSelection(providerID: providerID, enabled: false)
    }

    func usesCurrentCLISignIn(providerID: String) -> Bool {
        currentCLISignInSelections[providerID] == true
    }

    func acknowledgeCurrentCLIAccount(profileID: String) {
        let isKept = snapshot(profileID: profileID).flatMap(matchingManagedProfile(for:)) != nil
        rememberCurrentCLIAccount(profileID: profileID, wasKept: isKept)
    }

    func dismissCLIAccountChange(profileID: String) {
        acknowledgeCurrentCLIAccount(profileID: profileID)
    }

    func loadAccountState() async {
        do {
            let profileValue = try await rpc("profile.list")
            profiles = try profileValue?.decode([ProfileSummary].self) ?? []
            let snapshotValue = try await rpc("snapshot.list")
            snapshots = try snapshotValue?.decode([AccountSnapshot].self) ?? []
            reconcileRememberedCLIAccounts()
            errorMessage = nil
            await synchronizeCurrentCLISignInSelections()
        } catch { errorMessage = error.localizedDescription }
    }

    private func applyOrder(_ profileIDs: [String]) {
        let profileByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        profiles = profileIDs.compactMap { profileByID[$0] }

        let snapshotByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.profileID, $0) })
        let orderedSnapshots = profileIDs.compactMap { snapshotByID[$0] }
        let knownIDs = Set(profileIDs)
        snapshots = orderedSnapshots + snapshots.filter { !knownIDs.contains($0.profileID) }
    }

    private func identityKey(_ snapshot: AccountSnapshot) -> String? {
        guard let identity = snapshot.identity else { return nil }
        let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let stableID = identity.stableID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !email.isEmpty || !stableID.isEmpty else { return nil }
        return [snapshot.provider.id, email, stableID].joined(separator: "|")
    }

    private var currentCLIAccounts: [CurrentCLIAccountContext] {
        defaultProfiles.compactMap { profile in
            guard let snapshot = snapshot(profileID: profile.id),
                snapshot.authenticationState == .authenticated,
                identityKey(snapshot) != nil
            else { return nil }
            return CurrentCLIAccountContext(profile: profile, snapshot: snapshot)
        }
    }

    private func rememberCurrentCLIAccount(profileID: String, wasKept: Bool) {
        guard let profile = defaultProfiles.first(where: { $0.id == profileID }),
            let snapshot = snapshot(profileID: profileID),
            snapshot.authenticationState == .authenticated,
            let key = identityKey(snapshot)
        else { return }
        rememberedCLIAccounts[profile.providerID] = RememberedCLIAccount(
            identityKey: key,
            displayIdentity: CurrentCLIAccountContext(profile: profile, snapshot: snapshot).displayIdentity,
            wasKept: wasKept
        )
        persistRememberedCLIAccounts()
    }

    private func reconcileRememberedCLIAccounts() {
        var changed = false
        var selectionsChanged = false
        for context in currentCLIAccounts {
            let providerID = context.profile.providerID
            guard let key = identityKey(context.snapshot) else { continue }
            let isKept = matchingManagedProfile(for: context.snapshot) != nil
            if currentCLISignInSelections[providerID] == nil, isKept {
                currentCLISignInSelections[providerID] = false
                selectionsChanged = true
            }
            if let remembered = rememberedCLIAccounts[providerID] {
                if remembered.identityKey == key, isKept, !remembered.wasKept {
                    rememberedCLIAccounts[providerID] = RememberedCLIAccount(
                        identityKey: key,
                        displayIdentity: context.displayIdentity,
                        wasKept: true
                    )
                    changed = true
                }
            } else if isKept {
                rememberedCLIAccounts[providerID] = RememberedCLIAccount(
                    identityKey: key,
                    displayIdentity: context.displayIdentity,
                    wasKept: true
                )
                changed = true
            }
        }
        if changed { persistRememberedCLIAccounts() }
        if selectionsChanged { persistCurrentCLISignInSelections() }
    }

    private static func loadRememberedCLIAccounts() -> [String: RememberedCLIAccount] {
        guard let data = UserDefaults.standard.data(forKey: rememberedCLIAccountsKey),
            let value = try? JSONDecoder().decode([String: RememberedCLIAccount].self, from: data)
        else { return [:] }
        return value
    }

    private func persistRememberedCLIAccounts() {
        guard let data = try? JSONEncoder().encode(rememberedCLIAccounts) else { return }
        UserDefaults.standard.set(data, forKey: Self.rememberedCLIAccountsKey)
    }

    private static func loadCurrentCLISignInSelections(
        migrating remembered: [String: RememberedCLIAccount]
    ) -> [String: Bool] {
        if let data = UserDefaults.standard.data(forKey: currentCLISignInSelectionsKey),
            let value = try? JSONDecoder().decode([String: Bool].self, from: data)
        {
            return value
        }
        // Before connection choices were explicit, every acknowledged default
        // profile remained active. Preserve that behavior for existing users.
        return Dictionary(uniqueKeysWithValues: remembered.keys.map { ($0, true) })
    }

    private func persistCurrentCLISignInSelections() {
        guard let data = try? JSONEncoder().encode(currentCLISignInSelections) else { return }
        UserDefaults.standard.set(data, forKey: Self.currentCLISignInSelectionsKey)
    }

    private func setCurrentCLISignInSelection(providerID: String, enabled: Bool) {
        currentCLISignInSelections[providerID] = enabled
        persistCurrentCLISignInSelections()
        Task { await setDefaultProfileEnabled(providerID: providerID, enabled: enabled) }
    }

    private func synchronizeCurrentCLISignInSelections() async {
        for profile in defaultProfiles {
            guard let selected = currentCLISignInSelections[profile.providerID], profile.isEnabled != selected else { continue }
            await setDefaultProfileEnabled(providerID: profile.providerID, enabled: selected)
        }
    }

    private func setDefaultProfileEnabled(providerID: String, enabled: Bool) async {
        guard let profile = defaultProfiles.first(where: { $0.providerID == providerID }) else { return }
        do {
            let value = try await rpc(
                "profile.setEnabled",
                .object(["profileID": .string(profile.id), "enabled": .bool(enabled)])
            )
            let updated = try require(value, as: ProfileSummary.self)
            if let index = profiles.firstIndex(where: { $0.id == updated.id }) {
                profiles[index] = updated
            }
            let refreshed: AccountSnapshot?
            if enabled {
                let snapshotValue = try await rpc("refresh.profile", .object(["profileID": .string(profile.id)]))
                refreshed = try require(snapshotValue, as: AccountSnapshot.self)
            } else {
                refreshed = nil
            }
            if let refreshed {
                upsertRefreshedSnapshot(refreshed)
            }
            if let latestSelection = currentCLISignInSelections[providerID], latestSelection != enabled {
                await setDefaultProfileEnabled(providerID: providerID, enabled: latestSelection)
                return
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func backgroundRefresh() async {
        do {
            let value = try await rpc("refresh.all")
            replaceSnapshots(try value?.decode([AccountSnapshot].self) ?? snapshots)
            let profileValue = try await rpc("profile.list")
            profiles = try profileValue?.decode([ProfileSummary].self) ?? profiles
            reconcileRememberedCLIAccounts()
            errorMessage = nil
        } catch {
            await loadAccountState()
        }
    }

    private func replaceSnapshots(_ refreshed: [AccountSnapshot]) {
        let previous = snapshots
        snapshots = refreshed
        scheduleQuotaPrimers(previous: previous, refreshed: refreshed)
        primeInactiveWeeklyQuotas()
    }

    private func upsertRefreshedSnapshot(_ refreshed: AccountSnapshot) {
        let previous = snapshots
        if let index = snapshots.firstIndex(where: { $0.profileID == refreshed.profileID }) {
            snapshots[index] = refreshed
        } else {
            snapshots.append(refreshed)
        }
        scheduleQuotaPrimers(previous: previous, refreshed: [refreshed])
        primeInactiveWeeklyQuotas()
    }

    private func scheduleQuotaPrimers(previous: [AccountSnapshot], refreshed: [AccountSnapshot]) {
        guard UserDefaults.standard.bool(forKey: QuotaPrimerPolicy.enabledDefaultsKey) else { return }
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.profileID, $0) })
        for snapshot in refreshed {
            guard let oldSnapshot = previousByID[snapshot.profileID],
                let marker = QuotaPrimerPolicy.dueResetMarker(previous: oldSnapshot, refreshed: snapshot),
                attemptedQuotaPrimerResets[snapshot.profileID].map({ $0 >= marker }) != true
            else { continue }

            // Persist before launching the request so overlapping manual and
            // background refreshes cannot send the same primer twice.
            attemptedQuotaPrimerResets[snapshot.profileID] = marker
            persistAttemptedQuotaPrimerResets()
            Task { await sendQuotaPrimer(profileID: snapshot.profileID) }
        }
    }

    private func sendQuotaPrimer(profileID: String) async {
        do {
            let value = try await rpc("quota.prime", .object(["profileID": .string(profileID)]))
            let response = try require(value, as: AdapterResponse.self)
            guard response.ok else {
                throw NSError(
                    domain: "ai.upriver.cappy.Menu", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: response.message ?? "Quota primer failed."])
            }
            let label = profiles.first(where: { $0.id == profileID })?.label ?? "an account"
            noticeMessage = "Started the refreshed weekly quota clock for \(label)."
        } catch {
            let label = profiles.first(where: { $0.id == profileID })?.label ?? "an account"
            errorMessage = "Couldn’t start the refreshed weekly quota clock for \(label): \(error.localizedDescription)"
        }
    }

    private static func loadAttemptedQuotaPrimerResets() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: QuotaPrimerPolicy.attemptedResetsDefaultsKey),
            let value = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return value
    }

    private func persistAttemptedQuotaPrimerResets() {
        guard let data = try? JSONEncoder().encode(attemptedQuotaPrimerResets) else { return }
        UserDefaults.standard.set(data, forKey: QuotaPrimerPolicy.attemptedResetsDefaultsKey)
    }

    private func ensureServerAndLoad() async {
        let initialPing = try? await rpc("system.ping")
        if !isCompatiblePing(initialPing) {
            if initialPing != nil {
                _ = try? await rpc("system.shutdown")
                try? await Task.sleep(for: .milliseconds(300))
            }
            do {
                try launchServer()
                for _ in 0..<60 {
                    try await Task.sleep(for: .milliseconds(50))
                    if isCompatiblePing(try? await rpc("system.ping")) { break }
                }
            } catch { errorMessage = error.localizedDescription }
        }
        do {
            let value = try await rpc("provider.list")
            providers = try value?.decode([ProviderDescriptor].self) ?? []
        } catch { errorMessage = error.localizedDescription }
        await loadAccountState()
    }

    private func isCompatiblePing(_ value: JSONValue?) -> Bool {
        value?["serverAPIVersion"]?.doubleValue == Double(quotaAppServerAPIVersion)
            && value?["releaseVersion"]?.stringValue == quotaReleaseVersion
    }

    private func rpc(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue? {
        try await Task.detached(priority: .userInitiated) {
            try LocalRPCClient().call(method: method, params: params)
        }.value
    }

    private func require<T: Decodable>(_ value: JSONValue?, as type: T.Type) throws -> T {
        guard let value else {
            throw NSError(
                domain: "ai.upriver.cappy.Menu", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The app server returned an empty response."])
        }
        return try value.decode(type)
    }

    private func launchServer() throws {
        let helperDirectory: URL
        if Bundle.main.bundleURL.pathExtension == "app" {
            helperDirectory = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        } else {
            helperDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        }
        let executable = helperDirectory.appendingPathComponent("quota-appserver")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(
                domain: "ai.upriver.cappy.Menu", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cappy's app-server helper is missing."])
        }
        let process = Process()
        process.executableURL = executable
        process.environment = ProcessEnvironment.sanitized(adding: ["CAPPY_ADAPTER_DIR": helperDirectory.path])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        serverProcess = process
    }
}
