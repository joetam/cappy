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

private func writeMessage(_ message: [String: Any], to handle: FileHandle) throws {
    var data = try JSONSerialization.data(withJSONObject: message)
    data.append(0x0A)
    try handle.write(contentsOf: data)
}

private func refresh(profile: Profile) throws -> AccountSnapshot {
    guard
        let codex = VendorExecutable.resolve(
            "codex",
            overrideEnvironmentKey: "CAPPY_CODEX_PATH",
            legacyOverrideEnvironmentKey: "QUOTABAR_CODEX_PATH"
        )
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
    try writeMessage(
        ["method": "account/rateLimits/read", "id": 2, "params": [:]],
        to: input.fileHandleForWriting)

    collector.waitForResponse(id: 1, until: deadline)
    collector.waitForResponse(id: 2, until: deadline)
    guard !collector.overflowed else {
        throw codexError(code: 2, "Codex returned an oversized response")
    }
    guard let account = collector.result(1) else {
        throw codexError(
            code: 1,
            collector.error(1).map { "Codex account check failed: \($0)" } ?? "Codex account check timed out")
    }
    let limits = collector.result(2) ?? .object([:])
    return CodexNormalizer.snapshot(profile: profile, accountResult: account, rateLimitResult: limits)
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
    case .prepareLogin:
        guard let profile = request.profile,
            let codex = VendorExecutable.resolve(
                "codex",
                overrideEnvironmentKey: "CAPPY_CODEX_PATH",
                legacyOverrideEnvironmentKey: "QUOTABAR_CODEX_PATH"
            )
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
