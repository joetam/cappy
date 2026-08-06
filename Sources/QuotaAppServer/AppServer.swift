import Foundation
import QuotaContracts
import QuotaProviderKit

final class AppServer: @unchecked Sendable {
    private struct PendingEnrollment {
        var draft: Profile
        var finalConfigPath: String
    }

    private let store: StateStore
    private let adapters: AdapterRegistry
    private let logins = LoginCoordinator()
    private let refreshLock = NSLock()
    private let enrollmentLock = NSLock()
    private var refreshing: Set<String> = []
    private var pendingEnrollments: [String: PendingEnrollment] = [:]

    init(store: StateStore, adapters: AdapterRegistry) {
        self.store = store
        self.adapters = adapters
        discardOrphanedEnrollments()
        discardPreviouslyDeletedProfiles()
        discardOrphanedManagedProfiles()
        logins.onCompletion = { [weak self] job in
            self?.handleLoginCompletion(job)
        }
    }

    func handle(_ request: RPCRequest) -> RPCResponse {
        guard request.jsonrpc == "2.0", request.id.count <= 128, request.method.count <= 128 else {
            return RPCResponse(
                id: String(request.id.prefix(128)), result: nil, error: RPCErrorPayload(code: -32600, message: "Invalid request"))
        }
        do {
            let result: JSONValue?
            switch request.method {
            case "system.ping":
                result = .object([
                    "contractVersion": .number(Double(quotaContractVersion)),
                    "serverAPIVersion": .number(Double(quotaAppServerAPIVersion)),
                    "releaseVersion": .string(quotaReleaseVersion),
                    "status": .string("ok"),
                ])
            case "system.shutdown":
                result = .object(["status": .string("stopping")])
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
            case "profile.list":
                result = try .encode(store.profiles().map(ProfileSummary.init))
            case "snapshot.list":
                result = try .encode(publicSnapshots(store.snapshots()))
            case "provider.list":
                result = try .encode(providerDescriptors())
            case "refresh.all":
                let refreshed = try refreshAll()
                result = try .encode(publicSnapshots(refreshed))
            case "refresh.profile":
                let id = try requiredString(request.params, "profileID")
                result = try .encode(publicSnapshot(refreshProfile(id: id)))
            case "profile.add":
                result = try .encode(addProfile(params: request.params))
            case "profile.enroll":
                result = try .encode(enrollProfile(params: request.params))
            case "profile.login":
                let id = try requiredString(request.params, "profileID")
                result = try .encode(startLogin(profileID: id))
            case "profile.remove":
                let id = try requiredString(request.params, "profileID")
                result = try .encode(removeProfile(id: id))
            case "profile.configure":
                let id = try requiredString(request.params, "profileID")
                result = try .encode(configureProfile(id: id))
            case "login.status":
                let id = try requiredString(request.params, "jobID")
                guard let job = logins.job(id: id) else { throw appError("Unknown login job") }
                result = try .encode(job)
            case "login.cancel":
                let id = try requiredString(request.params, "jobID")
                let job = try logins.cancel(id: id)
                result = try .encode(job)
            case "quota.ingest":
                result = try .encode(publicSnapshot(ingest(params: request.params)))
            default:
                return RPCResponse(
                    id: request.id, result: nil, error: RPCErrorPayload(code: -32601, message: "Unknown method: \(request.method)"))
            }
            return RPCResponse(id: request.id, result: result, error: nil)
        } catch {
            return RPCResponse(id: request.id, result: nil, error: RPCErrorPayload(code: -32000, message: error.localizedDescription))
        }
    }

    func refreshAll() throws -> [AccountSnapshot] {
        let queue = OperationQueue()
        queue.name = "ai.upriver.cappy.refresh"
        queue.maxConcurrentOperationCount = 4
        for profile in store.profiles() {
            queue.addOperation { [weak self] in _ = try? self?.refreshProfile(id: profile.id) }
        }
        queue.waitUntilAllOperationsAreFinished()
        return store.snapshots()
    }

