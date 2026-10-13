import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ServerStore
    @EnvironmentObject var vpn: VPNController

    @State private var selection: Set<Server.ID> = []
    @State private var sortOrder = [KeyPathComparator(\Server.score, order: .reverse)]
    @State private var country = "ALL"
    @State private var search = ""

    private var countries: [(code: String, label: String, count: Int)] {
        Dictionary(grouping: store.servers, by: \.countryCode)
            .map { code, list in (code, "\(list[0].flag) \(list[0].countryName)", list.count) }
            .sorted { $0.count > $1.count }
    }

    private var rows: [Server] {
        store.servers
            .filter { country == "ALL" || $0.countryCode == country }
            .filter {
                search.isEmpty
                    || $0.host.localizedCaseInsensitiveContains(search)
                    || $0.ip.contains(search)
                    || $0.countryName.localizedCaseInsensitiveContains(search)
                    || $0.operatorName.localizedCaseInsensitiveContains(search)
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()
            Divider()
            table
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 520)
        .searchable(text: $search, placement: .toolbar, prompt: "호스트, IP, 국가 검색")
        .toolbar {
            ToolbarItem {
                Picker("국가", selection: $country) {
                    Text("모든 국가 (\(store.servers.count))").tag("ALL")
                    Divider()
                    ForEach(countries, id: \.code) { c in
                        Text("\(c.label) (\(c.count))").tag(c.code)
                    }
                }
                .frame(width: 200)
            }
            ToolbarItem {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(store.loading)
                .help("VPN Gate에서 서버 목록 다시 받기")
            }
        }
        .task { await store.refresh() }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("국가", value: \.countryName) { s in
                Text("\(s.flag) \(s.countryName)")
            }
            .width(min: 110, ideal: 130)
            TableColumn("호스트", value: \.host) { s in
                HStack(spacing: 4) {
                    if vpn.current?.id == s.id && vpn.isActive {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(vpn.phase == .connected ? .green : .orange)
                    }
                    Text(s.host)
                }
            }
            .width(min: 120, ideal: 150)
            TableColumn("IP", value: \.ip) { s in
                Text(s.ip).monospacedDigit()
            }
            .width(min: 100, ideal: 120)
            TableColumn("핑 (ms)", value: \.ping) { s in
                Text(s.pingText).monospacedDigit()
            }
            .width(min: 50, ideal: 60)
            TableColumn("속도 (Mbps)", value: \.speedBps) { s in
                Text(String(format: "%.1f", s.speedMbps)).monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("접속자", value: \.sessions) { s in
                Text("\(s.sessions)").monospacedDigit()
            }
            .width(min: 50, ideal: 60)
            TableColumn("가동", value: \.uptimeMs) { s in
                Text(s.uptimeText)
            }
            .width(min: 50, ideal: 60)
            TableColumn("프로토콜", value: \.proto) { s in
                Text(s.protoText).monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("점수", value: \.score) { s in
                Text(s.score.formatted()).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: Server.ID.self) { ids in
            if let server = server(for: ids) {
                Button("\(server.host)에 연결") { vpn.connect(server) }
                    .disabled(vpn.isBusy)
            }
        } primaryAction: { ids in
            if let server = server(for: ids) { vpn.connect(server) }
        }
    }

    private var footer: some View {
        HStack {
            if store.loading {
                ProgressView().controlSize(.small)
                Text("서버 목록 받는 중…")
            } else if let error = store.error {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error)
            } else {
                Text("행을 더블클릭하면 연결됩니다")
            }
            Spacer()
            if let updated = store.updated {
                Text("\(rows.count)개 표시 · 목록 갱신 \(updated.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func server(for ids: Set<Server.ID>) -> Server? {
        guard let id = ids.first else { return nil }
        return store.servers.first { $0.id == id }
    }
}

struct StatusBar: View {
    @EnvironmentObject var vpn: VPNController

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
            Spacer()
            if case .connecting = vpn.phase {
                ProgressView().controlSize(.small)
            }
            if vpn.isActive {
                Button("연결 끊기", role: .destructive) { vpn.disconnect() }
                    .disabled(vpn.phase == .disconnecting)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var server: String {
        guard let c = vpn.current else { return "" }
        return "\(c.flag) \(c.host) (\(c.ip))"
    }

    private var title: String {
        switch vpn.phase {
        case .idle: return "연결 안 됨"
        case .authorizing: return "관리자 암호 입력 대기 중"
        case .connecting(let step): return "\(step) — \(server)"
        case .connected: return "연결됨 — \(server)"
        case .disconnecting: return "연결 끊는 중"
        case .failed: return "연결 실패"
        }
    }

    private var detail: String? {
        switch vpn.phase {
        case .idle: return "목록에서 서버를 더블클릭하세요."
        case .connected:
            let tunnel = vpn.tunnelIP.map { "터널 IP \($0)" } ?? ""
            let publicIP = "공인 IP \(vpn.publicIP ?? "확인 중…")"
            return [tunnel, publicIP].filter { !$0.isEmpty }.joined(separator: " · ")
        case .failed(let message): return message
        default: return nil
        }
    }

    private var color: Color {
        switch vpn.phase {
        case .idle: return .gray
        case .connected: return .green
        case .failed: return .red
        default: return .orange
        }
    }
}
