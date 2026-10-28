import Darwin
import Foundation
import QuotaBuiltins
import QuotaContracts
import QuotaProviderKit

private final class CodexResponseCollector: @unchecked Sendable {
    private static let maxBufferedBytes = 1_048_576
    private let lock = NSLock()
    private var buffer = Data()
    private var results: [Int: JSONValue] = [:]
    private var errors: [Int: String] = [:]
    private var didOverflow = false
    let semaphore = DispatchSemaphore(value: 0)

    func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !didOverflow else { return }
        guard data.count <= Self.maxBufferedBytes - buffer.count else {
            didOverflow = true
            buffer.removeAll(keepingCapacity: false)
            semaphore.signal()
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let id = object["id"] as? Int
            else { continue }
            if let result = object["result"], let value = try? JSONValue.fromJSONObject(result) {
                results[id] = value
                semaphore.signal()
            } else if let error = object["error"] as? [String: Any] {
                errors[id] = error["message"] as? String ?? "Codex app-server error"
                semaphore.signal()
            }
        }
    }

    func result(_ id: Int) -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        return results[id]
    }

    func error(_ id: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return errors[id]
    }

    var overflowed: Bool {
        lock.lock(); defer { lock.unlock() }
        return didOverflow
    }

    func waitForResponse(id: Int, until deadline: Date) {
        while Date() < deadline && result(id) == nil && error(id) == nil && !overflowed {
            _ = semaphore.wait(timeout: .now() + 0.1)
        }
    }
}

private func codexError(code: Int, _ message: String) -> NSError {
    NSError(
        domain: "ai.upriver.cappy.Codex", code: code,
        userInfo: [NSLocalizedDescriptionKey: message])
}

private func isExpiredAuthenticationError(_ message: String) -> Bool {
    let normalized = message.lowercased()
    return normalized.contains("token_expired")
        || normalized.contains("authentication token is expired")
        || normalized.contains("401 unauthorized")
}

private func expiredSnapshot(profile: Profile, accountResult: JSONValue? = nil) -> AccountSnapshot {
    var snapshot =
        accountResult.map {
            CodexNormalizer.snapshot(
                profile: profile,
                accountResult: $0,
                rateLimitResult: .object([:])
            )
        }
        ?? AccountSnapshot(
            profileID: profile.id,
            provider: BuiltinProviders.codex,
            profileLabel: profile.label,
            authenticationState: .expired,
            freshness: .unavailable
        )
    snapshot.authenticationState = .expired
    snapshot.freshness = .unavailable
    snapshot.message = "Codex sign-in expired. Sign in again."
    return snapshot
}

private func writeMessage(_ message: [String: Any], to handle: FileHandle) throws {
    var data = try JSONSerialization.data(withJSONObject: message)
    data.append(0x0A)
    try handle.write(contentsOf: data)
}

private let quotaPrimerPrompt = """
    [CAPPY_QUOTA_PRIMER_NO_OP_V1]
    This is an automated quota-cycle primer. Do not inspect files, call tools, or perform any action.
    Reply with exactly: CAPPY_QUOTA_PRIMER_ACK_V1
    """

