public struct RememberedCLIAccount: Codable, Equatable, Sendable {
    public let identityKey: String
    public let displayIdentity: String
    public let wasKept: Bool

    public init(identityKey: String, displayIdentity: String, wasKept: Bool) {
        self.identityKey = identityKey
        self.displayIdentity = displayIdentity
        self.wasKept = wasKept
    }
}

public enum CLIAccountRecognition: Equatable, Sendable {
    case firstDiscovery
    case unchanged
    case changed(from: RememberedCLIAccount)
}

public func recognizeCLIAccount(
    currentIdentityKey: String,
    remembered: RememberedCLIAccount?
) -> CLIAccountRecognition {
    guard let remembered else { return .firstDiscovery }
    return remembered.identityKey == currentIdentityKey ? .unchanged : .changed(from: remembered)
}
