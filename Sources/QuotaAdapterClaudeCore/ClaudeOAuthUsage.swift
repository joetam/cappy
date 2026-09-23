import CryptoKit
import Foundation
import QuotaBuiltins
import QuotaContracts
import QuotaProviderKit

package struct ClaudeUsageFetchResult: Sendable {
    package var account: ClaudeOAuthAccount
    package var value: JSONValue?
    package var observedAt: Date
}

package enum ClaudeUsageClientError: LocalizedError {
    case credentialsUnavailable
    case unauthorized
    case responseUnavailable
    case invalidResponse
    case credentialUpdateFailed

    package var errorDescription: String? {
        switch self {
        case .credentialsUnavailable:
            return "Claude OAuth credentials are unavailable."
        case .unauthorized:
            return "Claude OAuth authorization has expired."
        case .responseUnavailable, .invalidResponse:
            return "Claude usage is temporarily unavailable."
        case .credentialUpdateFailed:
            return "Claude credentials could not be refreshed safely."
        }
    }
}

package struct ClaudeOAuthUsageClient {
    private static let profileURL = endpoint("https://api.anthropic.com/api/oauth/profile")
    private static let usageURL = endpoint("https://api.anthropic.com/api/oauth/usage")
    private static let tokenURL = endpoint("https://platform.claude.com/v1/oauth/token")
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let oauthBeta = "oauth-2025-04-20"
    private static let earlyRefreshSeconds: TimeInterval = 120

    private let credentials: any ClaudeCredentialStoring
    private let http: any ClaudeHTTPPerforming

    package init(
        credentials: any ClaudeCredentialStoring,
        http: any ClaudeHTTPPerforming
    ) {
        self.credentials = credentials
        self.http = http
    }

    init() {
        self.init(credentials: ClaudeCredentialStore(), http: ClaudeHTTPClient())
    }

    package func fetch(profile: Profile) async throws -> ClaudeUsageFetchResult {
        var credential = try credentials.load(profile: profile)
        if credential.expiresAt.map({ $0.timeIntervalSinceNow <= Self.earlyRefreshSeconds }) == true {
            credential = try await refresh(credential, force: false)
        }

        // Identity and quota are one transaction over one credential. A refresh
        // or an external account switch invalidates both halves of the reading.
        for attempt in 0..<3 {
            do {
                let rawProfile = try await fetchJSON(url: Self.profileURL, accessToken: credential.accessToken)
                guard let account = ClaudeOAuthAccount(profile: rawProfile) else {
                    throw ClaudeUsageClientError.invalidResponse
                }
                var usage: JSONValue?
                do {
                    usage = try await fetchJSON(url: Self.usageURL, accessToken: credential.accessToken)
                } catch ClaudeUsageClientError.unauthorized {
                    throw ClaudeUsageClientError.unauthorized
                } catch {
                    // A verified identity may use only its own cached meters.
                    usage = nil
                }
                let current = try credentials.load(profile: profile)
                guard current.source == credential.source, current.accessToken == credential.accessToken else {
                    credential = current
                    continue
                }
                return ClaudeUsageFetchResult(account: account, value: usage, observedAt: Date())
            } catch ClaudeUsageClientError.unauthorized {
                guard attempt < 2 else { throw ClaudeUsageClientError.unauthorized }
                credential = try await refresh(credential, force: true)
            }
        }
        throw ClaudeUsageClientError.responseUnavailable
    }

    static func removeManagedCredentials(profile: Profile) throws {
        try ClaudeCredentialStore().removeManagedCredentials(profile: profile)
    }

    private static func endpoint(_ value: String) -> URL {
        guard let url = URL(string: value) else { preconditionFailure("Invalid built-in Claude endpoint") }
        return url
    }

    private func fetchJSON(url: URL, accessToken: String) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Cappy/\(quotaReleaseVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await http.perform(request)
        if response.statusCode == 401 { throw ClaudeUsageClientError.unauthorized }
        guard response.statusCode == 200 else { throw ClaudeUsageClientError.responseUnavailable }
        guard let value = try? JSONDecoder.quota.decode(JSONValue.self, from: data), value.objectValue != nil else {
            throw ClaudeUsageClientError.invalidResponse
        }
        return value
    }

    private func refresh(_ previous: ClaudeCredential, force: Bool) async throws -> ClaudeCredential {
        // Re-read immediately before rotating. If Claude Code refreshed in the
        // meantime, adopt its token instead of racing the provider-owned store.
        let current = try credentials.reload(previous.source)
        if current.accessToken != previous.accessToken,
            current.expiresAt.map({ $0.timeIntervalSinceNow > 30 }) != false
        {
            return current
        }
        if !force, current.expiresAt.map({ $0.timeIntervalSinceNow > Self.earlyRefreshSeconds }) == true {
            return current
        }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw ClaudeUsageClientError.unauthorized
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("Cappy/\(quotaReleaseVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientID,
        ])

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.perform(request)
        } catch {
            throw ClaudeUsageClientError.responseUnavailable
        }
        guard response.statusCode == 200 else {
            // A sibling Claude process may have won a refresh-token rotation.
            // Adopt it if it reached storage before this request completed.
            if let sibling = try? credentials.reload(current.source), sibling.accessToken != current.accessToken {
                return sibling
            }
            throw response.statusCode == 401 ? ClaudeUsageClientError.unauthorized : ClaudeUsageClientError.responseUnavailable
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = object["access_token"] as? String,
            !accessToken.isEmpty,
            let expiresIn = Self.number(object["expires_in"]),
            expiresIn > 0
        else {
            throw ClaudeUsageClientError.invalidResponse
        }
        let rotatedRefreshToken = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        let refreshExpiresIn = Self.number(object["refresh_token_expires_in"])
        let now = Date()
        let updated = ClaudeCredentialUpdate(
            accessToken: accessToken,
            refreshToken: rotatedRefreshToken,
            expiresAt: now.addingTimeInterval(expiresIn),
            refreshTokenExpiresAt: refreshExpiresIn.map { now.addingTimeInterval($0) }
        )

        guard try credentials.persist(updated, replacing: current) else {
            // Another process wrote a newer credential while this request was
            // in flight. Its value is authoritative.
            let sibling = try credentials.reload(current.source)
            guard sibling.accessToken != current.accessToken else {
                throw ClaudeUsageClientError.credentialUpdateFailed
            }
            return sibling
        }
        return try credentials.reload(current.source)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue.isFinite ? value.doubleValue : nil }
        if let value = value as? String, let number = Double(value), number.isFinite { return number }
        return nil
    }
}

