import Foundation
import QuotaContracts
import QuotaProviderKit

final class StateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var state: AppState

    init() throws {
        try QuotaPaths.ensureDirectories()
        if FileManager.default.fileExists(atPath: QuotaPaths.stateURL.path) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: QuotaPaths.stateURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                    ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 16 * 1_048_576,
                    let data = FileManager.default.contents(atPath: QuotaPaths.stateURL.path)
                else {
                    throw Self.stateError("State is not a regular file of a safe size")
                }
                let decoded = try JSONDecoder.quota.decode(AppState.self, from: data)
                guard decoded.contractVersion == quotaContractVersion else {
                    throw NSError(
                        domain: "ai.upriver.cappy.State", code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "State contract version \(decoded.contractVersion) is not supported; the file was not modified."
                        ])
                }
                try Self.validate(decoded)
                state = decoded
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: QuotaPaths.stateURL.path)
                let missingDefaults = Self.defaultProfiles().filter { candidate in
                    !state.profiles.contains(where: { $0.id == candidate.id })
                }
                if state.profiles.count + missingDefaults.count <= 64, !missingDefaults.isEmpty {
                    state.profiles.append(contentsOf: missingDefaults)
                    try persist()
                }
            } catch {
                throw NSError(
                    domain: "ai.upriver.cappy.State", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Cappy state could not be read and was left untouched: \(error.localizedDescription)"
                    ])
            }
        } else {
            state = AppState(profiles: Self.defaultProfiles())
            try persist()
        }
    }

    private static func defaultProfiles() -> [Profile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            Profile(
                id: "codex-default",
                providerID: "openai-codex",
                label: "Codex",
                configPath: home.appendingPathComponent(".codex").path,
                isManaged: false,
                isDefault: true
            ),
            Profile(
                id: "claude-default",
                providerID: "anthropic-claude",
                label: "Claude",
                configPath: home.appendingPathComponent(".claude").path,
                isManaged: false,
                isDefault: true
            ),
        ]
    }

    func profiles() -> [Profile] {
        lock.lock(); defer { lock.unlock() }
        return state.profiles
    }

    func profile(id: String) -> Profile? {
        lock.lock(); defer { lock.unlock() }
        return state.profiles.first { $0.id == id }
    }

    func snapshots() -> [AccountSnapshot] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        return state.profiles.compactMap { profile in
            guard var snapshot = state.snapshots[profile.id] else { return nil }
            if snapshot.freshness == .fresh && now.timeIntervalSince(snapshot.observedAt) > 15 * 60 {
                snapshot.freshness = .stale
                snapshot.meters = snapshot.meters.map { meter in
                    var copy = meter
                    copy.status = .stale
                    return copy
                }
            }
            return snapshot
        }
    }

    func snapshot(profileID: String) -> AccountSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return state.snapshots[profileID]
    }

    func add(_ profile: Profile) throws {
        lock.lock()
        defer { lock.unlock() }
        try validateNewProfileLocked(profile)
        state.profiles.append(profile)
        do {
            try persistLocked()
        } catch {
            state.profiles.removeAll { $0.id == profile.id }
            throw error
        }
    }

    @discardableResult
    func commit(
        _ profile: Profile,
        snapshot: AccountSnapshot,
        automaticLabelBase: String? = nil,
        allowingDuplicateWithProfileID allowedDuplicateProfileID: String? = nil
    ) throws -> Profile {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.profileID == profile.id else { throw stateError("Snapshot does not match the profile being committed") }
        var committedProfile = profile
        var committedSnapshot = snapshot
        if let automaticLabelBase {
            committedProfile.label = availableLabelLocked(
                providerID: profile.providerID,
                base: automaticLabelBase,
                excludingProfileID: allowedDuplicateProfileID
            )
            committedSnapshot.profileLabel = committedProfile.label
        }
        try validateNewProfileLocked(committedProfile, allowingLabelConflictWithProfileID: allowedDuplicateProfileID)
        if let candidateKey = Self.identityKey(snapshot),
            let duplicate = state.snapshots.values.first(where: {
                $0.authenticationState == .authenticated
                    && $0.profileID != allowedDuplicateProfileID
                    && Self.identityKey($0) == candidateKey
            }),
            let duplicateProfile = state.profiles.first(where: { $0.id == duplicate.profileID })
        {
            throw stateError("This account is already tracked as “\(duplicateProfile.label)”.")
        }
        state.profiles.append(committedProfile)
        state.snapshots[committedProfile.id] = committedSnapshot
        do {
            try persistLocked()
        } catch {
            state.profiles.removeAll { $0.id == committedProfile.id }
            state.snapshots.removeValue(forKey: committedProfile.id)
            throw error
        }
        return committedProfile
    }

    func reorder(profileIDs: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        let currentIDs = state.profiles.map(\.id)
        guard profileIDs.count == currentIDs.count,
            Set(profileIDs).count == profileIDs.count,
            Set(profileIDs) == Set(currentIDs)
        else {
            throw Self.stateError("Account order must contain every tracked profile exactly once")
        }

        let profilesByID = Dictionary(uniqueKeysWithValues: state.profiles.map { ($0.id, $0) })
        let previous = state.profiles
        state.profiles = profileIDs.compactMap { profilesByID[$0] }
        do {
            try persistLocked()
        } catch {
            state.profiles = previous
            throw error
        }
    }

    func setEnabled(id: String, enabled: Bool) throws -> Profile {
        lock.lock(); defer { lock.unlock() }
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else {
            throw Self.stateError("Unknown profile")
        }
        guard state.profiles[index].isDefault else {
            throw Self.stateError("Only connections through provider CLIs can be enabled or disabled")
        }
        let previous = state.profiles[index]
        state.profiles[index].isEnabled = enabled
        do {
            try persistLocked()
            return state.profiles[index]
        } catch {
            state.profiles[index] = previous
            throw error
        }
    }

    func setProfileLabel(id: String, customDisplayName: String?, automaticLabelBase: String) throws -> Profile {
        lock.lock(); defer { lock.unlock() }
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else {
            throw Self.stateError("Unknown profile")
        }
        guard state.profiles[index].isManaged, !state.profiles[index].isDefault else {
            throw Self.stateError("Only connections through Cappy can have custom display names")
        }
        let providerID = state.profiles[index].providerID
        let label =
            customDisplayName
            ?? availableLabelLocked(providerID: providerID, base: automaticLabelBase, excludingProfileID: id)
        let normalized = Self.normalizedLabel(label)
        guard
            !state.profiles.contains(where: {
                $0.id != id && $0.providerID == providerID && Self.normalizedLabel($0.label) == normalized
            })
        else {
            throw Self.stateError("A connection named “\(label)” already exists for this provider")
        }
        let previousProfile = state.profiles[index]
        let previousSnapshot = state.snapshots[id]
        state.profiles[index].label = label
        state.snapshots[id]?.profileLabel = label
        do {
            try persistLocked()
            return state.profiles[index]
        } catch {
            state.profiles[index] = previousProfile
            state.snapshots[id] = previousSnapshot
            throw error
        }
    }

    @discardableResult
    func remove(id: String) throws -> Profile? {
        lock.lock(); defer { lock.unlock() }
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let profile = state.profiles.remove(at: index)
        let snapshot = state.snapshots.removeValue(forKey: id)
        do {
            try persistLocked()
        } catch {
            state.profiles.insert(profile, at: index)
            if let snapshot { state.snapshots[id] = snapshot }
            throw error
        }
        return profile
    }

    func setSnapshot(_ snapshot: AccountSnapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let profile = state.profiles.first(where: { $0.id == snapshot.profileID }) else {
            throw stateError("Cannot save a snapshot for an untracked profile")
        }
        var currentSnapshot = snapshot
        currentSnapshot.profileLabel = profile.label
        let previous = state.snapshots.updateValue(currentSnapshot, forKey: snapshot.profileID)
        do {
            try persistLocked()
        } catch {
            if let previous {
                state.snapshots[snapshot.profileID] = previous
            } else {
                state.snapshots.removeValue(forKey: snapshot.profileID)
            }
            throw error
        }
    }

    func hasLabel(providerID: String, label: String, excludingProfileID: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let normalized = Self.normalizedLabel(label)
        return state.profiles.contains {
            $0.id != excludingProfileID
                && $0.providerID == providerID
                && Self.normalizedLabel($0.label) == normalized
        }
    }

    private func persist() throws {
        lock.lock(); defer { lock.unlock() }
        try persistLocked()
    }

    private func persistLocked() throws {
        let data = try JSONEncoder.quota.encode(state)
        try data.write(to: QuotaPaths.stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: QuotaPaths.stateURL.path)
    }

    private static func normalizedLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func availableLabelLocked(providerID: String, base: String, excludingProfileID: String?) -> String {
        var ordinal = 1
        while true {
            let suffix = ordinal == 1 ? "" : " (\(ordinal))"
            let candidate = String(base.prefix(max(0, 64 - suffix.count))) + suffix
            let normalized = Self.normalizedLabel(candidate)
            let exists = state.profiles.contains {
                $0.id != excludingProfileID
                    && $0.providerID == providerID
                    && Self.normalizedLabel($0.label) == normalized
            }
            if !exists { return candidate }
            ordinal += 1
        }
    }

    private static func identityKey(_ snapshot: AccountSnapshot) -> String? {
        guard let identity = snapshot.identity else { return nil }
        let email = identity.email.map(normalizedIdentityPart).flatMap { $0.isEmpty ? nil : $0 }
        let stableID = identity.stableID.map(normalizedIdentityPart).flatMap { $0.isEmpty ? nil : $0 }
        guard email != nil || stableID != nil else { return nil }
        return [snapshot.provider.id, email ?? "", stableID ?? ""].joined(separator: "|")
    }

    private static func normalizedIdentityPart(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func validate(_ state: AppState) throws {
        guard state.profiles.count <= 64, state.snapshots.count <= 64 else {
            throw stateError("State contains too many profiles or snapshots")
        }
        let profileIDs = state.profiles.map(\.id)
        guard Set(profileIDs).count == profileIDs.count,
            state.profiles.allSatisfy({
                $0.id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
                    && $0.providerID.range(of: "^[a-z0-9][a-z0-9-]{1,63}$", options: .regularExpression) != nil
                    && !$0.label.isEmpty && $0.label.count <= 64
                    && $0.label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
                    && $0.configPath.hasPrefix("/") && $0.configPath.count <= 4_096
            })
        else {
            throw stateError("State contains invalid profile metadata")
        }
        let knownIDs = Set(profileIDs)
        guard
            state.snapshots.allSatisfy({ key, snapshot in
                let profile = state.profiles.first { $0.id == key }
                let meterIDs = snapshot.meters.map(\.id)
                return knownIDs.contains(key)
                    && snapshot.profileID == key
                    && snapshot.provider.id == profile?.providerID
                    && snapshot.contractVersion == quotaContractVersion
                    && snapshot.meters.count <= 100
                    && Set(meterIDs).count == meterIDs.count
            })
        else {
            throw stateError("State contains an invalid snapshot")
        }
    }

    private func validateNewProfileLocked(
        _ profile: Profile,
        allowingLabelConflictWithProfileID allowedLabelConflictProfileID: String? = nil
    ) throws {
        guard state.profiles.count < 64 else {
            throw stateError("Cappy supports up to 64 tracked profiles")
        }
        guard profile.id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil,
            profile.providerID.range(of: "^[a-z0-9][a-z0-9-]{1,63}$", options: .regularExpression) != nil,
            !profile.label.isEmpty, profile.label.count <= 64,
            profile.label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
            profile.configPath.hasPrefix("/"), profile.configPath.count <= 4_096,
            !(profile.isManaged && profile.isDefault)
        else { throw stateError("Profile identity is invalid") }
        guard !state.profiles.contains(where: { $0.id == profile.id }) else {
            throw stateError("A profile with this identifier already exists")
        }
        let normalizedLabel = Self.normalizedLabel(profile.label)
        guard
            !state.profiles.contains(where: {
                $0.id != allowedLabelConflictProfileID
                    && $0.providerID == profile.providerID
                    && Self.normalizedLabel($0.label) == normalizedLabel
            })
        else {
            throw stateError("A \(profile.providerID) profile named “\(profile.label)” is already tracked")
        }
    }

    private static func stateError(_ message: String) -> NSError {
        NSError(domain: "ai.upriver.cappy.State", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func stateError(_ message: String) -> NSError { Self.stateError(message) }
}
