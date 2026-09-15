import Foundation
import QuotaContracts

/// A connection and its latest reading. Connections remain independently
/// manageable even when several resolve to the same logical account.
public struct AccountConnectionReading: Equatable, Sendable {
    public var profile: ProfileSummary
    public var snapshot: AccountSnapshot

    public init(profile: ProfileSummary, snapshot: AccountSnapshot) {
        self.profile = profile
        self.snapshot = snapshot
    }
}

/// One account/workspace prepared for presentation from one or more
/// authentication connections.
public struct ReconciledAccount: Identifiable, Equatable, Sendable {
    public var id: String { primaryConnection.profile.id }
    public var identity: AccountIdentityKey?
    public var primaryConnection: AccountConnectionReading
    public var connections: [AccountConnectionReading]
    public var snapshot: AccountSnapshot

    public init(
        identity: AccountIdentityKey?,
        primaryConnection: AccountConnectionReading,
        connections: [AccountConnectionReading],
        snapshot: AccountSnapshot
    ) {
        self.identity = identity
        self.primaryConnection = primaryConnection
        self.connections = connections
        self.snapshot = snapshot
    }
}

/// Reconciles active connections into logical account/workspace rows. Managed
/// connections are the presentation owner when both managed and provider-CLI
/// connections reach the same account; the underlying connections are retained
/// on the result for connection-specific settings and actions.
public func reconcileAccounts(_ readings: [AccountConnectionReading]) -> [ReconciledAccount] {
    enum GroupKey: Hashable {
        case account(AccountIdentityKey)
        case connection(String)
    }

    struct Group {
        var firstIndex: Int
        var readings: [AccountConnectionReading]
    }

    var groups: [GroupKey: Group] = [:]
    for (index, reading) in readings.enumerated() {
        let key =
            accountIdentity(for: reading.snapshot).map(GroupKey.account)
            ?? .connection(reading.profile.id)
        if groups[key] == nil {
            groups[key] = Group(firstIndex: index, readings: [])
        }
        groups[key]?.readings.append(reading)
    }

    var accounts = groups.map { key, group -> (primaryIndex: Int, account: ReconciledAccount) in
        let primary = group.readings.first(where: { $0.profile.isManaged }) ?? group.readings[0]
        let primaryIndex = readings.firstIndex(where: { $0.profile.id == primary.profile.id }) ?? group.firstIndex
        var snapshot = primary.snapshot
        snapshot.profileID = primary.profile.id
        snapshot.profileLabel =
            primary.profile.isManaged
            ? primary.profile.label
            : automaticAccountDisplayName(for: primary.snapshot)
        let identity: AccountIdentityKey?
        switch key {
        case .account(let value): identity = value
        case .connection: identity = nil
        }
        return (
            primaryIndex,
            ReconciledAccount(
                identity: identity,
                primaryConnection: primary,
                connections: group.readings,
                snapshot: snapshot
            )
        )
    }
    .sorted { $0.primaryIndex < $1.primaryIndex }
    .map(\.account)

    // Managed names are user-owned and remain unchanged. If a provider-CLI
    // account would present the same name, disambiguate that derived name at
    // presentation time instead of reserving it in persistent connection state.
    let managedNames = Set(
        accounts.compactMap { account -> String? in
            guard account.primaryConnection.profile.isManaged else { return nil }
            return normalizedDisplayName(account.snapshot.profileLabel, providerID: account.snapshot.provider.id)
        })
    var presentedNames = managedNames
    for index in accounts.indices where !accounts[index].primaryConnection.profile.isManaged {
        let providerID = accounts[index].snapshot.provider.id
        let base = accounts[index].snapshot.profileLabel
        var candidate = base
        var key = normalizedDisplayName(candidate, providerID: providerID)
        if presentedNames.contains(key),
            let workspace = accounts[index].snapshot.identity?.organization?.trimmingCharacters(in: .whitespacesAndNewlines),
            !workspace.isEmpty,
            candidate.caseInsensitiveCompare(workspace) != .orderedSame
        {
            candidate = "\(base) · \(workspace)"
            key = normalizedDisplayName(candidate, providerID: providerID)
        }
        var ordinal = 2
        while presentedNames.contains(key) {
            candidate = "\(base) (\(ordinal))"
            key = normalizedDisplayName(candidate, providerID: providerID)
            ordinal += 1
        }
        accounts[index].snapshot.profileLabel = candidate
        presentedNames.insert(key)
    }

    return accounts
}

private func automaticAccountDisplayName(for snapshot: AccountSnapshot) -> String {
    let candidates = [snapshot.identity?.email, snapshot.identity?.displayName, snapshot.identity?.organization]
    for candidate in candidates {
        if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
    }
    return "\(snapshot.provider.displayName) account"
}

private func normalizedDisplayName(_ value: String, providerID: String) -> String {
    [providerID, value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()].joined(separator: "|")
}
