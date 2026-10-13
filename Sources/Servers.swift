import Foundation

/// One VPN Gate relay server, parsed from a row of the public server list.
struct Server: Identifiable, Hashable {
    let host: String
    let ip: String
    let score: Int
    let ping: Int          // ms; Int.max when the list reports none
    let speedBps: Int
    let countryName: String
    let countryCode: String
    let sessions: Int
    let uptimeMs: Int
    let totalUsers: Int
    let operatorName: String
    let proto: String      // "tcp" or "udp"
    let port: Int
    let config: String     // OpenVPN client config, decoded

    var id: String { host + "/" + ip }

    var flag: String {
        countryCode.uppercased().unicodeScalars
            .compactMap { Unicode.Scalar(127_397 + $0.value) }
            .map(String.init).joined()
    }

    var pingText: String { ping == Int.max ? "-" : "\(ping)" }
    var speedMbps: Double { Double(speedBps) / 1_000_000 }
    var protoText: String { "\(proto.uppercased()) \(port)" }

    var uptimeText: String {
        let hours = uptimeMs / 3_600_000
        if hours >= 24 { return "\(hours / 24)일" }
        if hours >= 1 { return "\(hours)시간" }
        return "\(uptimeMs / 60_000)분"
    }
}

enum ServerList {
    static let url = URL(string: "https://www.vpngate.net/api/iphone/")!

    /// Parses the VPN Gate CSV: a `*vpn_servers` line, a `#` header line,
    /// data rows whose 15th field is the base64 OpenVPN config, and a closing `*`.
    static func parse(_ text: String) -> [Server] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { line -> Server? in
            guard !line.hasPrefix("*"), !line.hasPrefix("#") else { return nil }
            let f = splitCSV(line)
            guard f.count >= 15,
                  let data = Data(base64Encoded: f[14], options: .ignoreUnknownCharacters)
            else { return nil }
            let config = String(decoding: data, as: UTF8.self)
            var proto = "tcp", port = 0
            for raw in config.split(whereSeparator: \.isNewline) {
                let parts = raw.split(separator: " ")
                if parts.first == "proto", parts.count > 1 { proto = String(parts[1]) }
                if parts.first == "remote", parts.count > 2 { port = Int(parts[2]) ?? 0 }
            }
            let server = Server(
                host: f[0], ip: f[1], score: Int(f[2]) ?? 0,
                ping: Int(f[3]) ?? Int.max, speedBps: Int(f[4]) ?? 0,
                countryName: f[5], countryCode: f[6], sessions: Int(f[7]) ?? 0,
                uptimeMs: Int(f[8]) ?? 0, totalUsers: Int(f[9]) ?? 0,
                operatorName: f[12].replacingOccurrences(of: "_", with: ","),
                proto: proto, port: port, config: config)
            return seen.insert(server.id).inserted ? server : nil
        }
    }

    /// Splits one CSV line, honouring double-quoted fields and `""` escapes.
    private static func splitCSV(_ line: Substring) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = line.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    let next = chars.next()
                    if next == "\"" { current.append("\"") } else { inQuotes = false; pending = next }
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                fields.append(current); current = ""
            } else {
                current.append(c)
            }
        }
        fields.append(current)
        return fields
    }
}

@MainActor
final class ServerStore: ObservableObject {
    @Published var servers: [Server] = []
    @Published var loading = false
    @Published var error: String?
    @Published var updated: Date?

    init() {
        if let cached = try? String(contentsOf: Paths.serverCache, encoding: .utf8) {
            servers = ServerList.parse(cached)
            updated = (try? FileManager.default.attributesOfItem(atPath: Paths.serverCache.path))?[.modificationDate] as? Date
        }
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            var request = URLRequest(url: ServerList.url)
            request.timeoutInterval = 30
            let (data, _) = try await URLSession.shared.data(for: request)
            let text = String(decoding: data, as: UTF8.self)
            let parsed = ServerList.parse(text)
            guard !parsed.isEmpty else { throw URLError(.cannotParseResponse) }
            servers = parsed
            updated = Date()
            error = nil
            try? Paths.ensureDir()
            try? data.write(to: Paths.serverCache, options: .atomic)
        } catch {
            self.error = "서버 목록을 받지 못했습니다: \(error.localizedDescription)"
        }
    }
}
