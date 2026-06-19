import SwiftUI
import AppKit
import Combine
import Foundation

// MARK: - Data Models (v2: Surge Edition)
struct Gateway: Codable { var ip: String; var ok: String; var rtt_ms: Double }
struct Domestic: Codable { var ok: Bool; var code: String; var ms: Int }
struct SurgeInfo: Codable {
    var running: Bool; var http_port: Bool; var socks_port: Bool
    // legacy compat
    init(running: Bool = false, http_port: Bool = false, socks_port: Bool = false) {
        self.running = running; self.http_port = http_port; self.socks_port = socks_port
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        http_port = try c.decodeIfPresent(Bool.self, forKey: .http_port) ?? false
        socks_port = try c.decodeIfPresent(Bool.self, forKey: .socks_port) ?? false
    }
}
struct ProxyInfo: Codable { var ok: Bool; var code: String; var ms: Int; var slow: Bool }
struct DirectInfo: Codable { var ok: Bool; var ms: Int }
struct ForeignInfo: Codable { var ok: Bool; var code: String; var ms: Int; var slow: Bool }
struct QLayer: Codable { var loss: Double?; var avg: Double?; var jitter: Double? }
struct Quality: Codable { var local: QLayer?; var net: QLayer? }
struct Status: Codable {
    var ts: String; var verdict: String; var reason: String
    var gateway: Gateway; var domestic: Domestic
    var surge: SurgeInfo?
    var proxy: ProxyInfo?       // v2 new field
    var direct: DirectInfo?     // v2 new field
    var foreign: ForeignInfo    // kept for compat (aliased to proxy in v2)
    var proxy_listen: Bool?     // legacy v1 field
    var quality: Quality?
    // Custom decoder: if proxy is nil but foreign exists, use foreign as proxy
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decode(String.self, forKey: .ts)
        verdict = try c.decode(String.self, forKey: .verdict)
        reason = try c.decode(String.self, forKey: .reason)
        gateway = try c.decode(Gateway.self, forKey: .gateway)
        domestic = try c.decode(Domestic.self, forKey: .domestic)
        surge = try c.decodeIfPresent(SurgeInfo.self, forKey: .surge)
        proxy = try c.decodeIfPresent(ProxyInfo.self, forKey: .proxy)
        direct = try c.decodeIfPresent(DirectInfo.self, forKey: .direct)
        foreign = try c.decodeIfPresent(ForeignInfo.self, forKey: .foreign) ??
            ForeignInfo(ok: proxy?.ok ?? false, code: proxy?.code ?? "000", ms: proxy?.ms ?? -1, slow: proxy?.slow ?? false)
        proxy_listen = try c.decodeIfPresent(Bool.self, forKey: .proxy_listen)
        quality = try c.decodeIfPresent(Quality.self, forKey: .quality)
    }
}
struct Event: Codable { var ts: String; var change: String; var verdict: String; var reason: String?; var note: String? }
struct TimelineRowData: Identifiable { let id = UUID(); var name: String; var cells: [Int] }


