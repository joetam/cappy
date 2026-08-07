import AppKit
import Foundation
import QuotaContracts
import QuotaProviderKit

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
    private var serverProcess: Process?

    var duplicateWarning: String? {
        let identityKeys = snapshots.compactMap { snapshot -> String? in
            guard snapshot.authenticationState == .authenticated, let identity = snapshot.identity else { return nil }
            let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let stableID = identity.stableID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !email.isEmpty || !stableID.isEmpty else { return nil }
            return [snapshot.provider.id, email, stableID].joined(separator: "|")
        }
        if Dictionary(grouping: identityKeys, by: { $0 }).values.contains(where: { $0.count > 1 }) {
            return "A signed-in account is tracked more than once. Use each card’s ••• menu to remove the extra profile."
        }
        let labelKeys = snapshots.map {
            [$0.provider.id, $0.profileLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()].joined(separator: "|")
        }
        if Dictionary(grouping: labelKeys, by: { $0 }).values.contains(where: { $0.count > 1 }) {
            return "Multiple profiles share the same label. Existing entries are kept so you can choose which ones to remove."
        }
        return nil
    }

    init() {
        Task {
            await ensureServerAndLoad()
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
                snapshots = try value?.decode([AccountSnapshot].self) ?? []
                let profileValue = try await rpc("profile.list")
                profiles = try profileValue?.decode([ProfileSummary].self) ?? profiles
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
            isRefreshing = false
        }
    }

    func addAccount(providerID: String, label: String) async -> Bool {
        addAccountMessage = "Preparing a temporary credential slot…"
        do {
            let value = try await rpc("profile.enroll", .object(["providerID": .string(providerID), "label": .string(label)]))
            var job = try require(value, as: LoginJob.self)
            activeAddJobID = job.id
            addAccountMessage = "Finish signing in with the provider. This slot is not saved until verification succeeds."
            while job.state == .running || job.state == .verifying {
                try await Task.sleep(for: .milliseconds(500))
                let status = try await rpc("login.status", .object(["jobID": .string(job.id)]))
                job = try require(status, as: LoginJob.self)
                if job.state == .verifying { addAccountMessage = "Verifying the signed-in account…" }
            }
            activeAddJobID = nil
            addAccountMessage = job.message ?? (job.state == .succeeded ? "Account added." : "Sign-in did not complete.")
            await loadAccountState()
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
        Task {
            _ = try? await rpc("system.shutdown")
            NSApplication.shared.terminate(nil)
        }
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

    func loadAccountState() async {
        do {
            let profileValue = try await rpc("profile.list")
            profiles = try profileValue?.decode([ProfileSummary].self) ?? []
            let snapshotValue = try await rpc("snapshot.list")
            snapshots = try snapshotValue?.decode([AccountSnapshot].self) ?? []
            errorMessage = nil
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

    private func backgroundRefresh() async {
        do {
            let value = try await rpc("refresh.all")
            snapshots = try value?.decode([AccountSnapshot].self) ?? snapshots
            let profileValue = try await rpc("profile.list")
            profiles = try profileValue?.decode([ProfileSummary].self) ?? profiles
            errorMessage = nil
        } catch {
            await loadAccountState()
        }
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