package protocol ClaudeHTTPPerforming {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class ClaudeHTTPClient: NSObject, ClaudeHTTPPerforming, URLSessionTaskDelegate, @unchecked Sendable {
    private static let maximumResponseBytes = 1_048_576
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.maximumResponseBytes, let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeUsageClientError.invalidResponse
        }
        return (data, httpResponse)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

package struct ClaudeCredential: Sendable {
    package var accessToken: String
    package var refreshToken: String?
    package var expiresAt: Date?
    package var source: ClaudeCredentialSource

    package init(accessToken: String, refreshToken: String?, expiresAt: Date?, source: ClaudeCredentialSource) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.source = source
    }
}

package struct ClaudeCredentialUpdate: Sendable {
    package var accessToken: String
    package var refreshToken: String
    package var expiresAt: Date
    package var refreshTokenExpiresAt: Date?
}

package enum ClaudeCredentialSource: Sendable, Equatable {
    case keychain(service: String, account: String?)
    case file(path: String)
}

package protocol ClaudeCredentialStoring {
    func load(profile: Profile) throws -> ClaudeCredential
    func reload(_ source: ClaudeCredentialSource) throws -> ClaudeCredential
    func persist(_ update: ClaudeCredentialUpdate, replacing previous: ClaudeCredential) throws -> Bool
}