// MARK: - Monitor
final class Monitor: ObservableObject {
    @Published var status: Status?
    @Published var events: [Event] = []
    @Published var trend: [Int] = []
    @Published var timelines: [TimelineRowData] = []
    @Published var rangeLabel: String = ""
    @Published var ageSeconds: Int = -1
    @Published var serviceAlive: Bool = false
    @Published var lastLoad: String = ""
    @Published var foreignDown: Bool = false
    @Published var proxyLatencyHistory: [Int] = []
    @Published var directLatencyHistory: [Int] = []
    @Published var riskData: SimpleRisk?
    @Published var simpleRisk: SimpleRisk?
    private var downSince: Date?
    private var timer: Timer?
    private let base = NSHomeDirectory() + "/Library/Application Support/NetWatch"

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let r = self.compute()
            DispatchQueue.main.async {
                self.status = r.status; self.events = r.events
                self.trend = r.trend; self.timelines = r.timelines
                self.rangeLabel = r.range
                self.ageSeconds = r.age
                self.serviceAlive = (r.age >= 0 && r.age <= 90)
                self.proxyLatencyHistory = r.proxyLat
                self.directLatencyHistory = r.directLat
                self.riskData = r.risk
                self.simpleRisk = r.risk
                let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
                self.lastLoad = tf.string(from: Date())
                let isDown = (r.status?.foreign.ok == false)
                if isDown {
                    if self.downSince == nil { self.downSince = Date() }
                    let alarm = Date().timeIntervalSince(self.downSince!) >= 120
                    if alarm != self.foreignDown {
                        self.foreignDown = alarm
                        NSApp.dockTile.badgeLabel = alarm ? "!" : nil
                    }
                } else {
                    self.downSince = nil
                    if self.foreignDown { self.foreignDown = false }
                    NSApp.dockTile.badgeLabel = nil
                }
            }
        }
    }

    func diagnosticReport() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        var s = "============================================\n网络体检 · 体检报告\n导出时间：\(df.string(from: Date()))\n============================================\n\n"
        if let st = status {
            s += "【当前状态】\n判定：\(st.verdict)（\(st.reason)）\n"
            s += "网关：\(st.gateway.ok == "true" ? "通" : "不通")  国内：\(st.domestic.ok ? "通(\(st.domestic.ms)ms)" : "断")"
            if let sg = st.surge { s += "  Surge进程：\(sg.running ? "在跑" : "没跑")  HTTP:\(sg.http_port ? "✓" : "✗")  SOCKS:\(sg.socks_port ? "✓" : "✗")" }
            if let px = st.proxy { s += "\n经代理：\(px.ok ? "通(\(px.ms)ms)" : "断")" }
            if let di = st.direct { s += "  直连：\(di.ok ? "通(\(di.ms)ms)" : "断")" }
            s += "\n\n"
        }
        if let txt = try? String(contentsOfFile: base + "/logs/events.jsonl", encoding: .utf8) {
            s += "【最近故障/恢复事件】\n"
            for line in txt.split(separator: "\n").suffix(30) {
                if let e = try? JSONDecoder().decode(Event.self, from: Data(String(line).utf8)) {
                    s += "\(shortTS(e.ts))  \(e.change)\n"
                }
            }
        }
        s += "\n============================================\n"
        return s
    }

    private func compute() -> (status: Status?, events: [Event], trend: [Int], timelines: [TimelineRowData], range: String, age: Int, proxyLat: [Int], directLat: [Int], risk: SimpleRisk?) {
        var status: Status? = nil
        var age = -1
        if let d = try? Data(contentsOf: URL(fileURLWithPath: base + "/状态.json")),
           let s = try? JSONDecoder().decode(Status.self, from: d) {
            status = s
            if let dt = parseTS(s.ts) { age = Int(Date().timeIntervalSince(dt)) }
        }
        var events: [Event] = []
        if let txt = try? String(contentsOfFile: base + "/logs/events.jsonl", encoding: .utf8) {
            let lines = txt.split(separator: "\n").suffix(8)
            events = Array(lines.compactMap { try? JSONDecoder().decode(Event.self, from: Data(String($0).utf8)) }.reversed())
        }
        let logs = base + "/logs"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: logs)) ?? [])
            .filter { $0.hasPrefix("samples-") && $0.hasSuffix(".jsonl") }.sorted()
        var all: [Status] = []
        for f in files.suffix(3) {
            if let txt = try? String(contentsOfFile: logs + "/" + f, encoding: .utf8) {
                for line in txt.split(separator: "\n") {
                    if let s = try? JSONDecoder().decode(Status.self, from: Data(String(line).utf8)) { all.append(s) }
                }
            }
        }
        let recent = Array(all.suffix(2880))
        let trend = Array(recent.suffix(40).map { $0.foreign.ms })
        let proxyLat = Array(recent.suffix(40).compactMap { (($0.proxy?.ms) ?? -1) > 0 ? $0.proxy?.ms : nil })
        let directLat = Array(recent.suffix(40).compactMap { (($0.direct?.ms) ?? -1) > 0 ? $0.direct?.ms : nil })
        let timelines = buildTimelines(recent)
        var range = ""
        if let f = recent.first?.ts, let l = recent.last?.ts { range = "\(shortTS(f)) → \(shortTS(l))" }
        // Load risk data
        var risk: SimpleRisk? = nil
        if let rd = try? Data(contentsOf: URL(fileURLWithPath: base + "/风险评估.json")),
           let rd2 = try? JSONDecoder().decode(SimpleRisk.self, from: rd) {
            risk = rd2
        }
        return (status, events, trend, timelines, range, age, proxyLat, directLat, risk)
    }
    func loadRiskData() {
        DispatchQueue.global(qos: .utility).async {
            let p = self.base + "/风险评估.json"
            if let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
               let r = try? JSONDecoder().decode(SimpleRisk.self, from: d) {
                DispatchQueue.main.async { self.simpleRisk = r; self.riskData = r }
            }
        }
    }

    private func buildTimelines(_ s: [Status]) -> [TimelineRowData] {
        let layers: [(String, (Status) -> Bool)] = [
            ("路由器", { $0.gateway.ok == "true" }),
            ("国内网站", { $0.domestic.ok }),
            ("翻墙软件", { $0.surge?.running ?? ($0.proxy_listen ?? false) }),
            ("翻墙后", { $0.foreign.ok }),
        ]
        let N = 96; let cnt = s.count
        var out: [TimelineRowData] = []
        for (name, test) in layers {
            if cnt == 0 { out.append(TimelineRowData(name: name, cells: [])); continue }
            var cells = [Int]()
            for b in 0..<N {
                let lo = b * cnt / N
                let hi = max(lo + 1, (b + 1) * cnt / N)
                let slice = s[lo..<min(hi, cnt)]
                cells.append(slice.isEmpty ? -1 : (slice.allSatisfy { test($0) } ? 1 : 0))
            }
            out.append(TimelineRowData(name: name, cells: cells))
        }
        return out
    }

    private func parseTS(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }
    private func shortTS(_ s: String) -> String {
        if s.count >= 16 { return String(s[s.index(s.startIndex, offsetBy: 5)..<s.index(s.startIndex, offsetBy: 16)]).replacingOccurrences(of: "T", with: " ") }
        return s
    }
}