    private func refreshProfile(id: String) throws -> AccountSnapshot {
        guard let profile = store.profile(id: id) else { throw appError("Unknown profile") }
        refreshLock.lock()
        if refreshing.contains(id) {
            refreshLock.unlock()
            if let existing = store.snapshot(profileID: id) { return existing }
            throw appError("Profile refresh is already running")
        }
        refreshing.insert(id)
        refreshLock.unlock()
        defer {
            refreshLock.lock(); refreshing.remove(id); refreshLock.unlock()
        }

        do {
            let snapshot = try readSnapshot(profile: profile)
            try store.setSnapshot(snapshot)
            return snapshot
        } catch {
            if var previous = store.snapshot(profileID: id) {
                previous.freshness = .stale
                previous.message = error.localizedDescription
                try store.setSnapshot(previous)
                return previous
            }
            let unavailable = AccountSnapshot(
                profileID: profile.id,
                provider: ProviderDescriptor(
                    id: profile.providerID,
                    displayName: adapters.manifest(providerID: profile.providerID)?.displayName ?? profile.providerID),
                profileLabel: profile.label,
                authenticationState: .unknown,
                meters: [],
                freshness: .unavailable,
                message: error.localizedDescription
            )
            try store.setSnapshot(unavailable)
            return unavailable
        }
    }

    private func providerDescriptors() -> [ProviderDescriptor] {
        adapters.all().map { manifest in
            let response = try? AdapterRunner.call(manifest: manifest, request: AdapterRequest(operation: .describe), timeout: 5)
            return response?.provider ?? ProviderDescriptor(id: manifest.providerID, displayName: manifest.displayName)
        }
    }

    private func publicSnapshots(_ snapshots: [AccountSnapshot]) -> [AccountSnapshot] {
        snapshots.map(publicSnapshot)
    }

    private func publicSnapshot(_ snapshot: AccountSnapshot) -> AccountSnapshot {
        var copy = snapshot
        copy.identity?.stableID = nil
        return copy
    }