struct ClaudeCredentialStore: ClaudeCredentialStoring {
    private static let maximumCredentialBytes = 1_048_576
    private static let maximumKeychainCredentialBytes = 64 * 1_024

    func load(profile: Profile) throws -> ClaudeCredential {
        let service = keychainService(profile: profile)
        var keychainFailure: Error?
        do {
            if let credential = try loadKeychain(service: service) { return credential }
        } catch {
            keychainFailure = error
        }
        let path = URL(fileURLWithPath: profile.configPath, isDirectory: true)
            .appendingPathComponent(".credentials.json", isDirectory: false).path
        if let credential = try loadFile(path: path) { return credential }
        if let keychainFailure { throw keychainFailure }
        throw ClaudeUsageClientError.credentialsUnavailable
    }

    func removeManagedCredentials(profile: Profile) throws {
        guard profile.isManaged, !profile.isDefault else { return }
        let service = keychainService(profile: profile)
        let account = keychainAccount()
        var arguments = ["delete-generic-password"]
        if let account { arguments += ["-a", account] }
        arguments += ["-s", service]
        let result = try ProcessRunner.run(
            "/usr/bin/security",
            arguments: arguments,
            timeout: 3,
            maxOutputBytes: 16_384
        )
        guard result.status == 0 || result.status == 44 else {
            throw ClaudeUsageClientError.credentialUpdateFailed
        }
    }

    func reload(_ source: ClaudeCredentialSource) throws -> ClaudeCredential {
        switch source {
        case .keychain(let service, _):
            guard let credential = try loadKeychain(service: service) else {
                throw ClaudeUsageClientError.credentialsUnavailable
            }
            return credential
        case .file(let path):
            guard let credential = try loadFile(path: path) else {
                throw ClaudeUsageClientError.credentialsUnavailable
            }
            return credential
        }
    }

