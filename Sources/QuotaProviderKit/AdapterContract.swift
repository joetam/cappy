import Foundation
import QuotaContracts

public let adapterProtocolVersion = 1

public enum AdapterOperation: String, Codable, Sendable {
    case describe
    case refresh
    case prepareLogin
    case configure
    case removeManagedCredentials
}

public struct AdapterContext: Codable, Sendable {
    public var quotaCachePath: String?
    public var clientExecutablePath: String?

    public init(quotaCachePath: String? = nil, clientExecutablePath: String? = nil) {
        self.quotaCachePath = quotaCachePath
        self.clientExecutablePath = clientExecutablePath
    }
}

public struct AdapterRequest: Codable, Sendable {
    public var protocolVersion: Int
    public var operation: AdapterOperation
    public var profile: Profile?
    public var context: AdapterContext
    public var payload: JSONValue?

    public init(operation: AdapterOperation, profile: Profile? = nil, context: AdapterContext = .init(), payload: JSONValue? = nil) {
        self.protocolVersion = adapterProtocolVersion
        self.operation = operation
        self.profile = profile
        self.context = context
        self.payload = payload
    }
}

public struct LoginCommand: Codable, Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var requiresPTY: Bool

    public init(executable: String, arguments: [String], environment: [String: String], requiresPTY: Bool = true) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.requiresPTY = requiresPTY
    }
}

public struct AdapterResponse: Codable, Sendable {
    public var protocolVersion: Int
    public var ok: Bool
    public var provider: ProviderDescriptor?
    public var snapshot: AccountSnapshot?
    public var loginCommand: LoginCommand?
    public var message: String?
    public var warnings: [String]

    public init(
        ok: Bool, provider: ProviderDescriptor? = nil, snapshot: AccountSnapshot? = nil, loginCommand: LoginCommand? = nil,
        message: String? = nil, warnings: [String] = []
    ) {
        self.protocolVersion = adapterProtocolVersion
        self.ok = ok
        self.provider = provider
        self.snapshot = snapshot
        self.loginCommand = loginCommand
        self.message = message
        self.warnings = warnings
    }
}

public struct AdapterManifest: Codable, Sendable, Identifiable {
    public var id: String { providerID }
    public var protocolVersion: Int
    public var providerID: String
    public var displayName: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(providerID: String, displayName: String, executable: String, arguments: [String] = [], environment: [String: String] = [:])
    {
        self.protocolVersion = adapterProtocolVersion
        self.providerID = providerID
        self.displayName = displayName
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}
