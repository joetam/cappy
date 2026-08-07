import Foundation

public enum QuotaPaths {
    public static var stateDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CAPPY_STATE_DIR"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Cappy", isDirectory: true)
    }

    public static var socketURL: URL { stateDirectory.appendingPathComponent("appserver.sock") }
    public static var lockURL: URL { stateDirectory.appendingPathComponent("appserver.lock") }
    public static var stateURL: URL { stateDirectory.appendingPathComponent("state.json") }
    public static var cacheDirectory: URL { stateDirectory.appendingPathComponent("quota-cache", isDirectory: true) }
    public static var profilesDirectory: URL { stateDirectory.appendingPathComponent("profiles", isDirectory: true) }
    public static var pendingProfilesDirectory: URL { profilesDirectory.appendingPathComponent(".pending", isDirectory: true) }
    public static var deletedProfilesDirectory: URL { profilesDirectory.appendingPathComponent(".deleted", isDirectory: true) }
    public static var adaptersDirectory: URL { stateDirectory.appendingPathComponent("adapters", isDirectory: true) }

    public static func ensureDirectories() throws {
        for url in [
            stateDirectory, cacheDirectory, profilesDirectory, pendingProfilesDirectory, deletedProfilesDirectory, adaptersDirectory,
        ] {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard isDirectory.boolValue, attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw NSError(
                        domain: "ai.upriver.cappy.Paths", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Refused to use a non-directory or symbolic link at \(url.path)"])
                }
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }
}
