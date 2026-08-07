import Foundation

public let quotaContractVersion = 1
/// Bump when clients must replace an already-running app-server after an update.
public let quotaAppServerAPIVersion = 5
public let quotaReleaseVersion = "0.1.1"

public enum AuthenticationState: String, Codable, Sendable {
    case authenticated
    case unauthenticated
    case authenticating
    case expired
    case unknown
}

public enum MeterKind: String, Codable, Sendable {
    case rollingWindow
    case balance
    case spend
    case count
    case unknown
}

public enum MeterUnit: String, Codable, Sendable {
    case percent
    case credits
    case usd
    case tokens
    case requests
    case count
    case unknown
}

public enum MeterStatus: String, Codable, Sendable {
    case available
    case warning
    case exhausted
    case unlimited
    case unavailable
    case stale
}

public enum SnapshotFreshness: String, Codable, Sendable {
    case fresh
    case stale
    case pending
    case unavailable
}

/// Optional visual identity supplied by a provider adapter. Clients should try
/// these sources in order and fall back to `ProviderDescriptor.symbolName`.
/// No source permits an adapter to provide an arbitrary filesystem path.
public struct ProviderIconDescriptor: Codable, Sendable, Equatable {
    /// An image resource shipped by the client application.
    public var bundledAssetName: String?
    /// A locally installed macOS application whose icon represents the provider.
    public var applicationBundleIdentifier: String?
    /// A named image inside that application. The application icon is used if it is absent or unavailable.
    public var applicationResourceName: String?
    public var applicationResourceExtension: String?
    /// `template` lets the client render a monochrome mark using its current foreground color.
    public var renderingMode: String?
    /// Optional background for monochrome bundled marks.
    public var backgroundHex: String?

    public init(
        bundledAssetName: String? = nil,
        applicationBundleIdentifier: String? = nil,
        applicationResourceName: String? = nil,
        applicationResourceExtension: String? = nil,
        renderingMode: String? = nil,
        backgroundHex: String? = nil
    ) {
        self.bundledAssetName = bundledAssetName
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationResourceName = applicationResourceName
        self.applicationResourceExtension = applicationResourceExtension
        self.renderingMode = renderingMode
        self.backgroundHex = backgroundHex
    }
}

public struct ProviderDescriptor: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var displayName: String
    public var symbolName: String?
    public var accentHex: String?
    public var icon: ProviderIconDescriptor?

    public init(
        id: String,
        displayName: String,
        symbolName: String? = nil,
        accentHex: String? = nil,
        icon: ProviderIconDescriptor? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.symbolName = symbolName
        self.accentHex = accentHex
        self.icon = icon
    }
}

public struct Profile: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var providerID: String
    public var label: String
    public var configPath: String
    public var isManaged: Bool
    public var isDefault: Bool
    public var createdAt: Date

    public init(
        id: String, providerID: String, label: String, configPath: String, isManaged: Bool, isDefault: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.configPath = configPath
        self.isManaged = isManaged
        self.isDefault = isDefault
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, providerID, label, configPath, isManaged, isDefault, createdAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        providerID = try values.decode(String.self, forKey: .providerID)
        label = try values.decode(String.self, forKey: .label)
        configPath = try values.decode(String.self, forKey: .configPath)
        isManaged = try values.decode(Bool.self, forKey: .isManaged)
        isDefault = try values.decodeIfPresent(Bool.self, forKey: .isDefault) ?? id.hasSuffix("-default")
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}

/// Public profile metadata returned to clients. Provider configuration paths are
/// intentionally kept inside the app-server/adapter trust boundary.
public struct ProfileSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var providerID: String
    public var label: String
    public var isManaged: Bool
    public var isDefault: Bool
    public var createdAt: Date

    public init(_ profile: Profile) {
        id = profile.id
        providerID = profile.providerID
        label = profile.label
        isManaged = profile.isManaged
        isDefault = profile.isDefault
        createdAt = profile.createdAt
    }
}

public struct ProfileRemovalResult: Codable, Sendable, Equatable {
    public var profile: ProfileSummary
    public var managedCredentialsRemoved: Bool?
    public var warning: String?

    public init(profile: ProfileSummary, managedCredentialsRemoved: Bool? = nil, warning: String? = nil) {
        self.profile = profile
        self.managedCredentialsRemoved = managedCredentialsRemoved
        self.warning = warning
    }
}

public struct LoginJob: Codable, Sendable, Identifiable, Equatable {
    public enum State: String, Codable, Sendable {
        case running
        case verifying
        case succeeded
        case failed
        case cancelled
    }