// MARK: - 颜色
let CL_BG = Color(red: 0.96, green: 0.96, blue: 0.97)
let CL_CARD = Color.white
let CL_CARD_SHADOW = Color.black.opacity(0.06)
let CL_PRIMARY = Color(red: 0.11, green: 0.11, blue: 0.12)
let CL_SECONDARY = Color(red: 0.53, green: 0.53, blue: 0.53)
let CL_TERTIARY = Color(red: 0.72, green: 0.72, blue: 0.74)
let CL_ACCENT = Color(red: 0.0, green: 0.44, blue: 0.89)
let CL_GREEN = Color(red: 0.20, green: 0.78, blue: 0.35)
let CL_ORANGE = Color(red: 1.0, green: 0.58, blue: 0.0)
let CL_RED = Color(red: 1.0, green: 0.23, blue: 0.19)
let CL_TRACK = Color(red: 0.91, green: 0.91, blue: 0.93)

func verdictColor(_ v: String) -> Color { switch v { case "正常": return CL_GREEN; case "国外缓慢": return CL_ORANGE; case "读取中…": return CL_TERTIARY; default: return CL_RED } }
func verdictSymbol(_ v: String) -> String { switch v { case "正常": return "checkmark.shield.fill"; case "国外缓慢": return "exclamationmark.triangle.fill"; case "读取中…": return "hourglass"; default: return "exclamationmark.octagon.fill" } }
func verdictLabel(_ v: String) -> String {
    switch v {
    case "正常": return "网络一切正常 👍"; case "国外缓慢": return "翻墙后网有点慢"; case "读取中…": return "正在检查..."
    case "本地网络断开": return "网线或 Wi-Fi 断了"; case "宽带/ISP故障": return "宽带/运营商出问题了"
    case "Surge 未运行": return "Surge 没开"; case "Surge 端口异常": return "Surge 设置有问题"; case "翻墙隧道异常": return "翻墙通道堵了"
    default: return v
    }
}

struct CardBackground: ViewModifier { func body(content: Content) -> some View { content.background(RoundedRectangle(cornerRadius: 16).fill(CL_CARD).shadow(color: CL_CARD_SHADOW, radius: 8, y: 3)) } }
extension View { var cardStyle: some View { modifier(CardBackground()) } }