private func primeQuota(profile: Profile) throws -> QuotaPrimerReceipt {
    guard let codex = VendorExecutable.resolveCodex() else {
        throw ProcessRunnerError.executableNotFound("codex")
    }
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("cappy-primer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: workspace) }
    let result = try ProcessRunner.run(
        codex,
        arguments: [
            "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
            "--cd", workspace.path,
            "--disable", "shell_tool", "--disable", "hooks", "--disable", "multi_agent",
            "--disable", "apps", "--config", "tools.web_search=false",
            "--config", "tools.view_image=false",
            "--sandbox", "read-only", quotaPrimerPrompt,
        ],
        environment: profile.isDefault ? [:] : ["CODEX_HOME": profile.configPath],
        stdin: Data(),
        timeout: 120,
        maxOutputBytes: 64 * 1024
    )
    guard result.status == 0 else {
        throw codexError(code: Int(result.status), "Codex quota primer failed (exit \(result.status)).")
    }
    return try validatePrimerCompletion(result.stdout)
}

/// A successful process exit can occur without a model turn. Require the
/// acknowledgement and completion with token usage before accepting an attempt; the
/// client still verifies the provider's reset clock independently.
private func validatePrimerCompletion(_ output: Data) throws -> QuotaPrimerReceipt {
    var threadID: String?
    var started = false
    var acknowledged = false
    var receipt: QuotaPrimerReceipt?
    for line in output.split(separator: 0x0A) where !line.isEmpty {
        guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            let type = event["type"] as? String
        else { throw codexError(code: 3, "Codex quota primer returned invalid completion events.") }
        switch type {
        case "thread.started":
            threadID = event["thread_id"] as? String
        case "turn.started":
            guard !started else { throw codexError(code: 3, "Codex quota primer unexpectedly started another turn.") }
            started = true
        case "error", "turn.failed":
            throw codexError(code: 3, "Codex quota primer reported a failed model turn.")
        case "item.completed":
            guard let item = event["item"] as? [String: Any] else { continue }
            if item["type"] as? String == "agent_message" {
                acknowledged = item["text"] as? String == "CAPPY_QUOTA_PRIMER_ACK_V1"
            }
        case "turn.completed":
            let usage = event["usage"] as? [String: Any]
            guard started, acknowledged, let threadID,
                let inputTokens = usage?["input_tokens"] as? Int,
                let outputTokens = usage?["output_tokens"] as? Int
            else { throw codexError(code: 3, "Codex quota primer returned an incomplete model turn.") }
            receipt = QuotaPrimerReceipt(
                threadID: threadID, inputTokens: inputTokens, outputTokens: outputTokens, completedAt: Date()
            )
        default: continue
        }
    }
    guard let receipt, receipt.isValid else {
        throw codexError(code: 3, "Codex quota primer did not complete an acknowledged model turn with token usage.")
    }
    return receipt
}

private func refresh(profile: Profile) throws -> AccountSnapshot {
    guard
        let codex = VendorExecutable.resolveCodex()
    else {
        throw ProcessRunnerError.executableNotFound("codex")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: codex)
    process.arguments = ["app-server"]
    let profileEnvironment = profile.isDefault ? [:] : ["CODEX_HOME": profile.configPath]
    process.environment = ProcessEnvironment.sanitized(adding: profileEnvironment)
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    let collector = CodexResponseCollector()
    output.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty { collector.consume(data) }
    }
    try process.run()
    defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let exitDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        collector.consume(output.fileHandleForReading.readDataToEndOfFile())
    }

    // Codex app-server treats `initialized` and all account methods as
    // post-handshake traffic. Wait for its initialize response before sending
    // them, and keep stdin open until their responses arrive.
    let deadline = Date().addingTimeInterval(15)
    try writeMessage(
        [
            "method": "initialize", "id": 0,
            "params": ["clientInfo": ["name": "cappy", "title": "Cappy", "version": quotaReleaseVersion]],
        ],
        to: input.fileHandleForWriting)
    collector.waitForResponse(id: 0, until: deadline)

    guard !collector.overflowed else {
        throw codexError(code: 2, "Codex returned an oversized response")
    }
    guard collector.result(0) != nil else {
        throw codexError(
            code: 1,
            collector.error(0).map { "Codex initialization failed: \($0)" } ?? "Codex initialization timed out")
    }

    try writeMessage(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
    try writeMessage(
        ["method": "account/read", "id": 1, "params": ["refreshToken": false]],
        to: input.fileHandleForWriting)

    collector.waitForResponse(id: 1, until: deadline)
    guard !collector.overflowed else {
        throw codexError(code: 2, "Codex returned an oversized response")
    }
    guard let account = collector.result(1) else {
        if let message = collector.error(1), isExpiredAuthenticationError(message) {
            return expiredSnapshot(profile: profile)
        }
        throw codexError(
            code: 1,
            collector.error(1).map { "Codex account check failed: \($0)" } ?? "Codex account check timed out")
    }

    var resolvedAccount = account
    try writeMessage(
        ["method": "account/rateLimits/read", "id": 2, "params": [:]],
        to: input.fileHandleForWriting)
    collector.waitForResponse(id: 2, until: deadline)
    guard !collector.overflowed else {
        throw codexError(code: 2, "Codex returned an oversized response")
    }
    var resolvedLimits = collector.result(2)
    if resolvedLimits == nil,
        let message = collector.error(2),
        isExpiredAuthenticationError(message)
    {
        try writeMessage(
            ["method": "account/read", "id": 3, "params": ["refreshToken": true]],
            to: input.fileHandleForWriting)
        collector.waitForResponse(id: 3, until: deadline)
        guard !collector.overflowed else {
            throw codexError(code: 2, "Codex returned an oversized response")
        }
        guard let refreshedAccount = collector.result(3) else {
            if let refreshMessage = collector.error(3), isExpiredAuthenticationError(refreshMessage) {
                return expiredSnapshot(profile: profile, accountResult: account)
            }
            throw codexError(
                code: 1,
                collector.error(3).map { "Codex token refresh failed: \($0)" } ?? "Codex token refresh timed out")
        }
        resolvedAccount = refreshedAccount

        try writeMessage(
            ["method": "account/rateLimits/read", "id": 4, "params": [:]],
            to: input.fileHandleForWriting)
        collector.waitForResponse(id: 4, until: deadline)
        guard !collector.overflowed else {
            throw codexError(code: 2, "Codex returned an oversized response")
        }
        resolvedLimits = collector.result(4)
        if resolvedLimits == nil,
            let retryMessage = collector.error(4),
            isExpiredAuthenticationError(retryMessage)
        {
            return expiredSnapshot(profile: profile, accountResult: refreshedAccount)
        }
    }
    guard let limits = resolvedLimits else {
        let responseID = collector.result(3) == nil ? 2 : 4
        throw codexError(
            code: 1,
            collector.error(responseID).map { "Codex rate-limit check failed: \($0)" }
                ?? "Codex rate-limit check timed out")
    }
    let billing = CodexBillingClient().fetch(profile: profile)
    return CodexNormalizer.snapshot(
        profile: profile,
        accountResult: resolvedAccount,
        rateLimitResult: limits,
        billingResult: billing
    )
}

