import CryptoKit
import Foundation
import QuotaBuiltins
import QuotaContracts
import QuotaProviderKit
import QuotaAdapterClaudeCore

private let profile = Profile(
    id: "claude-test", providerID: "anthropic-claude", label: "Test", configPath: "/unused", isManaged: true)

private func accountPayload(_ name: String, organization: String? = nil) -> String {
    """
    {"account":{"uuid":"account-\(name)","email":"\(name)@example.com"},
     "organization":{"uuid":"\(organization ?? "org-" + name)","name":"\(name)'s Organization","organization_type":"claude_max"}}
    """
}

private let usage = #"{"five_hour":{"utilization":42}}"#

private func credential(_ name: String) -> ClaudeCredential {
    ClaudeCredential(accessToken: name, refreshToken: "refresh-\(name)", expiresAt: .distantFuture, source: .file(path: "/unused"))
}

private final class CredentialStore: ClaudeCredentialStoring {
    var current = credential("alice")
    var available = true
    var rotations = 0

    func load(profile: Profile) throws -> ClaudeCredential {
        guard available else { throw ClaudeUsageClientError.credentialsUnavailable }
        return current
    }

    func reload(_ source: ClaudeCredentialSource) throws -> ClaudeCredential { try load(profile: profile) }

    func persist(_ update: ClaudeCredentialUpdate, replacing previous: ClaudeCredential) throws -> Bool {
        guard current.accessToken == previous.accessToken else { return false }
        rotations += 1
        current.accessToken = update.accessToken
        current.refreshToken = update.refreshToken
        current.expiresAt = update.expiresAt
        return true
    }
}

private final class HTTP: ClaudeHTTPPerforming {
    var requests: [URLRequest] = []
    var respond: (URLRequest) throws -> (Int, String)

    init(_ respond: @escaping (URLRequest) throws -> (Int, String)) { self.respond = respond }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = try respond(request)
        let url = try unwrap(request.url)
        let response = try unwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}

struct ClaudeIdentityTests {
    func testVerifiedIdentityReplacesStaleMetadataAndCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Reproduce a CLI directory with metadata for an entirely different account.
        try Data(#"{"oauthAccount":{"emailAddress":"bob@example.com","organizationName":"bob's Organization"}}"#.utf8)
            .write(to: directory.appendingPathComponent(".claude.json"))
        var isolated = profile
        isolated.configPath = directory.path
        let context = AdapterContext(quotaCachePath: directory.appendingPathComponent("cache.json").path)
        let store = CredentialStore()
        let http = HTTP { request in
            (200, request.url?.path.hasSuffix("profile") == true ? accountPayload("alice") : usage)
        }
        let client = ClaudeOAuthUsageClient(credentials: store, http: http)
        let first = try await refresh(profile: isolated, context: context, client: client)
        expectEqual(first.identity?.email, "alice@example.com")
        expectEqual(first.identity?.organization, "alice's Organization")
        expectEqual(first.meters.first?.used, 42)

        // Once the credential changes, a usage outage must not carry Alice's
        // meters into Bob's verified snapshot.
        store.current = credential("bob")
        http.respond = { request in
            request.url?.path.hasSuffix("profile") == true ? (200, accountPayload("bob")) : (503, "{}")
        }
        let switched = try await refresh(profile: isolated, context: context, client: client)
        expectEqual(switched.identity?.email, "bob@example.com")
        expectTrue(switched.meters.isEmpty)
        expectEqual(switched.freshness, .unavailable)

        store.current = credential("alice")
        http.respond = { request in
            request.url?.path.hasSuffix("profile") == true ? (200, accountPayload("alice")) : (503, "{}")
        }
        let cached = try await refresh(profile: isolated, context: context, client: client)
        expectEqual(cached.meters.first?.used, 42)
        expectEqual(cached.freshness, .stale)
        expectEqual(cached.meters.first?.status, .stale)
    }