// MARK: - 简化数据模型
struct SimpleRisk: Codable {
    var total_score: Int; var risk_level: String; var risk_emoji: String; var tspu_tier: String
    var signals_major: [String]; var signals_minor: [String]
    var proxy_ip: SimpleIP; var api_access: SimpleAPIs
    var proxy_info: SimpleProxyInfo?; var location_history: [SimpleLocHis]?; var location_changes_24h: Int?
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        total_score = try c.decodeIfPresent(Int.self, forKey: .total_score) ?? 0
        risk_level = try c.decodeIfPresent(String.self, forKey: .risk_level) ?? ""; risk_emoji = try c.decodeIfPresent(String.self, forKey: .risk_emoji) ?? ""
        tspu_tier = try c.decodeIfPresent(String.self, forKey: .tspu_tier) ?? ""
        signals_major = try c.decodeIfPresent([String].self, forKey: .signals_major) ?? []
        signals_minor = try c.decodeIfPresent([String].self, forKey: .signals_minor) ?? []
        proxy_ip = try c.decodeIfPresent(SimpleIP.self, forKey: .proxy_ip) ?? SimpleIP()
        api_access = try c.decodeIfPresent(SimpleAPIs.self, forKey: .api_access) ?? SimpleAPIs()
        proxy_info = try c.decodeIfPresent(SimpleProxyInfo.self, forKey: .proxy_info)
        location_history = try c.decodeIfPresent([SimpleLocHis].self, forKey: .location_history)
        location_changes_24h = try c.decodeIfPresent(Int.self, forKey: .location_changes_24h)
    }
}
struct SimpleIP: Codable {
    var ip: String = ""; var city: String = ""; var code: String = ""; var isp: String = ""
    var company_type: String = ""; var is_dc: Bool = false; var is_vpn: Bool = false; var is_proxy: Bool = false; var is_abuser: Bool = false
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        ip = try c.decodeIfPresent(String.self, forKey: .ip) ?? ""; city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""; isp = try c.decodeIfPresent(String.self, forKey: .isp) ?? ""
        company_type = try c.decodeIfPresent(String.self, forKey: .company_type) ?? ""
        is_dc = try c.decodeIfPresent(Bool.self, forKey: .is_dc) ?? false; is_vpn = try c.decodeIfPresent(Bool.self, forKey: .is_vpn) ?? false
        is_proxy = try c.decodeIfPresent(Bool.self, forKey: .is_proxy) ?? false; is_abuser = try c.decodeIfPresent(Bool.self, forKey: .is_abuser) ?? false
    }
    init() {}
}
struct SimpleAPIItem: Codable { var code: String = ""; var status: String = ""
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""; status = try c.decodeIfPresent(String.self, forKey: .status) ?? "" }
    init() {}
}
struct SimpleAPIs: Codable {
    var openai: SimpleAPIItem; var anthropic: SimpleAPIItem; var google: SimpleAPIItem
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        openai = try c.decodeIfPresent(SimpleAPIItem.self, forKey: .openai) ?? SimpleAPIItem()
        anthropic = try c.decodeIfPresent(SimpleAPIItem.self, forKey: .anthropic) ?? SimpleAPIItem()
        google = try c.decodeIfPresent(SimpleAPIItem.self, forKey: .google) ?? SimpleAPIItem()
    }
    init() { openai = SimpleAPIItem(); anthropic = SimpleAPIItem(); google = SimpleAPIItem() }
}
struct SimpleProxyApp: Codable {
    var name: String = ""; var running: Bool = false; var installed: Bool = false; var is_active: Bool = false; var http_port: Int = 0
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""; running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false; is_active = try c.decodeIfPresent(Bool.self, forKey: .is_active) ?? false
        http_port = try c.decodeIfPresent(Int.self, forKey: .http_port) ?? 0
    }
}
struct SimpleProxyInfo: Codable {
    var active_app: String = ""; var sys_proxy_on: Bool = false; var apps: [SimpleProxyApp] = []
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        active_app = try c.decodeIfPresent(String.self, forKey: .active_app) ?? ""
        sys_proxy_on = try c.decodeIfPresent(Bool.self, forKey: .sys_proxy_on) ?? false
        apps = try c.decodeIfPresent([SimpleProxyApp].self, forKey: .apps) ?? []
    }
}
struct SimpleLocHis: Codable {
    var ts: String = ""; var ip: String = ""; var location: String = ""; var isp: String = ""; var score: Int = 0; var changed: Bool = false
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        ts = try c.decodeIfPresent(String.self, forKey: .ts) ?? ""; ip = try c.decodeIfPresent(String.self, forKey: .ip) ?? ""
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""; isp = try c.decodeIfPresent(String.self, forKey: .isp) ?? ""
        score = try c.decodeIfPresent(Int.self, forKey: .score) ?? 0; changed = try c.decodeIfPresent(Bool.self, forKey: .changed) ?? false
    }
}

