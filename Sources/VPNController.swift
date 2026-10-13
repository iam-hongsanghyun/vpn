import Foundation

/// The server shown as current; persisted so a relaunched app re-attaches to a running tunnel.
struct CurrentServer: Codable, Equatable {
    let id: String
    let host: String
    let ip: String
    let countryName: String
    let flag: String
}

@MainActor
final class VPNController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case authorizing
        case connecting(String)
        case connected
        case disconnecting
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var current: CurrentServer?
    @Published private(set) var tunnelIP: String?
    @Published private(set) var publicIP: String?

    private var pollTask: Task<Void, Never>?
    private static let connectTimeout: TimeInterval = 45

    init() {
        if Self.processAlive(), let data = try? Data(contentsOf: Paths.current) {
            current = try? JSONDecoder().decode(CurrentServer.self, from: data)
            phase = .connecting("기존 연결 확인 중")
            startPolling()
        }
    }

    var isBusy: Bool {
        switch phase {
        case .authorizing, .disconnecting: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch phase {
        case .connecting, .connected, .disconnecting: return true
        default: return false
        }
    }

    // MARK: - Connect / disconnect

    func connect(_ server: Server) {
        guard !isBusy else { return }
        if current?.id == server.id, isActive { return }
        guard let openvpn = Paths.openvpn else {
            phase = .failed("OpenVPN이 없습니다. 터미널에서 `brew install openvpn` 후 다시 시도하세요.")
            return
        }

        Task {
            if Self.processAlive() { await stopAndWait() }
            do {
                try writeFiles(for: server)
            } catch {
                phase = .failed("설정 파일을 쓰지 못했습니다: \(error.localizedDescription)")
                return
            }
            current = CurrentServer(id: server.id, host: server.host, ip: server.ip,
                                    countryName: server.countryName, flag: server.flag)
            tunnelIP = nil
            publicIP = nil
            phase = .authorizing

            let command = "\(Self.shellQuote(openvpn)) --config \(Self.shellQuote(Paths.config.path))"
            let result = await Self.runAsAdmin(command, prompt: "VPN Gate 서버(\(server.host))에 연결하려면 관리자 권한이 필요합니다.")
            switch result {
            case .canceled:
                phase = .idle
                current = nil
            case .failed(let message):
                phase = .failed("OpenVPN을 시작하지 못했습니다: \(message)")
            case .ok:
                phase = .connecting("서버에 연결 중")
                try? JSONEncoder().encode(current).write(to: Paths.current, options: .atomic)
                startPolling()
            }
        }
    }

    func disconnect() {
        guard Self.processAlive() else {
            phase = .idle
            current = nil
            return
        }
        phase = .disconnecting
        Task {
            await stopAndWait()
            phase = .idle
            current = nil
            tunnelIP = nil
            publicIP = nil
        }
    }

    /// Stops openvpn synchronously; used when the app quits.
    func disconnectBlocking() {
        guard Self.processAlive(), let password = Self.password() else { return }
        _ = Management.query("signal SIGTERM", password: password)
    }

    private func stopAndWait() async {
        pollTask?.cancel()
        let password = Self.password()
        let sent = await Task.detached {
            password.flatMap { Management.query("signal SIGTERM", password: $0) } != nil
        }.value
        if !sent, let pid = Self.pid() {
            _ = await Self.runAsAdmin("kill \(pid)", prompt: "VPN 연결을 끊으려면 관리자 권한이 필요합니다.")
        }
        for _ in 0..<50 where Self.processAlive() {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Status polling

    private func startPolling() {
        pollTask?.cancel()
        let deadline = Date().addingTimeInterval(Self.connectTimeout)
        pollTask = Task { [weak self] in
            var everConnected = false
            while !Task.isCancelled {
                guard let self else { return }
                let password = Self.password()
                let state = await Task.detached { password.flatMap { Management.state(password: $0) } }.value

                if let state {
                    if state.name == "CONNECTED" {
                        if phase != .connected {
                            phase = .connected
                            tunnelIP = state.tunnelIP
                            everConnected = true
                            Task { self.publicIP = await Self.fetchPublicIP() }
                        }
                    } else if phase != .disconnecting {
                        phase = .connecting(everConnected ? "재연결 중" : Self.label(for: state.name))
                    }
                } else if !Self.processAlive() {
                    if phase != .disconnecting {
                        let reason = Self.lastLogError() ?? "OpenVPN이 종료되었습니다."
                        phase = .failed(everConnected ? "연결이 끊어졌습니다: \(reason)" : reason)
                    }
                    return
                }

                if !everConnected, Date() > deadline, phase != .disconnecting {
                    let reason = Self.lastLogError()
                    await stopAndWait()
                    phase = .failed("시간 안에 연결되지 않았습니다." + (reason.map { " (\($0))" } ?? ""))
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private static func label(for state: String) -> String {
        switch state {
        case "WAIT", "CONNECTING", "TCP_CONNECT", "RESOLVE": return "서버에 연결 중"
        case "AUTH": return "인증 중"
        case "GET_CONFIG": return "설정 받는 중"
        case "ASSIGN_IP", "ADD_ROUTES": return "네트워크 설정 중"
        case "RECONNECTING": return "재연결 중"
        case "EXITING": return "종료 중"
        default: return state
        }
    }

    // MARK: - Files

    /// Writes the server's config with the overrides this app needs: modern cipher
    /// negotiation with CBC fallback, bounded retries, a password-protected management
    /// socket, and a log/pid file the app can read.
    private func writeFiles(for server: Server) throws {
        try Paths.ensureDir()
        let password = UUID().uuidString
        try Data(password.utf8).write(to: Paths.password, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.password.path)

        let dropped = ["cipher", "data-ciphers", "resolv-retry", "daemon", "log", "log-append",
                       "management", "writepid", "connect-retry-max", "connect-timeout"]
        let kept = server.config.split(whereSeparator: \.isNewline).filter { line in
            let keyword = line.split(separator: " ").first.map(String.init) ?? ""
            return !dropped.contains(keyword)
        }
        let overrides = [
            "data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-128-CBC",
            "data-ciphers-fallback AES-128-CBC",
            "resolv-retry 5",
            "connect-timeout 10",
            "connect-retry-max 2",
            "management 127.0.0.1 \(Management.port) \"\(Paths.password.path)\"",
            "log \"\(Paths.log.path)\"",
            "writepid \"\(Paths.pid.path)\"",
            "daemon vpngate-mac",
        ]
        let text = (kept.map(String.init) + overrides).joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: Paths.config, options: .atomic)
        try? FileManager.default.removeItem(at: Paths.pid)
    }

    private static func password() -> String? {
        (try? String(contentsOf: Paths.password, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pid() -> pid_t? {
        (try? String(contentsOf: Paths.pid, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// openvpn runs as root, so kill(pid, 0) answers EPERM while it is alive.
    nonisolated static func processAlive() -> Bool {
        guard let text = try? String(contentsOf: Paths.pid, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func lastLogError() -> String? {
        guard let log = try? String(contentsOf: Paths.log, encoding: .utf8) else { return nil }
        let keys = ["error", "fatal", "failed", "refused", "timed out", "exiting due to", "cannot", "unreachable"]
        let line = log.split(whereSeparator: \.isNewline).suffix(100).last { line in
            let l = line.lowercased()
            return keys.contains { l.contains($0) } && !l.contains("dns-updown") && !l.contains("shlock")
        }
        // Drop the "YYYY-MM-DD HH:MM:SS " timestamp.
        return line.map { $0.count > 20 && $0.first?.isNumber == true ? String($0.dropFirst(20)) : String($0) }
    }

    // MARK: - Helpers

    enum AdminResult { case ok, canceled, failed(String) }

    /// Runs a shell command as root through the standard macOS password prompt.
    nonisolated static func runAsAdmin(_ command: String, prompt: String) async -> AdminResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let script = "do shell script \(appleScriptQuote(command)) with administrator privileges with prompt \(appleScriptQuote(prompt))"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let stderr = Pipe()
                process.standardError = stderr
                process.standardOutput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failed(error.localizedDescription))
                    return
                }
                let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .ok)
                } else if message.contains("-128") {
                    continuation.resume(returning: .canceled)
                } else {
                    continuation.resume(returning: .failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
    }

    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func fetchPublicIP() async -> String? {
        var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
        request.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