    func testLegacyCacheCannotBePromotedToVerifiedReading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cache.json")
        let legacyBinding = SHA256.hash(data: Data("org-alice|alice@example.com".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let meters = ClaudeNormalizer.meters(fromOAuthUsage: try JSONDecoder.quota.decode(JSONValue.self, from: Data(usage.utf8)))
        let cache = MeterCache(profileID: profile.id, accountBinding: legacyBinding, meters: meters, observedAt: Date())
        try JSONEncoder.quota.encode(cache).write(to: path)
        let http = HTTP { request in
            request.url?.path.hasSuffix("profile") == true ? (200, accountPayload("alice")) : (503, "{}")
        }
        let snapshot = try await refresh(
            profile: profile, context: .init(quotaCachePath: path.path), client: .init(credentials: CredentialStore(), http: http))
        expectEqual(snapshot.identity?.email, "alice@example.com")
        expectTrue(snapshot.meters.isEmpty)
    }

    func testRepeatedSwitchesAreBoundedAndExpiredCredentialsClearIdentity() async throws {
        let store = CredentialStore()
        let http = HTTP { request in
            let alice = store.current.accessToken == "alice"
            if request.url?.path.hasSuffix("profile") == true { return (200, accountPayload(alice ? "alice" : "bob")) }
            store.current = credential(alice ? "bob" : "alice")
            return (200, usage)
        }
        do {
            _ = try await ClaudeOAuthUsageClient(credentials: store, http: http).fetch(profile: profile)
            fail("Never publish a reading while the credential keeps changing")
        } catch ClaudeUsageClientError.responseUnavailable {
            expectEqual(http.requests.count, 6)
        }
        store.current.refreshToken = nil
        http.respond = { _ in (401, "{}") }
        let snapshot = try await refresh(profile: profile, context: .init(), client: .init(credentials: store, http: http))
        expectEqual(snapshot.authenticationState, .expired)
        expectNil(snapshot.identity)
        expectTrue(snapshot.meters.isEmpty)
    }

    func testSwitchDuringUsageRetriesEntireReading() async throws {
        let store = CredentialStore()
        let http = HTTP { request in
            let alice = request.value(forHTTPHeaderField: "Authorization") == "Bearer alice"
            if request.url?.path.hasSuffix("profile") == true { return (200, accountPayload(alice ? "alice" : "bob")) }
            if alice { store.current = credential("bob") }
            return (200, alice ? usage : #"{"five_hour":{"utilization":7}}"#)
        }
        let snapshot = try await refresh(profile: profile, context: .init(), client: .init(credentials: store, http: http))
        expectEqual(snapshot.identity?.email, "bob@example.com")
        expectEqual(snapshot.meters.first?.used, 7)
        expectEqual(
            http.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer alice", "Bearer alice", "Bearer bob", "Bearer bob"])
    }

    func testUnauthorizedUsageReverifiesIdentityAfterRotation() async throws {
        let store = CredentialStore()
        let http = HTTP { request in
            if request.url?.path.hasSuffix("token") == true {
                return (200, #"{"access_token":"bob","refresh_token":"refresh-bob","expires_in":3600}"#)
            }
            let alice = request.value(forHTTPHeaderField: "Authorization") == "Bearer alice"
            if request.url?.path.hasSuffix("profile") == true { return (200, accountPayload(alice ? "alice" : "bob")) }
            return alice ? (401, "{}") : (200, usage)
        }
        let result = try await ClaudeOAuthUsageClient(credentials: store, http: http).fetch(profile: profile)
        expectEqual(result.account.email, "bob@example.com")
        expectEqual(store.rotations, 1)
        expectEqual(http.requests.filter { $0.url?.path.hasSuffix("profile") == true }.count, 2)
    }

    func testUnverifiableIdentityFailsBeforeUsage() async throws {
        for payload in ["{}", #"{"account":{"email":"alice@example.com"},"organization":{"uuid":"org"}}"#] {
            let http = HTTP { _ in (200, payload) }
            do {
                _ = try await ClaudeOAuthUsageClient(credentials: CredentialStore(), http: http).fetch(profile: profile)
                fail("An unverified identity must fail closed")
            } catch ClaudeUsageClientError.invalidResponse {
                expectEqual(http.requests.count, 1)
            }
        }
        let http = HTTP { _ in (503, "{}") }
        do {
            _ = try await refresh(profile: profile, context: .init(), client: .init(credentials: CredentialStore(), http: http))
            fail("A profile outage must not use CLI metadata or fetch usage")
        } catch ClaudeUsageClientError.responseUnavailable {
            expectEqual(http.requests.count, 1)
        }
    }

    func testMissingCredentialClearsIdentityAndMeters() async throws {
        let store = CredentialStore()
        store.available = false
        let http = HTTP { _ in
            fail("No request without a credential"); return (200, "{}")
        }
        let snapshot = try await refresh(profile: profile, context: .init(), client: .init(credentials: store, http: http))
        expectEqual(snapshot.authenticationState, .unauthenticated)
        expectNil(snapshot.identity)
        expectTrue(snapshot.meters.isEmpty)
    }

    func testCacheBindingIncludesAccountAndWorkspaceButNotNames() throws {
        func account(_ payload: String) throws -> ClaudeOAuthAccount {
            try unwrap(ClaudeOAuthAccount(profile: JSONDecoder.quota.decode(JSONValue.self, from: Data(payload.utf8))))
        }
        let original = try account(accountPayload("alice"))
        let renamed = try account(accountPayload("alice").replacingOccurrences(of: "alice@example.com", with: "renamed@example.com"))
        let otherWorkspace = try account(accountPayload("alice", organization: "another-workspace"))
        let otherMember = try account(accountPayload("bob", organization: "org-alice"))
        expectEqual(cacheBinding(account: original), cacheBinding(account: renamed))
        expectNotEqual(cacheBinding(account: original), cacheBinding(account: otherWorkspace))
        expectNotEqual(cacheBinding(account: original), cacheBinding(account: otherMember))
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    guard actual == expected else { fatalError("Expected \(expected), got \(actual)", file: file, line: line) }
}

private func expectNotEqual<T: Equatable>(_ actual: T, _ other: T, file: StaticString = #file, line: UInt = #line) {
    guard actual != other else { fatalError("Unexpected equality", file: file, line: line) }
}

private func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    guard value else { fatalError("Expected true", file: file, line: line) }
}

private func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    guard value == nil else { fatalError("Expected nil", file: file, line: line) }
}

private func fail(_ message: String, file: StaticString = #file, line: UInt = #line) {
    fatalError(message, file: file, line: line)
}

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw ClaudeUsageClientError.invalidResponse }
    return value
}

@main
private struct ClaudeAdapterSelfTest {
    static func main() async throws {
        let tests = ClaudeIdentityTests()
        try await tests.testVerifiedIdentityReplacesStaleMetadataAndCache()
        try await tests.testSwitchDuringUsageRetriesEntireReading()
        try await tests.testUnauthorizedUsageReverifiesIdentityAfterRotation()
        try await tests.testUnverifiableIdentityFailsBeforeUsage()
        try await tests.testMissingCredentialClearsIdentityAndMeters()
        try await tests.testLegacyCacheCannotBePromotedToVerifiedReading()
        try await tests.testRepeatedSwitchesAreBoundedAndExpiredCredentialsClearIdentity()
        try tests.testCacheBindingIncludesAccountAndWorkspaceButNotNames()
        print("claude-identity: all checks passed")
    }
}