// MARK: - 健康状态
struct StatusHero: View {
    let verdict: String; let reason: String; let ageSeconds: Int; let serviceAlive: Bool
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(verdictColor(verdict).opacity(0.12)).frame(width: 88, height: 88)
                Circle().fill(verdictColor(verdict).opacity(0.25)).frame(width: 64, height: 64)
                Image(systemName: verdictSymbol(verdict)).font(.system(size: 28, weight: .semibold)).foregroundColor(verdictColor(verdict))
            }
            Text(verdictLabel(verdict)).font(.system(size: 22, weight: .bold)).foregroundColor(CL_PRIMARY)
            Text(reason).font(.system(size: 12)).foregroundColor(CL_SECONDARY).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16)
            HStack(spacing: 5) { Circle().fill(serviceAlive ? CL_GREEN : CL_RED).frame(width: 6, height: 6); Text(serviceAlive ? "自动监测中 · \(ageSeconds)s 前" : "⚠️ 可能停了").font(.system(size: 10)).foregroundColor(CL_TERTIARY) }.padding(.top, 2)
        }.frame(maxWidth: .infinity).padding(.vertical, 24).modifier(CardBackground())
    }
}
struct MetricPill: View {
    let icon: String; let label: String; let value: String; let ok: Bool
    var body: some View { HStack(spacing: 10) { Image(systemName: icon).font(.system(size: 16)).foregroundColor(ok ? CL_GREEN : CL_RED).frame(width: 28); VStack(alignment: .leading, spacing: 2) { Text(label).font(.system(size: 11)).foregroundColor(CL_TERTIARY); Text(value).font(.system(size: 13, weight: .medium)).foregroundColor(CL_PRIMARY) }; Spacer(); Circle().fill(ok ? CL_GREEN : CL_RED).frame(width: 8, height: 8) }.padding(.horizontal, 14).padding(.vertical, 10).background(Color(red: 0.97, green: 0.97, blue: 0.98)).cornerRadius(12) }
}
struct SurgeSection: View {
    let surge: SurgeInfo?; let proxy: ProxyInfo?; let direct: DirectInfo?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) { Image(systemName: "bolt.fill").font(.system(size: 13)).foregroundColor(CL_ACCENT); Text("翻墙软件 Surge").font(.system(size: 14, weight: .semibold)).foregroundColor(CL_PRIMARY); Spacer() }
            HStack(spacing: 8) { MetricPill(icon: "app.fill", label: "软件开着吗", value: surge?.running == true ? "开着呢" : "没开", ok: surge?.running ?? false); MetricPill(icon: "network", label: "翻墙通道 1", value: surge?.http_port == true ? "正常" : "不通", ok: surge?.http_port ?? false) }
            HStack(spacing: 8) { MetricPill(icon: "network", label: "翻墙通道 2", value: surge?.socks_port == true ? "正常" : "不通", ok: surge?.socks_port ?? false); MetricPill(icon: "globe", label: "能上 Google 吗", value: proxy?.ok == true ? "能 (\(proxy?.ms ?? 0)ms)" : "上不了", ok: proxy?.ok ?? false) }
        }.padding(14).cardStyle
    }
}
struct LatencyChart: View {
    let proxyValues: [Int]; let directValues: [Int]
    var body: some View {
        let mx = max(max(proxyValues.max() ?? 1, directValues.max() ?? 1), 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) { Label("走翻墙", systemImage: "circle.fill").font(.system(size: 10)).foregroundColor(CL_ACCENT); Label("不走翻墙", systemImage: "circle.fill").font(.system(size: 10)).foregroundColor(CL_TERTIARY); Spacer(); Text("越高越慢").font(.system(size: 9)).foregroundColor(CL_TERTIARY) }
            HStack(alignment: .bottom, spacing: 1.5) { ForEach(0..<max(proxyValues.count, directValues.count, 1), id: \.self) { i in VStack(spacing: 1) { RoundedRectangle(cornerRadius: 2).fill(CL_ACCENT.opacity(0.85)).frame(width: 4, height: max(2, CGFloat(i < proxyValues.count ? proxyValues[i] : 0) / CGFloat(mx) * 50)); RoundedRectangle(cornerRadius: 2).fill(CL_TERTIARY.opacity(0.5)).frame(width: 4, height: max(2, CGFloat(i < directValues.count ? directValues[i] : 0) / CGFloat(mx) * 50)) } } }.frame(height: 52)
        }.padding(14).cardStyle
    }
}
struct TimelineGrid: View {
    let data: [TimelineRowData]; let rangeLabel: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("最近网络稳不稳").font(.system(size: 13, weight: .semibold)).foregroundColor(CL_PRIMARY); Spacer(); Text("绿=正常 红=断了").font(.system(size: 9)).foregroundColor(CL_TERTIARY) }
            VStack(alignment: .leading, spacing: 5) { ForEach(data) { row in HStack(spacing: 8) { Text(row.name).font(.system(size: 10, weight: .medium)).foregroundColor(CL_SECONDARY).frame(width: 48, alignment: .leading); HStack(spacing: 0.4) { ForEach(Array(row.cells.enumerated()), id: \.offset) { _, c in RoundedRectangle(cornerRadius: 1).fill(c == 1 ? CL_GREEN : (c == 0 ? CL_RED.opacity(0.7) : CL_TRACK)).frame(width: 3, height: 12) } } } } }.padding(.top, 2)
            if !rangeLabel.isEmpty { Text(rangeLabel).font(.system(size: 8, design: .monospaced)).foregroundColor(CL_TERTIARY).padding(.leading, 56) }
        }.padding(14).cardStyle
    }
}
struct QualityPanel: View {
    let status: Status?; let trend: [Int]
    var foreignAvail: Double { let t = trend; if t.isEmpty { return 0 }; return Double(t.filter { $0 >= 0 }.count) / Double(t.count) * 100 }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("网好不好用").font(.system(size: 13, weight: .semibold)).foregroundColor(CL_PRIMARY)
            HStack(spacing: 8) { qItem("到路由器", loss: status?.quality?.local?.loss, jitter: status?.quality?.local?.jitter, avg: status?.quality?.local?.avg); qItem("到国内网站", loss: status?.quality?.net?.loss, jitter: status?.quality?.net?.jitter, avg: status?.quality?.net?.avg) }
            HStack(spacing: 8) { qItem("翻墙成功率", pct: foreignAvail) }
        }.padding(14).cardStyle
    }
    func qItem(_ name: String, loss: Double? = nil, jitter: Double? = nil, avg: Double? = nil, pct: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(size: 10)).foregroundColor(CL_TERTIARY)
            if let p = pct { Text("\(Int(p))%").font(.system(size: 16, weight: .bold)).foregroundColor(p >= 95 ? CL_GREEN : (p >= 80 ? CL_ORANGE : CL_RED)) }
            else { HStack(spacing: 8) { if let l = loss, l >= 0 { VStack(alignment: .leading, spacing: 1) { Text("掉线率").font(.system(size: 8)).foregroundColor(CL_TERTIARY); Text(String(format: "%.1f%%", l)).font(.system(size: 12, weight: .medium)).foregroundColor(l <= 1 ? CL_GREEN : (l <= 5 ? CL_ORANGE : CL_RED)) } }; if let j = jitter, j >= 0 { VStack(alignment: .leading, spacing: 1) { Text("卡顿").font(.system(size: 8)).foregroundColor(CL_TERTIARY); Text(String(format: "%.0fms", j)).font(.system(size: 12, weight: .medium)).foregroundColor(j <= 30 ? CL_GREEN : (j <= 100 ? CL_ORANGE : CL_RED)) } }; if let a = avg, a >= 0 { VStack(alignment: .leading, spacing: 1) { Text("响应").font(.system(size: 8)).foregroundColor(CL_TERTIARY); Text(String(format: "%.0fms", a)).font(.system(size: 12, weight: .medium)).foregroundColor(a <= 20 ? CL_GREEN : (a <= 50 ? CL_ORANGE : CL_RED)) } } } }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color(red: 0.97, green: 0.97, blue: 0.98)).cornerRadius(10)
    }
}

