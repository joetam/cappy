import Foundation
import QuotaContracts
import QuotaProviderKit

private func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("quota: \(message)\n".utf8))
    exit(status)
}

private func sibling(_ name: String) -> String {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent(name).path
}

private func ensureServer() throws {
    let client = LocalRPCClient()
    let initialPing = try? client.call(method: "system.ping")
    if initialPing?["serverAPIVersion"]?.doubleValue == Double(quotaAppServerAPIVersion) {
        return
    }
    if initialPing != nil {
        _ = try? client.call(method: "system.shutdown")
        Thread.sleep(forTimeInterval: 0.3)
    }
    let executable = sibling("quota-appserver")
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        throw NSError(
            domain: "ai.upriver.cappy.CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "quota-appserver is not installed next to quota"]
        )
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.environment = ProcessEnvironment.sanitized()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    for _ in 0..<40 {
        Thread.sleep(forTimeInterval: 0.05)
        let ping = try? LocalRPCClient().call(method: "system.ping")
        if ping?["serverAPIVersion"]?.doubleValue == Double(quotaAppServerAPIVersion) {
            return
        }
    }
    throw NSError(domain: "ai.upriver.cappy.CLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "quota-appserver did not start"])
}

private func call(_ method: String, _ params: JSONValue? = nil) throws -> JSONValue? {
    try ensureServer()
    return try LocalRPCClient().call(method: method, params: params)
}

private func requiredCall(_ method: String, _ params: JSONValue? = nil) throws -> JSONValue {
    guard let value = try call(method, params) else {
        throw NSError(
            domain: "ai.upriver.cappy.CLI", code: 3, userInfo: [NSLocalizedDescriptionKey: "The app server returned an empty response"])
    }
    return value
}

private func pretty<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder.quota
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func status(json: Bool) throws {
    let value = try call("snapshot.list") ?? .array([])
    let snapshots = try value.decode([AccountSnapshot].self)
    if json { print(try pretty(snapshots)); return }
    if snapshots.isEmpty { print("No accounts found."); return }
    for snapshot in snapshots {
        let plan = snapshot.subscription?.planName.map { " · \($0)" } ?? ""
        let renewal =
            snapshot.subscription?.nextBillingDate.map {
                " · renews \($0.formatted(date: .abbreviated, time: .omitted))"
            } ?? ""
        print("\(snapshot.provider.displayName) / \(snapshot.profileLabel)\(plan)\(renewal)")
        if snapshot.authenticationState != .authenticated {
            print("  \(snapshot.authenticationState.rawValue): \(snapshot.message ?? "No account information")")
            continue
        }
        if snapshot.meters.isEmpty { print("  \(snapshot.message ?? "No quota meters yet")") }
        for meter in snapshot.meters {
            if let fraction = meter.usedFraction {
                let reset = meter.resetsAt.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
                let name = String(meter.displayName.prefix(24)).padding(toLength: 24, withPad: " ", startingAt: 0)
                let percent = String(format: "%5.1f", fraction * 100)
                print("  \(name) \(percent)% used\(reset)")
            } else if let remaining = meter.remaining {
                print("  \(meter.displayName): \(remaining.formatted()) \(meter.unit.rawValue) remaining")
            } else {
                print("  \(meter.displayName): \(meter.status.rawValue)")
            }
        }
    }
}

private func addAccount(arguments: ArraySlice<String>) throws {
    guard arguments.count >= 2, let rawProvider = arguments.first else { fail("usage: quota add <codex|claude|provider-id> <label>") }
    let provider = rawProvider == "codex" ? "openai-codex" : (rawProvider == "claude" ? "anthropic-claude" : rawProvider)
    let label = arguments.dropFirst().joined(separator: " ")
    let value = try requiredCall("profile.enroll", .object(["providerID": .string(provider), "label": .string(label)]))
    var job = try value.decode(LoginJob.self)
    print("Complete sign-in with the provider. The profile will be saved after verification.")
    while job.state == .running || job.state == .verifying {
        Thread.sleep(forTimeInterval: 0.5)
        job = try requiredCall("login.status", .object(["jobID": .string(job.id)])).decode(LoginJob.self)
    }
    if job.state == .succeeded { print(job.message ?? "Account added.") } else { fail(job.message ?? "Sign-in did not complete") }
}

private func removeAccount(arguments: [String]) throws {
    guard arguments.count == 2 else { fail("usage: quota remove <profile-id>") }
    let result = try requiredCall("profile.remove", .object(["profileID": .string(arguments[1])])).decode(ProfileRemovalResult.self)
    print("Removed \(result.profile.label) from Cappy. The provider account was not deleted.")
    if let warning = result.warning { FileHandle.standardError.write(Data("quota: \(warning)\n".utf8)) }
}

private func reorderAccounts(arguments: ArraySlice<String>) throws {
    let profileIDs = Array(arguments)
    guard !profileIDs.isEmpty else { fail("usage: quota reorder <profile-id>...") }
    let params: JSONValue = .object(["profileIDs": .array(profileIDs.map(JSONValue.string))])
    _ = try requiredCall("profile.reorder", params).decode([ProfileSummary].self)
    print("Saved account order.")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first ?? "status"
    switch command {
    case "status": try status(json: arguments.contains("--json"))
    case "refresh":
        _ = try call("refresh.all")
        try status(json: arguments.contains("--json"))
    case "profiles":
        let profiles = try requiredCall("profile.list").decode([ProfileSummary].self)
        print(try pretty(profiles))
    case "providers":
        let providers = try requiredCall("provider.list").decode([ProviderDescriptor].self)
        print(try pretty(providers))
    case "add": try addAccount(arguments: arguments.dropFirst())
    case "remove": try removeAccount(arguments: arguments)
    case "reorder": try reorderAccounts(arguments: arguments.dropFirst())
    case "login":
        guard arguments.count == 2 else { fail("usage: quota login <profile-id>") }
        _ = try call("profile.login", .object(["profileID": .string(arguments[1])]))
        print("Complete sign-in in the browser.")
    case "help", "--help", "-h":
        print(
            """
            quota status [--json]               Show all accounts and meters
            quota refresh [--json]              Refresh all providers
            quota profiles                      List credential slots
            quota providers                     List installed adapters
            quota add <provider> <label>         Create a managed profile and sign in
            quota remove <managed-profile-id>    Remove a managed profile and its isolated local credentials
            quota reorder <profile-id>...        Set the order using every tracked profile ID
            quota login <managed-profile-id>     Sign into an existing managed profile
            """)
    default: fail("unknown command: \(command)")
    }
} catch {
    fail(error.localizedDescription)
}
