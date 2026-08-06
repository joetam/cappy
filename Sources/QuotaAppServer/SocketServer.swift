import Darwin
import Foundation
import QuotaProviderKit

final class SingleInstanceLock {
    private var descriptor: Int32

    init(path: String) throws {
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(
                domain: "ai.upriver.cappy.Lock", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Could not create the app-server lock"])
        }
        fchmod(descriptor, S_IRUSR | S_IWUSR)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            throw NSError(
                domain: "ai.upriver.cappy.Lock", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Cappy app server is already running"])
        }
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}

final class SocketServer {
    private let path: String
    private let handler: @Sendable (RPCRequest) -> RPCResponse
    private var descriptor: Int32 = -1

    init(path: String, handler: @escaping @Sendable (RPCRequest) -> RPCResponse) {
        self.path = path
        self.handler = handler
    }

    func run() throws {
        unlink(path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("Could not create socket") }
        Self.disableSIGPIPE(descriptor)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw socketError("Socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, length) }
        }
        guard bound == 0 else { throw socketError("Could not bind socket") }
        chmod(path, S_IRUSR | S_IWUSR)
        guard listen(descriptor, 16) == 0 else { throw socketError("Could not listen on socket") }

        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 { continue }
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
                close(client)
                continue
            }
            Self.disableSIGPIPE(client)
            Self.setTimeout(client, seconds: 10)
            DispatchQueue.global(qos: .userInitiated).async { [handler] in
                defer { close(client) }
                guard let request = Self.readRequest(client) else { return }
                let response = handler(request)
                guard var data = try? JSONEncoder.quota.encode(response) else { return }
                data.append(0x0A)
                data.withUnsafeBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    var offset = 0
                    while offset < buffer.count {
                        let written = Darwin.write(client, baseAddress.advanced(by: offset), buffer.count - offset)
                        if written <= 0 { break }
                        offset += written
                    }
                }
            }
        }
    }

    private static func disableSIGPIPE(_ descriptor: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
    }

    private static func setTimeout(_ descriptor: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }

    private static func readRequest(_ descriptor: Int32) -> RPCRequest? {
        var data = Data(), byte: UInt8 = 0
        var foundTerminator = false
        while data.count < 1_048_576 {
            let count = Darwin.read(descriptor, &byte, 1)
            if count <= 0 { break }
            if byte == 0x0A {
                foundTerminator = true
                break
            }
            data.append(byte)
        }
        guard foundTerminator else { return nil }
        return try? JSONDecoder.quota.decode(RPCRequest.self, from: data)
    }

    private func socketError(_ message: String) -> NSError {
        NSError(
            domain: "ai.upriver.cappy.Socket", code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(errno)))"])
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
        unlink(path)
    }
}