    private func addProfile(params: JSONValue?) throws -> ProfileSummary {
        let providerID = try requiredString(params, "providerID")
        let label = try requiredString(params, "label").trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidLabel(label) else { throw appError("Profile label must be 1–64 characters and cannot contain control characters") }
        guard let manifest = adapters.manifest(providerID: providerID) else { throw appError("Unknown provider") }
        let prefix = providerID.replacingOccurrences(of: "[^a-zA-Z0-9]+", with: "-", options: .regularExpression)
        let id = "\(prefix)-\(UUID().uuidString.lowercased())"
        let providerDirectory = try managedProviderDirectory(providerID: providerID, createIfMissing: true)
        let path = providerDirectory.appendingPathComponent(id).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let profile = Profile(id: id, providerID: providerID, label: label, configPath: path, isManaged: true)
        do {
            try store.add(profile)
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
        let context = AdapterContext(
            quotaCachePath: QuotaPaths.cacheDirectory.appendingPathComponent("\(id).json").path,
            clientExecutablePath: helperPath(named: "quota")
        )
        let configuration = try? AdapterRunner.call(
            manifest: manifest, request: AdapterRequest(operation: .configure, profile: profile, context: context))
        let pending = AccountSnapshot(
            profileID: id,
            provider: configuration?.provider ?? ProviderDescriptor(id: providerID, displayName: manifest.displayName),
            profileLabel: label,
            authenticationState: .unauthenticated,
            meters: [],
            freshness: .pending,
            message: configuration?.warnings.first ?? "Credential slot created. Sign in when you are ready."
        )
        do {
            try store.setSnapshot(pending)
        } catch {
            _ = try? store.remove(id: profile.id)
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
        return ProfileSummary(profile)
    }

    private func enrollProfile(params: JSONValue?) throws -> LoginJob {
        let providerID = try requiredString(params, "providerID")
        let label = try requiredString(params, "label").trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidLabel(label) else { throw appError("Profile label must be 1–64 characters and cannot contain control characters") }
        guard let manifest = adapters.manifest(providerID: providerID) else { throw appError("Unknown provider") }
        guard !store.hasLabel(providerID: providerID, label: label), !hasPendingLabel(providerID: providerID, label: label) else {
            throw appError("A \(manifest.displayName) profile named “\(label)” already exists or is signing in")
        }

        enrollmentLock.lock()
        let enrollmentCapacityAvailable = store.profiles().count + pendingEnrollments.count < 64
        enrollmentLock.unlock()
        guard enrollmentCapacityAvailable else { throw appError("Cappy supports up to 64 tracked or pending profiles") }

        let prefix = providerID.replacingOccurrences(of: "[^a-zA-Z0-9]+", with: "-", options: .regularExpression)
        let id = "\(prefix)-\(UUID().uuidString.lowercased())"
        let stagingPath = QuotaPaths.pendingProfilesDirectory.appendingPathComponent(id).path
        let finalPath = try managedProviderDirectory(providerID: providerID, createIfMissing: true).appendingPathComponent(id).path
        try FileManager.default.createDirectory(
            atPath: stagingPath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let draft = Profile(id: id, providerID: providerID, label: label, configPath: stagingPath, isManaged: true)
        enrollmentLock.lock()
        let normalizedLabel = normalizedIdentityPart(label)
        let capacityAvailable = store.profiles().count + pendingEnrollments.count < 64
        let labelReserved = pendingEnrollments.values.contains {
            $0.draft.providerID == providerID && normalizedIdentityPart($0.draft.label) == normalizedLabel
        }
        let labelCommitted = store.hasLabel(providerID: providerID, label: label)
        if !capacityAvailable || labelReserved || labelCommitted {
            enrollmentLock.unlock()
            try? FileManager.default.removeItem(atPath: stagingPath)
            if !capacityAvailable { throw appError("Cappy supports up to 64 tracked or pending profiles") }
            throw appError("A \(manifest.displayName) profile named “\(label)” already exists or is signing in")
        }
        pendingEnrollments[id] = PendingEnrollment(draft: draft, finalConfigPath: finalPath)
        enrollmentLock.unlock()

        let context = adapterContext(profileID: id)
        let configuration: AdapterResponse
        do {
            configuration = try AdapterRunner.call(
                manifest: manifest, request: AdapterRequest(operation: .configure, profile: draft, context: context))
        } catch {
            discardPendingEnrollment(profileID: id)
            throw error
        }
        guard configuration.ok else {
            discardPendingEnrollment(profileID: id)
            throw appError(configuration.message ?? "Could not prepare the profile")
        }
        do {
            return try startLogin(profile: draft, manifest: manifest)
        } catch {
            discardPendingEnrollment(profileID: id)
            throw error
        }
    }

    private func startLogin(profileID: String) throws -> LoginJob {
        guard let profile = store.profile(id: profileID),
            let manifest = adapters.manifest(providerID: profile.providerID)
        else { throw appError("Unknown profile") }
        return try startLogin(profile: profile, manifest: manifest)
    }

    private func startLogin(profile: Profile, manifest: AdapterManifest) throws -> LoginJob {
        let response = try AdapterRunner.call(manifest: manifest, request: AdapterRequest(operation: .prepareLogin, profile: profile))
        guard response.ok, let command = response.loginCommand else {
            throw appError(response.message ?? "Adapter did not provide a login command")
        }
        return try logins.start(profileID: profile.id, command: command)
    }

    private func handleLoginCompletion(_ job: LoginJob) {
        if let pending = pendingEnrollment(profileID: job.profileID) {
            guard job.state == .verifying else {
                discardPendingEnrollment(profileID: job.profileID)
                return
            }
            do {
                let snapshot = try readSnapshot(profile: pending.draft)
                guard snapshot.authenticationState == .authenticated else {
                    throw appError(snapshot.message ?? "The provider did not report a signed-in account")
                }
                if let duplicate = duplicateProfile(for: snapshot) {
                    throw appError("This account is already tracked as “\(duplicate.label)”.")
                }
                guard logins.beginCommit(id: job.id) else { throw appError("Sign-in was cancelled") }
                _ = try managedProviderDirectory(providerID: pending.draft.providerID, createIfMissing: true)
                try FileManager.default.moveItem(atPath: pending.draft.configPath, toPath: pending.finalConfigPath)
                var committed = pending.draft
                committed.configPath = pending.finalConfigPath
                do {
                    try store.commit(committed, snapshot: snapshot)
                } catch {
                    try? FileManager.default.removeItem(atPath: pending.finalConfigPath)
                    throw error
                }
                removePendingRecord(profileID: job.profileID)
                logins.succeed(id: job.id, message: "Added \(committed.label).")
            } catch {
                discardPendingEnrollment(profileID: job.profileID)
                logins.fail(id: job.id, message: error.localizedDescription)
            }
            return
        }

        guard job.state == .verifying else { return }
        do {
            let snapshot = try refreshProfile(id: job.profileID)
            guard snapshot.authenticationState == .authenticated else {
                throw appError(snapshot.message ?? "The provider did not report a signed-in account")
            }
            logins.succeed(id: job.id, message: "Signed in.")
        } catch {
            logins.fail(id: job.id, message: error.localizedDescription)
        }
    }

    private func removeProfile(id: String) throws -> ProfileRemovalResult {
        guard let profile = store.profile(id: id) else { throw appError("Unknown profile") }
        logins.cancelJobs(profileID: id)
        let managedConfigURL = profile.isManaged ? try validatedManagedConfigURL(profile) : nil
        var stagedDeletionURL: URL?
        if let managedConfigURL, FileManager.default.fileExists(atPath: managedConfigURL.path) {
            let destination = QuotaPaths.deletedProfilesDirectory.appendingPathComponent(profile.id, isDirectory: true)
            do {
                try FileManager.default.moveItem(at: managedConfigURL, to: destination)
                stagedDeletionURL = destination
            } catch {
                throw appError("Could not safely stage this profile’s local sign-in data for removal: \(error.localizedDescription)")
            }
        }

        let removed: Profile
        do {
            guard let value = try store.remove(id: id) else { throw appError("Unknown profile") }
            removed = value
        } catch {
            if let stagedDeletionURL, let managedConfigURL {
                try? FileManager.default.moveItem(at: stagedDeletionURL, to: managedConfigURL)
            }
            throw error
        }
        try? FileManager.default.removeItem(at: QuotaPaths.cacheDirectory.appendingPathComponent("\(id).json"))
        var warning: String?
        if let stagedDeletionURL {
            do {
                try FileManager.default.removeItem(at: stagedDeletionURL)
            } catch {
                warning = "The profile was removed. Its staged local sign-in data will be cleaned up the next time Cappy starts."
            }
        }
        return ProfileRemovalResult(
            profile: ProfileSummary(removed),
            managedCredentialsRemoved: profile.isManaged ? warning == nil : nil,
            warning: warning
        )
    }

    private func readSnapshot(profile: Profile) throws -> AccountSnapshot {
        guard let manifest = adapters.manifest(providerID: profile.providerID) else {
            throw appError("No adapter for \(profile.providerID)")
        }
        let response = try AdapterRunner.call(
            manifest: manifest,
            request: AdapterRequest(operation: .refresh, profile: profile, context: adapterContext(profileID: profile.id))
        )
        guard response.ok, let rawSnapshot = response.snapshot else {
            throw appError(response.message ?? "Adapter refresh failed")
        }
        return try validated(rawSnapshot, for: profile)
    }

    private func adapterContext(profileID: String) -> AdapterContext {
        AdapterContext(
            quotaCachePath: QuotaPaths.cacheDirectory.appendingPathComponent("\(profileID).json").path,
            clientExecutablePath: helperPath(named: "quota")
        )
    }

    private func pendingEnrollment(profileID: String) -> PendingEnrollment? {
        enrollmentLock.lock(); defer { enrollmentLock.unlock() }
        return pendingEnrollments[profileID]
    }

    private func removePendingRecord(profileID: String) {
        enrollmentLock.lock(); pendingEnrollments.removeValue(forKey: profileID); enrollmentLock.unlock()
    }

    private func discardPendingEnrollment(profileID: String) {
        enrollmentLock.lock()
        let pending = pendingEnrollments.removeValue(forKey: profileID)
        enrollmentLock.unlock()
        guard let pending else { return }
        try? FileManager.default.removeItem(atPath: pending.draft.configPath)
        try? FileManager.default.removeItem(at: QuotaPaths.cacheDirectory.appendingPathComponent("\(profileID).json"))
    }

    private func hasPendingLabel(providerID: String, label: String) -> Bool {
        let normalized = normalizedIdentityPart(label)
        enrollmentLock.lock(); defer { enrollmentLock.unlock() }
        return pendingEnrollments.values.contains {
            $0.draft.providerID == providerID && normalizedIdentityPart($0.draft.label) == normalized
        }
    }

    private func duplicateProfile(for candidate: AccountSnapshot) -> Profile? {
        guard let candidateKey = identityKey(candidate) else { return nil }
        let snapshots = store.snapshots()
        guard
            let duplicate = snapshots.first(where: {
                $0.authenticationState == .authenticated && $0.profileID != candidate.profileID && identityKey($0) == candidateKey
            })
        else { return nil }
        return store.profile(id: duplicate.profileID)
    }

    private func identityKey(_ snapshot: AccountSnapshot) -> String? {
        guard let identity = snapshot.identity else { return nil }
        let email = identity.email.map(normalizedIdentityPart).flatMap { $0.isEmpty ? nil : $0 }
        let stableID = identity.stableID.map(normalizedIdentityPart).flatMap { $0.isEmpty ? nil : $0 }
        guard email != nil || stableID != nil else { return nil }
        return [snapshot.provider.id, email ?? "", stableID ?? ""].joined(separator: "|")
    }

    private func normalizedIdentityPart(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func discardOrphanedEnrollments() {
        guard
            let children = try? FileManager.default.contentsOfDirectory(
                at: QuotaPaths.pendingProfilesDirectory, includingPropertiesForKeys: nil)
        else { return }
        for child in children { try? FileManager.default.removeItem(at: child) }
    }

    private func discardPreviouslyDeletedProfiles() {
        guard
            let children = try? FileManager.default.contentsOfDirectory(
                at: QuotaPaths.deletedProfilesDirectory, includingPropertiesForKeys: nil)
        else { return }
        for child in children {
            if let profile = store.profile(id: child.lastPathComponent), profile.isManaged,
                let original = try? validatedManagedConfigURL(profile), !FileManager.default.fileExists(atPath: original.path)
            {
                _ = try? managedProviderDirectory(providerID: profile.providerID, createIfMissing: true)
                if (try? FileManager.default.moveItem(at: child, to: original)) != nil { continue }
            }
            try? FileManager.default.removeItem(at: child)
        }
    }

    private func discardOrphanedManagedProfiles() {
        let trackedPaths = Set(store.profiles().filter(\.isManaged).map { URL(fileURLWithPath: $0.configPath).standardizedFileURL.path })
        guard
            let providerDirectories = try? FileManager.default.contentsOfDirectory(
                at: QuotaPaths.profilesDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { return }
        for providerDirectory in providerDirectories where !providerDirectory.lastPathComponent.hasPrefix(".") {
            guard
                let values = try? providerDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                values.isDirectory == true, values.isSymbolicLink != true,
                let children = try? FileManager.default.contentsOfDirectory(at: providerDirectory, includingPropertiesForKeys: nil)
            else { continue }
            for child in children where !trackedPaths.contains(child.standardizedFileURL.path) {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    private func validatedManagedConfigURL(_ profile: Profile) throws -> URL {
        let expected = try managedProviderDirectory(providerID: profile.providerID, createIfMissing: false)
            .appendingPathComponent(profile.id, isDirectory: true).standardizedFileURL
        let actual = URL(fileURLWithPath: profile.configPath, isDirectory: true).standardizedFileURL
        guard actual.path == expected.path else {
            throw appError("Refused to remove a managed profile whose credential path is outside Cappy’s profile directory")
        }
        if FileManager.default.fileExists(atPath: expected.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: expected.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw appError("Refused to remove a managed profile whose credential path is not a regular directory")
            }
        }
        return expected
    }

    private func managedProviderDirectory(providerID: String, createIfMissing: Bool) throws -> URL {
        guard providerID.range(of: "^[a-z0-9][a-z0-9-]{1,63}$", options: .regularExpression) != nil else {
            throw appError("Invalid provider identity")
        }
        let directory = QuotaPaths.profilesDirectory.appendingPathComponent(providerID, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw appError("Refused to use a non-directory or symbolic link for managed provider data")
            }
        } else if createIfMissing {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } else {
            return directory
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    private func configureProfile(id: String) throws -> AdapterResponse {
        guard let profile = store.profile(id: id),
            let manifest = adapters.manifest(providerID: profile.providerID)
        else { throw appError("Unknown profile") }
        let context = AdapterContext(
            quotaCachePath: QuotaPaths.cacheDirectory.appendingPathComponent("\(id).json").path,
            clientExecutablePath: helperPath(named: "quota")
        )
        return try AdapterRunner.call(
            manifest: manifest, request: AdapterRequest(operation: .configure, profile: profile, context: context))
    }

    private func ingest(params: JSONValue?) throws -> AccountSnapshot {
        guard let params, let cacheValue = params["cache"] else { throw appError("cache is required") }
        var cache = try cacheValue.decode(MeterCache.self)
        guard cache.contractVersion == quotaContractVersion else { throw appError("Unsupported meter-cache contract version") }
        guard store.profile(id: cache.profileID) != nil else { throw appError("Unknown profile") }
        cache.meters = sanitize(cache.meters)
        cache.observedAt = Date()
        let url = QuotaPaths.cacheDirectory.appendingPathComponent("\(cache.profileID).json")
        try JSONEncoder.quota.encode(cache).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try refreshProfile(id: cache.profileID)
    }

    private func sanitize(_ meters: [QuotaMeter]) -> [QuotaMeter] {
        var seenIDs = Set<String>()
        var sanitized: [QuotaMeter] = []
        for meter in meters.prefix(100) {
            var copy = meter
            copy.id = sanitizedText(copy.id, limit: 128)
            guard !copy.id.isEmpty, seenIDs.insert(copy.id).inserted else { continue }
            copy.displayName = sanitizedText(copy.displayName, limit: 128)
            if copy.displayName.isEmpty { copy.displayName = copy.id }
            copy.scope.kind = sanitizedText(copy.scope.kind, limit: 64)
            copy.scope.id = sanitizedText(copy.scope.id, limit: 128)
            copy.scope.displayName = copy.scope.displayName.map { sanitizedText($0, limit: 128) }
            copy.source = sanitizedText(copy.source, limit: 128)
            copy.used = finite(copy.used)
            copy.limit = finite(copy.limit)
            copy.remaining = finite(copy.remaining)
            copy.usedFraction = finite(copy.usedFraction).map { min(max($0, 0), 1) }
            copy.windowSeconds = copy.windowSeconds.map { min(max($0, 0), 10 * 365 * 24 * 60 * 60) }
            copy.priority = min(max(copy.priority, -1_000), 10_000)
            copy.details = nil
            sanitized.append(copy)
        }
        return sanitized.sorted { ($0.priority, $0.displayName, $0.id) < ($1.priority, $1.displayName, $1.id) }
    }

    private func validated(_ snapshot: AccountSnapshot, for profile: Profile) throws -> AccountSnapshot {
        guard snapshot.contractVersion == quotaContractVersion else { throw appError("Adapter returned an unsupported snapshot contract") }
        guard snapshot.profileID == profile.id else { throw appError("Adapter returned a snapshot for the wrong profile") }
        guard snapshot.provider.id == profile.providerID else { throw appError("Adapter returned a mismatched provider identity") }
        var copy = snapshot
        copy.profileLabel = String(profile.label.prefix(64))
        copy.provider.displayName = sanitizedText(copy.provider.displayName, limit: 64)
        copy.provider.symbolName = copy.provider.symbolName.map { sanitizedText($0, limit: 64) }
        copy.provider.accentHex = copy.provider.accentHex.flatMap(validAccentHex)
        copy.authenticationMethod = copy.authenticationMethod.map { sanitizedText($0, limit: 64) }
        copy.message = copy.message.map { sanitizedText($0, limit: 512) }
        if copy.observedAt.timeIntervalSinceNow > 5 * 60 { copy.observedAt = Date() }
        if var subscription = copy.subscription {
            subscription.planName = subscription.planName.map { sanitizedText($0, limit: 64) }
            subscription.billingMode = subscription.billingMode.map { sanitizedText($0, limit: 64) }
            subscription.seatTier = subscription.seatTier.map { sanitizedText($0, limit: 64) }
            copy.subscription = subscription
        }
        if var identity = copy.identity {
            identity.displayName = identity.displayName.map { sanitizedText($0, limit: 128) }
            identity.email = identity.email.map { sanitizedText($0, limit: 254) }
            identity.organization = identity.organization.map { sanitizedText($0, limit: 128) }
            identity.stableID = identity.stableID.map { sanitizedText($0, limit: 256) }
            copy.identity = identity
        }
        copy.meters = sanitize(copy.meters)
        return copy
    }

    private func isValidLabel(_ label: String) -> Bool {
        !label.isEmpty && label.count <= 64 && label.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func sanitizedText(_ value: String, limit: Int) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(limit))
    }

    private func finite(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? $0 : nil }
    }

    private func validAccentHex(_ value: String) -> String? {
        let candidate = String(value.prefix(8))
        guard candidate.count == 6, candidate.allSatisfy({ $0.isHexDigit }) else { return nil }
        return candidate
    }

    private func helperPath(named name: String) -> String? {
        let own = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        let candidate = own.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private func requiredString(_ params: JSONValue?, _ key: String) throws -> String {
        guard let value = params?[key]?.stringValue, !value.isEmpty else { throw appError("\(key) is required") }
        return value
    }

    private func appError(_ message: String) -> NSError {
        NSError(domain: "ai.upriver.cappy.AppServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
