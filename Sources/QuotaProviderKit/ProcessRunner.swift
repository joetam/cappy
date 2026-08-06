import Darwin
import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: LocalizedError {
    case executableNotFound(String)
    case timedOut(String)
    case failedToLaunch(String)
    case inputTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let value): "Executable not found: \(value)"
        case .timedOut(let value): "Command timed out: \(value)"
        case .failedToLaunch(let value): "Could not launch command: \(value)"
        case .inputTooLarge(let limit): "Input exceeds the \(limit)-byte safety limit"
        }
    }
}

public enum BoundedInput {
    public static func read(_ handle: FileHandle = .standardInput, maxBytes: Int = 1_048_576) throws -> Data {
        let limit = max(0, maxBytes)
        var data = Data()
        while data.count <= limit {
            let remaining = limit + 1 - data.count
            guard remaining > 0, let chunk = try handle.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw ProcessRunnerError.inputTooLarge(limit) }
        return data
    }
}

/// A deliberately small environment for helpers and vendor CLIs. In particular,
/// credentials exported in the launching shell are not forwarded to every
/// adapter process.
public enum ProcessEnvironment {
    public static func sanitized(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        adding additions: [String: String] = [:]
    ) -> [String: String] {
        let allowed = Set([
            "HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR",
            "LANG", "TERM", "COLORTERM", "BROWSER", "DISPLAY",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
            "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
            "__CF_USER_TEXT_ENCODING",
            "CAPPY_STATE_DIR", "CAPPY_ADAPTER_DIR",
            "CAPPY_CODEX_PATH", "CAPPY_CLAUDE_PATH",
            // Pre-Cappy compatibility. Remove only in a version with an explicit migration.
            "QUOTABAR_STATE_DIR", "QUOTABAR_ADAPTER_DIR",
            "QUOTABAR_CODEX_PATH", "QUOTABAR_CLAUDE_PATH",
        ])
        var result = environment.filter { key, _ in
            allowed.contains(key) || key.hasPrefix("LC_")
        }
        result.merge(additions) { _, new in new }
        return result
    }
}

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) { self.limit = max(0, limit) }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < limit else { return }
        data.append(chunk.prefix(limit - data.count))
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

public enum ProcessRunner {
    public static func resolveExecutable(_ nameOrPath: String, environment: [String: String] = ProcessInfo.processInfo.environment)
        -> String?
    {
        if nameOrPath.contains("/") {
            return FileManager.default.isExecutableFile(atPath: nameOrPath) ? nameOrPath : nil
        }
        let path = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/" + nameOrPath
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func run(
        _ executable: String,
        arguments: [String] = [],
        environment additions: [String: String] = [:],
        stdin: Data? = nil,
        timeout: TimeInterval = 20,
        maxOutputBytes: Int = 4 * 1_048_576
    ) throws -> ProcessResult {
        guard let resolved = resolveExecutable(executable) else { throw ProcessRunnerError.executableNotFound(executable) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = arguments
        process.environment = ProcessEnvironment.sanitized(adding: additions)

        let output = Pipe()
        let errors = Pipe()
        let capturedOutput = BoundedOutput(limit: maxOutputBytes)
        let capturedErrors = BoundedOutput(limit: maxOutputBytes)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { capturedOutput.append(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { capturedErrors.append(data) }
        }
        process.standardOutput = output
        process.standardError = errors
        let input = Pipe()
        if stdin != nil { process.standardInput = input }

        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }

        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw ProcessRunnerError.failedToLaunch(error.localizedDescription)
        }

        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        }

        if completed.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 2)
            }
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw ProcessRunnerError.timedOut(URL(fileURLWithPath: resolved).lastPathComponent)
        }

        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        capturedOutput.append(output.fileHandleForReading.readDataToEndOfFile())
        capturedErrors.append(errors.fileHandleForReading.readDataToEndOfFile())
        return ProcessResult(
            status: process.terminationStatus,
            stdout: capturedOutput.value(),
            stderr: capturedErrors.value()
        )
    }
}
