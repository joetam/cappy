import Foundation
import QuotaProviderKit

public enum AppServerLauncher {
    public static func run() throws {
        try QuotaPaths.ensureDirectories()
        let instanceLock = try SingleInstanceLock(path: QuotaPaths.lockURL.path)
        let store = try StateStore()
        let appServer = AppServer(store: store, adapters: AdapterRegistry())
        DispatchQueue.global(qos: .utility).async { _ = try? appServer.refreshAll() }
        let server = SocketServer(path: QuotaPaths.socketURL.path, handler: appServer.handle)
        try withExtendedLifetime(instanceLock) { try server.run() }
    }
}
