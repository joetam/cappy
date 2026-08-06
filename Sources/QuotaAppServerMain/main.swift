import Foundation
import QuotaAppServerCore

do {
    try AppServerLauncher.run()
} catch {
    FileHandle.standardError.write(Data("quota-appserver: \(error.localizedDescription)\n".utf8))
    exit(1)
}
