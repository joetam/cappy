import Darwin
import Foundation
import QuotaContracts
import QuotaProviderKit

final class LoginCoordinator: @unchecked Sendable {
    private static let maximumLoginDuration: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var jobs: [String: LoginJob] = [:]
    private var processes: [String: Process] = [:]
    private var timeouts: [String: DispatchWorkItem] = [:]
    private var committing: Set<String> = []
    var onCompletion: (@Sendable (LoginJob) -> Void)?

    func start(profileID: String, command: LoginCommand) throws -> LoginJob {
        let id = UUID().uuidString
        let job = LoginJob(id: id, profileID: profileID, state: .running, startedAt: Date())
        lock.lock()
        if let existing = jobs.values.first(where: {
            $0.profileID == profileID && ($0.state == .running || $0.state == .verifying)
        }) {
            lock.unlock()
            return existing
        }
        pruneCompletedJobsLocked()
        jobs[id] = job
        lock.unlock()

        let process = Process()
        if command.requiresPTY, FileManager.default.isExecutableFile(atPath: "/usr/bin/script") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", command.executable] + command.arguments
        } else {
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
        }
        process.environment = ProcessEnvironment.sanitized(adding: command.environment)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock()
            self.processes.removeValue(forKey: id)
            self.timeouts.removeValue(forKey: id)?.cancel()
            if var current = self.jobs[id] {
                if current.state == .running {
                    current.state = process.terminationStatus == 0 ? .verifying : .failed
                    current.message =
                        process.terminationStatus == 0
                        ? "Verifying the signed-in account…" : "Vendor login exited with status \(process.terminationStatus)."
                }
                self.jobs[id] = current
                self.lock.unlock()
                self.onCompletion?(current)
                return
            }
            self.lock.unlock()
        }
        do {
            try process.run()
            lock.lock()
            if jobs[id]?.state == .running {
                processes[id] = process
                let timeout = DispatchWorkItem { [weak self] in self?.timeout(id: id) }
                timeouts[id] = timeout
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + Self.maximumLoginDuration,
                    execute: timeout
                )
            }
            lock.unlock()
        } catch {
            lock.lock(); jobs.removeValue(forKey: id); lock.unlock()
            throw error
        }
        return job
    }

    func job(id: String) -> LoginJob? {
        lock.lock(); defer { lock.unlock() }
        return jobs[id]
    }

    func succeed(id: String, message: String? = nil) {
        update(id: id, state: .succeeded, message: message)
    }

    func fail(id: String, message: String) {
        update(id: id, state: .failed, message: message)
    }

    @discardableResult
    func cancel(id: String) throws -> LoginJob {
        lock.lock()
        guard var job = jobs[id] else {
            lock.unlock()
            throw NSError(domain: "ai.upriver.cappy.Login", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown login job"])
        }
        let process = processes[id]
        if job.state == .running || (job.state == .verifying && !committing.contains(id)) {
            job.state = .cancelled
            job.message = "Sign-in cancelled. You can try again."
            jobs[id] = job
            timeouts.removeValue(forKey: id)?.cancel()
        } else if job.state == .verifying {
            job.message = "Finishing sign-in verification…"
            jobs[id] = job
        }
        lock.unlock()
        if let process, process.isRunning { Self.terminateProcessTree(process) }
        return job
    }

    func cancelJobs(profileID: String) {
        lock.lock()
        let ids = jobs.values.filter { $0.profileID == profileID && ($0.state == .running || $0.state == .verifying) }.map(\.id)
        lock.unlock()
        for id in ids { _ = try? cancel(id: id) }
    }

    func beginCommit(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var job = jobs[id], job.state == .verifying, !committing.contains(id) else { return false }
        committing.insert(id)
        job.message = "Saving the Cappy connection…"
        jobs[id] = job
        return true
    }

    private func update(id: String, state: LoginJob.State, message: String?) {
        lock.lock(); defer { lock.unlock() }
        guard var job = jobs[id], job.state != .cancelled else { return }
        job.state = state
        job.message = message
        jobs[id] = job
        if state != .running && state != .verifying {
            committing.remove(id)
            timeouts.removeValue(forKey: id)?.cancel()
        }
    }

    private func timeout(id: String) {
        lock.lock()
        guard var job = jobs[id], job.state == .running else {
            timeouts.removeValue(forKey: id)?.cancel()
            lock.unlock()
            return
        }
        job.state = .failed
        job.message = "Sign-in timed out. Try again."
        jobs[id] = job
        let process = processes[id]
        timeouts.removeValue(forKey: id)?.cancel()
        lock.unlock()
        if let process, process.isRunning {
            Self.terminateProcessTree(process)
        } else {
            onCompletion?(job)
        }
    }

    private func pruneCompletedJobsLocked() {
        let completed = jobs.values
            .filter { $0.state != .running && $0.state != .verifying }
            .sorted { $0.startedAt < $1.startedAt }
        for job in completed.dropLast(100) {
            jobs.removeValue(forKey: job.id)
            committing.remove(job.id)
            timeouts.removeValue(forKey: job.id)?.cancel()
        }
    }

    private static func terminateProcessTree(_ process: Process) {
        let root = process.processIdentifier
        for child in descendants(of: root).reversed() {
            _ = Darwin.kill(child, SIGTERM)
        }
        process.terminate()
    }

    private static func descendants(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var pending = [root]
        while let parent = pending.popLast() {
            let children = directChildren(of: parent)
            result.append(contentsOf: children)
            pending.append(contentsOf: children)
        }
        return result
    }

    private static func directChildren(of parent: pid_t) -> [pid_t] {
        var capacity = 16
        while capacity <= 1_024 {
            var children = [pid_t](repeating: 0, count: capacity)
            let byteCount = children.withUnsafeMutableBytes { buffer in
                proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
            }
            guard byteCount > 0 else { return [] }
            let childCount = Int(byteCount) / MemoryLayout<pid_t>.size
            if childCount < children.count {
                return Array(children.prefix(childCount)).filter { $0 > 0 }
            }
            capacity *= 2
        }
        return []
    }
}
