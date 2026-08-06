import Darwin
import Foundation
import QuotaContracts
import QuotaProviderKit

final class AdapterRegistry: @unchecked Sendable {
    private let manifests: [String: AdapterManifest]

    init() {
        let ownDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        let adapterDirectory =
            (ProcessInfo.processInfo.environment["CAPPY_ADAPTER_DIR"]
            ?? ProcessInfo.processInfo.environment["QUOTABAR_ADAPTER_DIR"])
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? ownDirectory
        var loaded: [String: AdapterManifest] = [
            "openai-codex": AdapterManifest(
                providerID: "openai-codex",
                displayName: "Codex",
                executable: adapterDirectory.appendingPathComponent("quota-adapter-codex").path
            ),
            "anthropic-claude": AdapterManifest(
                providerID: "anthropic-claude",
                displayName: "Claude",
                executable: adapterDirectory.appendingPathComponent("quota-adapter-claude").path
            ),
        ]

        if let files = try? FileManager.default.contentsOfDirectory(at: QuotaPaths.adaptersDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                    attributes[.type] as? FileAttributeType == .typeRegular,
                    let fileSize = attributes[.size] as? NSNumber,
                    fileSize.intValue <= 128 * 1024,
                    let data = try? Data(contentsOf: file),
                    var manifest = try? JSONDecoder.quota.decode(AdapterManifest.self, from: data),
                    manifest.protocolVersion == adapterProtocolVersion,
                    loaded[manifest.providerID] == nil,
                    Self.isValid(manifest: manifest),
                    Self.isTrustedExecutable(manifest.executable)
                else { continue }
                manifest.executable = URL(fileURLWithPath: manifest.executable).resolvingSymlinksInPath().path
                loaded[manifest.providerID] = manifest
            }
        }
        manifests = loaded
    }

    func manifest(providerID: String) -> AdapterManifest? { manifests[providerID] }
    func all() -> [AdapterManifest] { manifests.values.sorted { $0.displayName < $1.displayName } }

    private static func isTrustedExecutable(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: resolved),
            let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let permissions = attributes[.posixPermissions] as? NSNumber,
            let owner = attributes[.ownerAccountID] as? NSNumber
        else { return false }
        let unsafeWriteBits = permissions.intValue & 0o022
        return unsafeWriteBits == 0 && owner.intValue == getuid()
    }

    private static func isValid(manifest: AdapterManifest) -> Bool {
        guard manifest.providerID.range(of: "^[a-z0-9][a-z0-9-]{1,63}$", options: .regularExpression) != nil,
            !manifest.displayName.isEmpty, manifest.displayName.count <= 64,
            manifest.displayName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
            manifest.executable.hasPrefix("/"), manifest.executable.count <= 4_096,
            manifest.arguments.count <= 32,
            manifest.arguments.allSatisfy({ $0.count <= 512 && !$0.contains("\0") }),
            manifest.environment.count <= 64,
            manifest.environment.allSatisfy({
                $0.key.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$", options: .regularExpression) != nil
                    && $0.value.count <= 2_048 && !$0.value.contains("\0")
            })
        else {
            return false
        }
        return true
    }
}

enum AdapterRunner {
    static func call(manifest: AdapterManifest, request: AdapterRequest, timeout: TimeInterval = 25) throws -> AdapterResponse {
        let input = try JSONEncoder.quota.encode(request)
        let result = try ProcessRunner.run(
            manifest.executable,
            arguments: manifest.arguments,
            environment: manifest.environment,
            stdin: input,
            timeout: timeout,
            maxOutputBytes: 1_048_576
        )
        guard result.status == 0 else {
            throw NSError(
                domain: "ai.upriver.cappy.Adapter", code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: "Adapter exited with status \(result.status)"])
        }
        guard let response = try? JSONDecoder.quota.decode(AdapterResponse.self, from: result.stdout) else {
            throw NSError(
                domain: "ai.upriver.cappy.Adapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Adapter returned invalid data"])
        }
        guard response.protocolVersion == adapterProtocolVersion else {
            throw NSError(
                domain: "ai.upriver.cappy.Adapter", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Adapter returned an unsupported protocol version"])
        }
        return response
    }
}
