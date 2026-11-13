import Foundation
import Darwin

public enum SocketError: LocalizedError {
    case createFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case acceptFailed(Int32)
    case acceptTimedOut
    case readFailed(Int32)
    case readTimedOut
    case connectionClosed
    case writeFailed(Int32)
    case invalidPort

    public var errorDescription: String? {
        switch self {
        case .createFailed(let code): return "Could not create local socket (\(code))"
        case .bindFailed(let code): return "Could not bind local socket (\(code))"
        case .listenFailed(let code): return "Could not listen on local socket (\(code))"
        case .acceptFailed(let code): return "Could not accept device connection (\(code))"
        case .acceptTimedOut: return "Timed out waiting for the device stream"
        case .readFailed(let code): return "Device stream read failed (\(code))"
        case .readTimedOut: return "Timed out waiting for the device stream"
        case .connectionClosed: return "The device closed the connection"
        case .writeFailed(let code): return "Could not send input to the device (\(code))"
        case .invalidPort: return "Invalid local port"
        }
    }
}

/// A loopback-only TCP listener used for scrcpy's reverse tunnel.
public final class LoopbackTCPServer: @unchecked Sendable {
    private var descriptor: Int32
    private let lock = NSLock()
    public let port: UInt16

    public init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.createFailed(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.bindFailed(code)
        }
        guard Darwin.listen(fd, 4) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.listenFailed(code)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.bindFailed(code)
        }
        let hostPort = UInt16(bigEndian: boundAddress.sin_port)
        guard hostPort > 0 else {
            Darwin.close(fd)
            throw SocketError.invalidPort
        }

        self.descriptor = fd
        self.port = hostPort
    }

    public func accept(timeout: TimeInterval) throws -> Int32 {
        lock.lock()
        let fd = descriptor
        lock.unlock()
        guard fd >= 0 else { throw SocketError.connectionClosed }

        var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(1, min(timeout * 1000, Double(Int32.max))))
        let pollResult = poll(&pollDescriptor, 1, milliseconds)
        if pollResult == 0 { throw SocketError.acceptTimedOut }
        if pollResult < 0 {
            if errno == EINTR { return try accept(timeout: max(0.1, timeout)) }
            throw SocketError.acceptFailed(errno)
        }

        var clientAddress = sockaddr()
        var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
        let client = Darwin.accept(fd, &clientAddress, &clientLength)
        guard client >= 0 else { throw SocketError.acceptFailed(errno) }
        Self.configureAcceptedSocket(client)
        return client
    }

    public func close() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    deinit { close() }

    private static func configureAcceptedSocket(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
}

public enum SocketIO {
    public static func configureStream(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func setReadTimeout(_ fd: Int32, seconds: TimeInterval?) {
        var timeout = timeval()
        if let seconds {
            let whole = Int(seconds)
            timeout.tv_sec = whole
            timeout.tv_usec = Int32((seconds - Double(whole)) * 1_000_000)
        }
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func readExactly(fd: Int32, count: Int) throws -> Data {
        guard count >= 0 else { throw SocketError.readFailed(EINVAL) }
        if count == 0 { return Data() }
        var result = Data()
        result.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(count, 64 * 1024))
        while result.count < count {
            let remaining = count - result.count
            let capacity = min(buffer.count, remaining)
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(fd, bytes.baseAddress, capacity, 0)
            }
            if readCount == 0 { throw SocketError.connectionClosed }
            if readCount < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { throw SocketError.readTimedOut }
                throw SocketError.readFailed(code)
            }
            result.append(contentsOf: buffer.prefix(readCount))
        }
        return result
    }

    public static func readSome(fd: Int32, maxLength: Int = 16 * 1024) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let readCount = buffer.withUnsafeMutableBytes { bytes in
            Darwin.recv(fd, bytes.baseAddress, maxLength, 0)
        }
        if readCount == 0 { throw SocketError.connectionClosed }
        if readCount < 0 {
            let code = errno
            if code == EINTR { return try readSome(fd: fd, maxLength: maxLength) }
            if code == EAGAIN || code == EWOULDBLOCK { throw SocketError.readTimedOut }
            throw SocketError.readFailed(code)
        }
        return Data(buffer.prefix(readCount))
    }

    public static func writeAll(fd: Int32, data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw SocketError.writeFailed(code)
                }
                guard written > 0 else { throw SocketError.writeFailed(EPIPE) }
                offset += written
            }
        }
    }

    public static func shutdown(_ fd: Int32) {
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
