import Darwin
import Foundation
import QuotaContracts

public struct RPCRequest: Codable, Sendable {
    public var jsonrpc = "2.0"
    public var id: String
    public var method: String
    public var params: JSONValue?

    public init(id: String = UUID().uuidString, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct RPCErrorPayload: Codable, Sendable, Error {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct RPCResponse: Codable, Sendable {
    public var jsonrpc = "2.0"
    public var id: String
    public var result: JSONValue?
    public var error: RPCErrorPayload?

    public init(id: String, result: JSONValue?, error: RPCErrorPayload?) {
        self.id = id
        self.result = result
        self.error = error
    }
}

public enum LocalRPCError: LocalizedError {
    case socket(String)
    case protocolError(String)
    case remote(RPCErrorPayload)

    public var errorDescription: String? {
        switch self {
        case .socket(let message), .protocolError(let message): message
        case .remote(let payload): payload.message
        }
    }
}

public final class LocalRPCClient: @unchecked Sendable {
    public let socketPath: String

    public init(socketPath: String = QuotaPaths.socketURL.path) { self.socketPath = socketPath }

    public func call(method: String, params: JSONValue? = nil) throws -> JSONValue? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalRPCError.socket("Could not create local socket") }
        defer { close(descriptor) }
        var noSIGPIPE: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout.size(ofValue: noSIGPIPE)))
        // A 64-profile refresh runs four adapters at a time and can legitimately
        // exceed five minutes when every provider reaches its timeout.
        var timeout = timeval(tv_sec: 600, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw LocalRPCError.socket("Socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, length) }
        }
        guard connected == 0 else { throw LocalRPCError.socket("Cappy app server is not running") }

        let request = RPCRequest(method: method, params: params)
        var payload = try JSONEncoder.quota.encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { throw LocalRPCError.protocolError("Could not encode app-server request") }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw LocalRPCError.socket("Could not write to app server") }
                offset += written
            }
        }

        var responseData = Data()
        var byte: UInt8 = 0
        var foundTerminator = false
        while responseData.count < 1_048_576 {
            let count = Darwin.read(descriptor, &byte, 1)
            if count <= 0 { break }
            if byte == 0x0A {
                foundTerminator = true
                break
            }
            responseData.append(byte)
        }
        guard !responseData.isEmpty else { throw LocalRPCError.protocolError("App server returned no response") }
        guard foundTerminator else { throw LocalRPCError.protocolError("App server returned an incomplete or oversized response") }
        let response = try JSONDecoder.quota.decode(RPCResponse.self, from: responseData)
        guard response.jsonrpc == "2.0", response.id == request.id else {
            throw LocalRPCError.protocolError("App server returned a mismatched response")
        }
        if let error = response.error { throw LocalRPCError.remote(error) }
        return response.result
    }
}

public extension JSONEncoder {
    static var quota: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var quota: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public extension JSONValue {
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder.quota.encode(value)
        return try JSONDecoder.quota.decode(JSONValue.self, from: data)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder.quota.encode(self)
        return try JSONDecoder.quota.decode(type, from: data)
    }
}