// MARK: - 安全体检卡片
struct RiskSection: View {
    @ObservedObject var m: Monitor
    @State private var isChecking = false
    var risk: SimpleRisk? { m.simpleRisk }
    func scoreColor(_ s: Int) -> Color { if s >= 85 { return CL_GREEN }; if s >= 70 { return CL_GREEN.opacity(0.8) }; if s >= 50 { return CL_ORANGE }; return CL_RED }
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "shield.checkered").font(.system(size: 14)).foregroundColor(CL_ACCENT)
                Text("账号安全体检").font(.system(size: 14, weight: .semibold)).foregroundColor(CL_PRIMARY)
                Spacer()
                Button(action: { runCheck() }) {
                    HStack(spacing: 4) {
                        if isChecking { ProgressView().scaleEffect(0.6).frame(width: 12, height: 12) } else { Image(systemName: "play.circle.fill") }
                        Text(isChecking ? "检测中..." : "一键检测").font(.system(size: 11, weight: .medium))
                    }.foregroundColor(.white).padding(.horizontal, 12).padding(.vertical, 6).background(isChecking ? CL_TERTIARY : CL_ACCENT).cornerRadius(8)
                }.buttonStyle(.plain).disabled(isChecking)
            }
            if let r = risk {
                // 1. IP 纯净度
                rr(icon: "ipaddress", title: "IP 纯净度", big: "\(r.total_score)", unit: "/100", detail: ipDetail(r), color: scoreColor(r.total_score))
                // 2. 被风控概率
                let rp = 100 - r.total_score
                rr(icon: "exclamationmark.shield", title: "被风控概率", big: "\(rp)", unit: "/100", detail: riskDetail(r), color: scoreColor(r.total_score))
                // 3. 当前代理地点
                rr(icon: "location.circle", title: "当前代理地点", big: nil, unit: "", detail: "\(r.proxy_ip.city) \(r.proxy_ip.code)", color: CL_ACCENT)
                // 4. 位置变更提醒
                if let ch = r.location_changes_24h, ch > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 14)).foregroundColor(CL_ORANGE)
                        VStack(alignment: .leading, spacing: 2) { Text("位置变更提醒").font(.system(size: 12, weight: .medium)).foregroundColor(CL_PRIMARY); Text("最近换过 \(ch) 次地点，频繁换地点容易触发风控！").font(.system(size: 10)).foregroundColor(CL_ORANGE) }
                        Spacer()
                    }.padding(10).background(CL_ORANGE.opacity(0.08)).cornerRadius(8)
                }
                // 5. 历史位置
                if let hist = r.location_history, !hist.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("📍 代理位置历史").font(.system(size: 11, weight: .semibold)).foregroundColor(CL_PRIMARY); Spacer(); Text("\(hist.count) 条").font(.system(size: 9)).foregroundColor(CL_TERTIARY) }
                        ForEach(Array(hist.suffix(8).reversed().enumerated()), id: \.offset) { _, h in
                            HStack(spacing: 8) {
                                Circle().fill(h.changed ? CL_ORANGE : CL_GREEN).frame(width: 6, height: 6)
                                Text(h.ts.count >= 16 ? String(h.ts[h.ts.index(h.ts.startIndex, offsetBy: 5)..<h.ts.index(h.ts.startIndex, offsetBy: 16)]).replacingOccurrences(of: "T", with: " ") : h.ts).font(.system(size: 9, design: .monospaced)).foregroundColor(CL_TERTIARY)
                                Text(h.location).font(.system(size: 10)).foregroundColor(h.changed ? CL_ORANGE : CL_PRIMARY)
                                Spacer()
                                Text("\(h.score)").font(.system(size: 9, weight: .medium)).foregroundColor(scoreColor(h.score))
                            }.padding(.vertical, 1)
                        }
                    }.padding(10).background(Color(red: 0.97, green: 0.97, blue: 0.98)).cornerRadius(8)
                }
                // 6. 翻墙软件
                if let pi = r.proxy_info {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("🖥 翻墙软件").font(.system(size: 11, weight: .semibold)).foregroundColor(CL_PRIMARY); Spacer(); if !pi.active_app.isEmpty { Text("当前: \(pi.active_app)").font(.system(size: 9, weight: .medium)).foregroundColor(CL_ACCENT) } }
                        ForEach(pi.apps, id: \.name) { app in
                            HStack(spacing: 6) {
                                Image(systemName: app.running ? "checkmark.circle.fill" : "circle").font(.system(size: 10)).foregroundColor(app.running ? CL_GREEN : CL_TERTIARY)
                                Text(app.name).font(.system(size: 10)).foregroundColor(app.running ? CL_PRIMARY : CL_TERTIARY)
                                if app.is_active { Text("（正在用）").font(.system(size: 8, weight: .medium)).foregroundColor(CL_ACCENT) }
                                Spacer()
                                if app.running { Text("端口 \(app.http_port)").font(.system(size: 8, design: .monospaced)).foregroundColor(CL_TERTIARY) }
                            }
                        }
                    }.padding(10).background(Color(red: 0.97, green: 0.97, blue: 0.98)).cornerRadius(8)
                }
            } else {
                Text("点击「一键检测」查看账号安全状况").font(.system(size: 11)).foregroundColor(CL_TERTIARY).padding(.top, 4)
            }
        }.padding(14).modifier(CardBackground())
    }
    func runCheck() {
        isChecking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let t = Process(); t.executableURL = URL(fileURLWithPath: "/bin/bash")
            t.arguments = [NSHomeDirectory() + "/Library/Application Support/NetWatch/risk_check.sh"]
            try? t.run(); t.waitUntilExit(); Thread.sleep(forTimeInterval: 1)
            DispatchQueue.main.async { m.loadRiskData(); isChecking = false }
        }
    }
    func ipDetail(_ r: SimpleRisk) -> String {
        let ip = r.proxy_ip
        if ip.is_dc { return "机房 IP（容易被封！）" }
        if ip.is_vpn { return "被标记为 VPN" }
        if ip.is_abuser { return "有滥用记录" }
        if ip.company_type == "isp" || ip.company_type.isEmpty { return "家庭宽带（安全）" }
        return ip.company_type
    }
    func riskDetail(_ r: SimpleRisk) -> String {
        if r.signals_major.isEmpty && r.signals_minor.isEmpty { return "暂时安全，放心用 👍" }
        return (r.signals_major.prefix(2) + r.signals_minor.prefix(1)).joined(separator: "；")
    }
    func rr(icon: String, title: String, big: String?, unit: String, detail: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).foregroundColor(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(CL_PRIMARY); Text(detail).font(.system(size: 10)).foregroundColor(CL_SECONDARY).fixedSize(horizontal: false, vertical: true) }
            Spacer()
            if let b = big { HStack(alignment: .firstTextBaseline, spacing: 1) { Text(b).font(.system(size: 18, weight: .bold)).foregroundColor(color); Text(unit).font(.system(size: 9)).foregroundColor(CL_TERTIARY) } }
        }.padding(10).background(Color(red: 0.97, green: 0.97, blue: 0.98)).cornerRadius(8)
    }
}