private func handle(_ request: AdapterRequest) -> AdapterResponse {
    guard request.protocolVersion == adapterProtocolVersion else {
        return AdapterResponse(ok: false, message: "Unsupported adapter protocol version")
    }
    switch request.operation {
    case .describe:
        return AdapterResponse(ok: true, provider: BuiltinProviders.codex)
    case .refresh:
        guard let profile = request.profile else { return AdapterResponse(ok: false, message: "Profile is required") }
        do { return AdapterResponse(ok: true, snapshot: try refresh(profile: profile)) } catch {
            return AdapterResponse(ok: false, message: error.localizedDescription)
        }
    case .primeQuota:
        guard let profile = request.profile else { return AdapterResponse(ok: false, message: "Profile is required") }
        do {
            let receipt = try primeQuota(profile: profile)
            return AdapterResponse(
                ok: true, message: "Codex primer completed. Weekly reset verification is pending.", primerReceipt: receipt
            )
        } catch {
            return AdapterResponse(ok: false, message: error.localizedDescription)
        }
    case .prepareLogin:
        guard let profile = request.profile,
            let codex = VendorExecutable.resolveCodex()
        else {
            return AdapterResponse(ok: false, message: "Codex CLI is not installed")
        }
        return AdapterResponse(
            ok: true,
            loginCommand: LoginCommand(
                executable: codex,
                arguments: ["login"],
                environment: profile.isDefault ? [:] : ["CODEX_HOME": profile.configPath],
                requiresPTY: true
            ))
    case .configure:
        return AdapterResponse(ok: true)
    case .removeManagedCredentials:
        // Codex credentials live inside CODEX_HOME and are removed with the
        // app-server-owned managed profile directory.
        return AdapterResponse(ok: true)
    }
}

do {
    let input = try BoundedInput.read()
    let request = try JSONDecoder.quota.decode(AdapterRequest.self, from: input)
    let response = handle(request)
    FileHandle.standardOutput.write(try JSONEncoder.quota.encode(response))
} catch {
    let response = AdapterResponse(ok: false, message: "Invalid adapter request: \(error.localizedDescription)")
    FileHandle.standardOutput.write((try? JSONEncoder.quota.encode(response)) ?? Data())
}
