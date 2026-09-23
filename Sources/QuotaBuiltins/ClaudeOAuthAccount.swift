import Foundation
import QuotaContracts

/// Identity verified by the OAuth profile endpoint using the quota credential.
/// CLI configuration metadata is deliberately not an input to this type.
public struct ClaudeOAuthAccount: Sendable {
    public let accountID: String
    public let email: String
    public let organizationID: String
    public let organizationName: String?
    public let displayName: String?
    public let planName: String?

    public init?(profile: JSONValue) {
        func text(_ value: JSONValue?) -> String? {
            guard let value = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        guard let accountID = text(profile["account"]?["uuid"]),
            let email = text(profile["account"]?["email"]),
            let organizationID = text(profile["organization"]?["uuid"])
        else { return nil }
        self.accountID = accountID
        self.email = email
        self.organizationID = organizationID
        organizationName = text(profile["organization"]?["name"])
        displayName = text(profile["account"]?["display_name"])
        let organizationType = text(profile["organization"]?["organization_type"])
        planName = organizationType.map { $0.hasPrefix("claude_") ? String($0.dropFirst(7)) : $0 }
    }
}