struct EventList: View {
    let events: [Event]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近发生了啥").font(.system(size: 12, weight: .semibold)).foregroundColor(CL_PRIMARY)
            if events.isEmpty { Text("一直很稳 ✅").font(.system(size: 12)).foregroundColor(CL_TERTIARY) }
            else { ForEach(Array(events.prefix(6).enumerated()), id: \.offset) { _, e in HStack(spacing: 8) { Text(e.ts.count >= 16 ? String(e.ts[e.ts.index(e.ts.startIndex, offsetBy: 5)..<e.ts.index(e.ts.startIndex, offsetBy: 16)]).replacingOccurrences(of: "T", with: " ") : e.ts).font(.system(size: 10, design: .monospaced)).foregroundColor(CL_TERTIARY); Text(e.change).font(.system(size: 11)).foregroundColor(e.verdict == "正常" ? CL_GREEN : CL_RED); Spacer() }.padding(.vertical, 2) } }
        }.padding(14).cardStyle
    }
}

struct ContentView: View {
    @ObservedObject var m: Monitor
    @State private var copied = false
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if m.foreignDown { HStack(spacing: 10) { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.white).font(.system(size: 18)); VStack(alignment: .leading, spacing: 1) { Text("翻墙后上不了外网了").foregroundColor(.white).font(.system(size: 14, weight: .bold)); Text("持续断了才提醒你").foregroundColor(.white.opacity(0.85)).font(.system(size: 10)) }; Spacer() }.padding(12).frame(maxWidth: .infinity).background(CL_RED).cornerRadius(12) }
                if let s = m.status { StatusHero(verdict: s.verdict, reason: s.reason, ageSeconds: m.ageSeconds, serviceAlive: m.serviceAlive) } else { StatusHero(verdict: "读取中…", reason: "正在连接...", ageSeconds: -1, serviceAlive: false) }
                VStack(spacing: 6) { if let s = m.status { MetricPill(icon: "house.fill", label: "路由器/光猫", value: "\(s.gateway.ip) · \(Int(s.gateway.rtt_ms))ms", ok: s.gateway.ok == "true"); MetricPill(icon: "globe.asia.australia.fill", label: "国内网站（百度）", value: "\(s.domestic.code) · \(s.domestic.ms)ms", ok: s.domestic.ok) } }.padding(.horizontal, 2)
                SurgeSection(surge: m.status?.surge, proxy: m.status?.proxy, direct: m.status?.direct)
                if !m.proxyLatencyHistory.isEmpty { LatencyChart(proxyValues: m.proxyLatencyHistory, directValues: m.directLatencyHistory) }
                if !m.timelines.isEmpty { TimelineGrid(data: m.timelines, rangeLabel: m.rangeLabel) }
                QualityPanel(status: m.status, trend: m.trend)
                RiskSection(m: m)
                EventList(events: m.events)
                VStack(spacing: 2) { Text("网络体检 · 每分钟自动检查 · 24h 值班").font(.system(size: 9)).foregroundColor(CL_TERTIARY); Text("上次: \(m.lastLoad)").font(.system(size: 8)).foregroundColor(CL_TERTIARY) }.padding(.top, 2)
            }.padding(16).frame(maxWidth: .infinity)
        }.frame(minWidth: 480, minHeight: 700).background(CL_BG)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!; let monitor = Monitor()
    func applicationDidFinishLaunching(_ n: Notification) {
        monitor.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "网络体检"; window.titlebarAppearsTransparent = true; window.backgroundColor = NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        window.contentView = NSHostingView(rootView: ContentView(m: monitor)); window.center(); window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool { if !f { window.makeKeyAndOrderFront(nil) }; NSApp.activate(ignoringOtherApps: true); return true }
}
let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