    public var id: String
    public var profileID: String
    public var state: State
    public var startedAt: Date
    public var message: String?

    public init(id: String, profileID: String, state: State, startedAt: Date = Date(), message: String? = nil) {
        self.id = id
        self.profileID = profileID
        self.state = state
        self.startedAt = startedAt
        self.message = message
    }
}

public struct AccountIdentity: Codable, Sendable, Equatable {
    public var displayName: String?
    public var email: String?
    public var organization: String?
    public var stableID: String?

    public init(displayName: String? = nil, email: String? = nil, organization: String? = nil, stableID: String? = nil) {
        self.displayName = displayName
        self.email = email
        self.organization = organization
        self.stableID = stableID
    }
}

public struct Subscription: Codable, Sendable, Equatable {
    public var planName: String?
    public var billingMode: String?
    public var seatTier: String?

    public init(planName: String? = nil, billingMode: String? = nil, seatTier: String? = nil) {
        self.planName = planName
        self.billingMode = billingMode
        self.seatTier = seatTier
    }
}

public struct MeterScope: Codable, Sendable, Equatable {
    public var kind: String
    public var id: String
    public var displayName: String?

    public init(kind: String, id: String, displayName: String? = nil) {
        self.kind = kind
        self.id = id
        self.displayName = displayName
    }
}

public struct QuotaMeter: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var displayName: String
    public var kind: MeterKind
    public var unit: MeterUnit
    public var scope: MeterScope
    public var used: Double?
    public var limit: Double?
    public var remaining: Double?
    public var usedFraction: Double?
    public var resetsAt: Date?
    public var windowSeconds: Int?
    public var status: MeterStatus
    public var priority: Int
    public var source: String
    public var details: [String: String]?

    public init(
        id: String,
        displayName: String,
        kind: MeterKind,
        unit: MeterUnit,
        scope: MeterScope,
        used: Double? = nil,
        limit: Double? = nil,
        remaining: Double? = nil,
        usedFraction: Double? = nil,
        resetsAt: Date? = nil,
        windowSeconds: Int? = nil,
        status: MeterStatus = .available,
        priority: Int = 100,
        source: String,
        details: [String: String]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.unit = unit
        self.scope = scope
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.usedFraction = usedFraction.map { min(max($0, 0), 1) }
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
        self.status = status
        self.priority = priority
        self.source = source
        self.details = details
    }
}

public struct AccountSnapshot: Codable, Sendable, Identifiable, Equatable {
    public var id: String { profileID }
    public var contractVersion: Int
    public var profileID: String
    public var provider: ProviderDescriptor
    public var profileLabel: String
    public var authenticationState: AuthenticationState
    public var authenticationMethod: String?
    public var identity: AccountIdentity?
    public var subscription: Subscription?
    public var meters: [QuotaMeter]
    public var observedAt: Date
    public var freshness: SnapshotFreshness
    public var message: String?

    public init(
        profileID: String,
        provider: ProviderDescriptor,
        profileLabel: String,
        authenticationState: AuthenticationState,
        authenticationMethod: String? = nil,
        identity: AccountIdentity? = nil,
        subscription: Subscription? = nil,
        meters: [QuotaMeter] = [],
        observedAt: Date = Date(),
        freshness: SnapshotFreshness,
        message: String? = nil
    ) {
        self.contractVersion = quotaContractVersion
        self.profileID = profileID
        self.provider = provider
        self.profileLabel = profileLabel
        self.authenticationState = authenticationState
        self.authenticationMethod = authenticationMethod
        self.identity = identity
        self.subscription = subscription
        self.meters = meters.sorted { ($0.priority, $0.displayName) < ($1.priority, $1.displayName) }
        self.observedAt = observedAt
        self.freshness = freshness
        self.message = message
    }
}

public struct AppState: Codable, Sendable {
    public var contractVersion: Int = quotaContractVersion
    public var profiles: [Profile]
    public var snapshots: [String: AccountSnapshot]

    public init(profiles: [Profile] = [], snapshots: [String: AccountSnapshot] = [:]) {
        self.profiles = profiles
        self.snapshots = snapshots
    }
}

public struct MeterCache: Codable, Sendable, Equatable {
    public var contractVersion: Int
    public var profileID: String
    public var meters: [QuotaMeter]
    public var observedAt: Date

    public init(profileID: String, meters: [QuotaMeter], observedAt: Date = Date()) {
        self.contractVersion = quotaContractVersion
        self.profileID = profileID
        self.meters = meters
        self.observedAt = observedAt
    }
}
