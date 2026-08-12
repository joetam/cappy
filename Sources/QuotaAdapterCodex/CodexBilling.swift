import Foundation
import QuotaContracts

/// Best-effort access to the ChatGPT entitlement that backs a Codex login.
/// This endpoint is not part of the public OpenAI API, so failures must never
/// prevent the supported app-server quota data from being returned.
struct CodexBillingClient {
    private static let maximumCredentialBytes = 1_048_576
    private static let maximumResponseBytes = 1_048_576
    private static let endpoint: URL = {
        guard let url = URL(string: "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27") else {
            preconditionFailure("Invalid built-in Codex billing endpoint")
        }
        return url
    }()

    func fetch(profile: Profile) -> JSONValue? {
        guard let credential = loadCredential(profile: profile) else { return nil }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Cappy/\(quotaReleaseVersion)", forHTTPHeaderField: "User-Agent")

        let http = CodexBillingHTTPClient()
        guard let data = http.perform(request), data.count <= Self.maximumResponseBytes,
            let value = try? JSONDecoder.quota.decode(JSONValue.self, from: data)
        else { return nil }
        return value["accounts"]?[credential.accountID]
    }

    private func loadCredential(profile: Profile) -> (accessToken: String, accountID: String)? {
        let url = URL(fileURLWithPath: profile.configPath, isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maximumCredentialBytes,
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
            data.count <= Self.maximumCredentialBytes,
            let value = try? JSONDecoder.quota.decode(JSONValue.self, from: data),
            let accessToken = value["tokens"]?["access_token"]?.stringValue,
            !accessToken.isEmpty,
            let accountID = value["tokens"]?["account_id"]?.stringValue,
            !accountID.isEmpty
        else { return nil }
        return (accessToken, accountID)
    }
}

private final class CodexBillingHTTPClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

    func perform(_ request: URLRequest) -> Data? {
        let response = CodexBillingResponseBox()
        let task = session.dataTask(with: request) { data, urlResponse, _ in
            response.complete(data: data, response: urlResponse)
        }
        task.resume()
        defer { session.invalidateAndCancel() }
        guard let result = response.wait(timeout: 10), result.response.statusCode == 200 else { return nil }
        return result.data
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

private final class CodexBillingResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: (data: Data, response: HTTPURLResponse)?

    func complete(data: Data?, response: URLResponse?) {
        lock.lock()
        if let data, let response = response as? HTTPURLResponse {
            result = (data, response)
        }
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> (data: Data, response: HTTPURLResponse)? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