    func persist(_ update: ClaudeCredentialUpdate, replacing previous: ClaudeCredential) throws -> Bool {
        let document = try credentialDocument(source: previous.source)
        guard document.accessToken == previous.accessToken, document.refreshToken == previous.refreshToken else {
            return false
        }
        var root = document.root
        if var oauth = root["claudeAiOauth"] as? [String: Any] {
            oauth["accessToken"] = update.accessToken
            oauth["refreshToken"] = update.refreshToken
            oauth["expiresAt"] = update.expiresAt.timeIntervalSince1970 * 1_000
            if let refreshExpiry = update.refreshTokenExpiresAt {
                oauth["refreshTokenExpiresAt"] = refreshExpiry.timeIntervalSince1970 * 1_000
            }
            root["claudeAiOauth"] = oauth
        } else {
            root["access_token"] = update.accessToken
            root["refresh_token"] = update.refreshToken
            root["expires_at"] = update.expiresAt.timeIntervalSince1970
            if let refreshExpiry = update.refreshTokenExpiresAt {
                root["refresh_token_expires_at"] = refreshExpiry.timeIntervalSince1970
            }
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard data.count <= Self.maximumCredentialBytes else { throw ClaudeUsageClientError.credentialUpdateFailed }
        try write(data, to: previous.source)
        return true
    }

    private func keychainService(profile: Profile) -> String {
        guard !profile.isDefault else { return "Claude Code-credentials" }
        let normalizedPath = profile.configPath.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalizedPath.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(suffix)"
    }

    private func loadKeychain(service: String) throws -> ClaudeCredential? {
        let account = keychainAccount()
        guard let data = try keychainData(service: service, account: account) else { return nil }
        return try decode(data, source: .keychain(service: service, account: account))
    }

    private func loadFile(path: String) throws -> ClaudeCredential? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maximumCredentialBytes
        else {
            throw ClaudeUsageClientError.credentialsUnavailable
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        return try decode(data, source: .file(path: path))
    }

    private func decode(_ data: Data, source: ClaudeCredentialSource) throws -> ClaudeCredential {
        let document = try decodeDocument(data)
        return ClaudeCredential(
            accessToken: document.accessToken,
            refreshToken: document.refreshToken,
            expiresAt: document.expiresAt,
            source: source
        )
    }

    private func credentialDocument(source: ClaudeCredentialSource) throws -> ClaudeCredentialDocument {
        let data: Data
        switch source {
        case .keychain(let service, let account):
            guard let value = try keychainData(service: service, account: account) else {
                throw ClaudeUsageClientError.credentialsUnavailable
            }
            data = value
        case .file(let path):
            guard let value = FileManager.default.contents(atPath: path), value.count <= Self.maximumCredentialBytes else {
                throw ClaudeUsageClientError.credentialsUnavailable
            }
            data = value
        }
        return try decodeDocument(data)
    }

    private func decodeDocument(_ data: Data) throws -> ClaudeCredentialDocument {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageClientError.credentialsUnavailable
        }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        let accessKey = root["claudeAiOauth"] == nil ? "access_token" : "accessToken"
        let refreshKey = root["claudeAiOauth"] == nil ? "refresh_token" : "refreshToken"
        let expiryKey = root["claudeAiOauth"] == nil ? "expires_at" : "expiresAt"
        guard let accessToken = oauth[accessKey] as? String, !accessToken.isEmpty else {
            throw ClaudeUsageClientError.credentialsUnavailable
        }
        let refreshToken = (oauth[refreshKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expiresAt = Self.date(oauth[expiryKey])
        return ClaudeCredentialDocument(
            root: root,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }

    private func write(_ data: Data, to source: ClaudeCredentialSource) throws {
        switch source {
        case .keychain(let service, let account):
            guard let account, data.count <= Self.maximumKeychainCredentialBytes else {
                throw ClaudeUsageClientError.credentialUpdateFailed
            }
            // Claude Code grants its credential item to Apple's `security`
            // helper and uses hexadecimal data mode for non-interactive writes.
            // Interactive `-w` input is capped at 128 bytes and corrupts the
            // JSON document, while `-X` preserves the complete value.
            let result = try ProcessRunner.run(
                "/usr/bin/security",
                arguments: ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex(data)],
                timeout: 3,
                maxOutputBytes: 16_384
            )
            guard result.status == 0 else { throw ClaudeUsageClientError.credentialUpdateFailed }
        case .file(let path):
            let url = URL(fileURLWithPath: path)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ClaudeUsageClientError.credentialUpdateFailed
            }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    private static func date(_ value: Any?) -> Date? {
        let number: Double?
        if let value = value as? NSNumber {
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value)
        } else {
            number = nil
        }
        guard var seconds = number, seconds.isFinite else { return nil }
        if seconds > 100_000_000_000 { seconds /= 1_000 }
        return Date(timeIntervalSince1970: seconds)
    }

    private func keychainData(service: String, account: String?) throws -> Data? {
        var arguments = ["find-generic-password"]
        if let account { arguments += ["-a", account] }
        arguments += ["-w", "-s", service]
        let result = try ProcessRunner.run(
            "/usr/bin/security",
            arguments: arguments,
            timeout: 3,
            maxOutputBytes: Self.maximumCredentialBytes
        )
        if result.status == 44 { return nil }
        guard result.status == 0, !result.stdout.isEmpty, result.stdout.count <= Self.maximumCredentialBytes else {
            throw ClaudeUsageClientError.credentialsUnavailable
        }
        return result.stdout
    }

    private func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded = [UInt8]()
        encoded.reserveCapacity(data.count * 2)
        for byte in data {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private func keychainAccount() -> String? {
        let candidate = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        guard candidate.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        return candidate
    }
}

private struct ClaudeCredentialDocument {
    var root: [String: Any]
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}
