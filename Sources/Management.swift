import Foundation

/// File locations under ~/Library/Application Support/VPNGateMac.
enum Paths {
    static let dir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VPNGateMac", isDirectory: true)
    static let config = dir.appendingPathComponent("current.ovpn")
    static let password = dir.appendingPathComponent("management.pw")
    static let log = dir.appendingPathComponent("openvpn.log")
    static let pid = dir.appendingPathComponent("openvpn.pid")
    static let current = dir.appendingPathComponent("current.json")
    static let serverCache = dir.appendingPathComponent("servers.csv")

    static func ensureDir() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static let openvpn: String? = ["/opt/homebrew/sbin/openvpn", "/usr/local/sbin/openvpn"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Talks to the OpenVPN management interface on 127.0.0.1, which lets this
/// unprivileged app read state and stop the root-owned openvpn process.
enum Management {
    static let port: UInt16 = 7505

    /// Sends one command and returns the reply text, or nil when unreachable.
    static func query(_ command: String, password: String, timeout: Int = 2) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var buffer = ""
        func send(_ s: String) { _ = s.withCString { write(fd, $0, strlen($0)) } }
        func read(until done: (String) -> Bool) -> Bool {
            var chunk = [UInt8](repeating: 0, count: 4096)
            while !done(buffer) {
                let n = recv(fd, &chunk, chunk.count, 0)
                if n <= 0 { return false }
                buffer += String(decoding: chunk[0..<n], as: UTF8.self)
            }
            return true
        }

        guard read(until: { $0.contains("ENTER PASSWORD:") }) else { return nil }
        send(password + "\n")
        guard read(until: { $0.contains("SUCCESS: password is correct") }) else { return nil }
        buffer = ""
        send(command + "\n")
        _ = read(until: { reply in
            reply.split(whereSeparator: \.isNewline).contains {
                $0 == "END" || $0.hasPrefix("SUCCESS:") || $0.hasPrefix("ERROR:")
            }
        })
        send("quit\n")
        return buffer
    }

    struct State {
        let name: String       // CONNECTING, WAIT, AUTH, GET_CONFIG, ASSIGN_IP, ADD_ROUTES, CONNECTED, RECONNECTING, EXITING
        let tunnelIP: String
    }

    /// Parses the `state` reply: `<time>,<STATE>,<detail>,<local tunnel IP>,<remote IP>,...`.
    static func state(password: String) -> State? {
        guard let reply = query("state", password: password) else { return nil }
        for line in reply.split(whereSeparator: \.isNewline) where !line.hasPrefix(">") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            if f.count >= 4, Int(f[0]) != nil {
                return State(name: String(f[1]), tunnelIP: String(f[3]))
            }
        }
        return nil
    }
}
