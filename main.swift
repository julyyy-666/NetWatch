import SwiftUI
import AppKit
import Combine
import Foundation
import QuartzCore

// MARK: - Data Models
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
    var proxy_app: String?
    var proxy_mode: String?
    var proxy_port: Int?
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
        proxy_app = try c.decodeIfPresent(String.self, forKey: .proxy_app)
        proxy_mode = try c.decodeIfPresent(String.self, forKey: .proxy_mode)
        proxy_port = try c.decodeIfPresent(Int.self, forKey: .proxy_port)
        proxy = try c.decodeIfPresent(ProxyInfo.self, forKey: .proxy)
        direct = try c.decodeIfPresent(DirectInfo.self, forKey: .direct)
        foreign = try c.decodeIfPresent(ForeignInfo.self, forKey: .foreign) ??
            ForeignInfo(ok: proxy?.ok ?? false, code: proxy?.code ?? "000", ms: proxy?.ms ?? -1, slow: proxy?.slow ?? false)
        proxy_listen = try c.decodeIfPresent(Bool.self, forKey: .proxy_listen)
        quality = try c.decodeIfPresent(Quality.self, forKey: .quality)
    }
}
struct Event: Codable { var ts: String; var change: String; var verdict: String; var reason: String?; var note: String? }


// MARK: - Monitor
final class Monitor: ObservableObject {
    @Published var status: Status?
    @Published var events: [Event] = []
    @Published var trend: [Int] = []
    @Published var rangeLabel: String = ""
    @Published var ageSeconds: Int = -1
    @Published var serviceAlive: Bool = false
    @Published var lastLoad: String = ""
    @Published var foreignDown: Bool = false
    @Published var proxyLatencyHistory: [Int] = []
    @Published var directLatencyHistory: [Int] = []
    @Published var riskData: SimpleRisk?
    @Published var simpleRisk: SimpleRisk?
    @Published var updateInfo: UpdateInfo?
    @Published var updateCheckMessage: String = ""
    @Published var checkingUpdates: Bool = false
    // 体检进行中标志：放 Monitor 上（不放 SecurityPage 的 @State），
    // 因为 .id(tab) 切 Tab 会销毁 SecurityPage、丢掉本地 @State，
    // 导致用户切走再切回时按钮误判为"空闲"、可重复点击 → 并发跑两个 risk_check.sh 写同一份 JSON。
    @Published var riskChecking: Bool = false
    @Published var checkInterval: Int = Monitor.savedCheckIntervalSeconds()
    private var downSince: Date?
    private var timer: Timer?
    private var updateTimer: Timer?
    private let base = NSHomeDirectory() + "/Library/Application Support/NetWatch"
    private let currentVersion: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "4.0"
        return v
    }()
    private let repoOwner = "julyyy-666"
    private let repoName = "NetWatch"
    private static let intervalKey = "NetWatchCheckIntervalSeconds"
    private static let allowedIntervals = [15, 30, 60]

    static func savedCheckIntervalSeconds() -> Int {
        let stored = UserDefaults.standard.integer(forKey: intervalKey)
        if allowedIntervals.contains(stored) { return stored }
        let path = NSHomeDirectory() + "/Library/Application Support/NetWatch/.check_interval"
        if let s = try? String(contentsOfFile: path, encoding: .utf8),
           let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)),
           allowedIntervals.contains(v) {
            UserDefaults.standard.set(v, forKey: intervalKey)
            return v
        }
        return 15
    }

    func setCheckInterval(_ seconds: Int) {
        guard Self.allowedIntervals.contains(seconds), seconds != checkInterval else { return }
        checkInterval = seconds
        UserDefaults.standard.set(seconds, forKey: Self.intervalKey)
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try? "\(seconds)".write(toFile: base + "/.check_interval", atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: .netWatchCheckIntervalChanged, object: seconds)
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        checkForUpdates()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkForUpdates() }
    }

    func checkForUpdates(manual: Bool = false) {
        if manual {
            updateCheckMessage = "正在检查..."
            checkingUpdates = true
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let url = URL(string: "https://api.github.com/repos/\(self.repoOwner)/\(self.repoName)/releases/latest")!
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            guard let data = URLSession.shared.synchronousData(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if manual {
                    DispatchQueue.main.async {
                        self.updateCheckMessage = "检查失败，可能是网络不通"
                        self.checkingUpdates = false
                    }
                }
                return
            }
            let tag = json["tag_name"] as? String ?? ""
            let cleanTag = tag.replacingOccurrences(of: "v", with: "")
            let name = json["name"] as? String ?? tag
            let htmlUrl = json["html_url"] as? String ?? ""
            let body = json["body"] as? String ?? ""
            var dmgUrl = ""
            if let assets = json["assets"] as? [[String: Any]] {
                for a in assets {
                    if let n = a["name"] as? String, n.lowercased().hasSuffix(".dmg"),
                       let u = a["browser_download_url"] as? String { dmgUrl = u; break }
                }
            }
            let hasUpdate = cleanTag.compare(self.currentVersion, options: .numeric) == .orderedDescending
            DispatchQueue.main.async {
                self.updateInfo = UpdateInfo(
                    latestVersion: cleanTag, currentVersion: self.currentVersion,
                    hasUpdate: hasUpdate, releaseName: name, releaseUrl: htmlUrl,
                    releaseNotes: body, tag: tag, dmgUrl: dmgUrl
                )
                if manual {
                    self.updateCheckMessage = hasUpdate ? "发现新版 v\(cleanTag)" : "当前已是最新版本"
                    self.checkingUpdates = false
                }
            }
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let r = self.compute()
            DispatchQueue.main.async {
                self.status = r.status; self.events = r.events
                self.trend = r.trend
                self.rangeLabel = r.range
                self.ageSeconds = r.age
                self.serviceAlive = (r.age >= 0 && r.age <= max(45, self.checkInterval * 3))
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
            s += "【当前状态】\n判定：\(publicText(st.verdict))（\(publicText(st.reason))）\n"
            s += "网关：\(st.gateway.ok == "true" ? "通" : "不通")  国内：\(st.domestic.ok ? "通(\(st.domestic.ms)ms)" : "断")"
            let app = st.proxy_app?.isEmpty == false ? st.proxy_app! : "未识别"
            let mode = st.proxy_mode?.isEmpty == false ? st.proxy_mode! : "none"
            s += "  代理软件：\(app)  通道：\(mode):\(st.proxy_port ?? 0)"
            if let px = st.proxy { s += "\n经代理：\(px.ok ? "通(\(px.ms)ms)" : "断")" }
            if let di = st.direct { s += "  直连：\(di.ok ? "通(\(di.ms)ms)" : "断")" }
            s += "\n\n"
        }
        if let txt = try? String(contentsOfFile: base + "/logs/events.jsonl", encoding: .utf8) {
            s += "【最近故障/恢复事件】\n"
            for line in txt.split(separator: "\n").suffix(30) {
                if let e = try? JSONDecoder().decode(Event.self, from: Data(String(line).utf8)) {
                    s += "\(shortTS(e.ts))  \(publicText(e.change))\n"
                }
            }
        }
        s += "\n============================================\n"
        return s
    }

    private func compute() -> (status: Status?, events: [Event], trend: [Int], range: String, age: Int, proxyLat: [Int], directLat: [Int], risk: SimpleRisk?) {
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
        var range = ""
        if let f = recent.first?.ts, let l = recent.last?.ts { range = "\(shortTS(f)) → \(shortTS(l))" }
        // Load risk data
        var risk: SimpleRisk? = nil
        if let rd = try? Data(contentsOf: URL(fileURLWithPath: base + "/风险评估.json")),
           let rd2 = try? JSONDecoder().decode(SimpleRisk.self, from: rd) {
            risk = rd2
        }
        return (status, events, trend, range, age, proxyLat, directLat, risk)
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
// 见林设计系统 v4 暖黄复古风（状态色保留功能性语义，但调暖）
let CL_BG = Color(red: 0.949, green: 0.933, blue: 0.874)        // #F2EEDF 暖纸底
let CL_CARD = Color.white.opacity(0.72)                          // 半透明白卡
let CL_CARD_SHADOW = Color(red: 0.165, green: 0.141, blue: 0.106).opacity(0.06)
let CL_PRIMARY = Color(red: 0.165, green: 0.141, blue: 0.106)   // #2A241B 墨黑
let CL_SECONDARY = Color(red: 0.361, green: 0.325, blue: 0.271) // #5C5345 深灰
let CL_TERTIARY = Color(red: 0.541, green: 0.510, blue: 0.463)  // #8A8275 灰棕
let CL_ACCENT = Color(red: 0.753, green: 0.325, blue: 0.180)    // #C0532E 朱砂红
let CL_GREEN = Color(red: 0.420, green: 0.478, blue: 0.227)     // #6B7A3A 暖橄榄=正常
let CL_ORANGE = Color(red: 0.729, green: 0.459, blue: 0.090)    // #BA7517 琥珀=警告
let CL_RED = Color(red: 0.753, green: 0.325, blue: 0.180)       // 朱砂红=故障
let CL_TRACK = Color(red: 0.890, green: 0.863, blue: 0.769)     // #E3DCC4 轨道

func verdictColor(_ v: String) -> Color { switch v { case "正常": return CL_GREEN; case "国外缓慢": return CL_ORANGE; case "读取中…": return CL_TERTIARY; default: return CL_RED } }
func verdictSymbol(_ v: String) -> String { switch v { case "正常": return "checkmark.shield.fill"; case "国外缓慢": return "exclamationmark.triangle.fill"; case "读取中…": return "hourglass"; default: return "exclamationmark.octagon.fill" } }
func verdictLabel(_ v: String) -> String {
    let clean = publicText(v)
    switch clean {
    case "正常": return "网络一切正常 👍"; case "国外缓慢": return "代理后网有点慢"; case "读取中…": return "正在检查..."
    case "本地网络断开": return "网线或 Wi-Fi 断了"; case "宽带/ISP故障": return "宽带/运营商出问题了"
    case "Surge 未运行": return "Surge 没开"; case "Surge 端口异常": return "Surge 设置有问题"; case "代理隧道异常": return "代理通道堵了"
    case "代理通道异常": return "代理通道堵了"
    case "代理软件未运行": return "代理软件没开"
    case "代理端口未开启": return "代理软件在跑，但端口没开"
    case "宽带/运营商异常": return "宽带/运营商出问题了"
    default: return clean
    }
}

func publicText(_ s: String) -> String {
    let oldProxyWord = "\u{7FFB}\u{5899}"
    let oldAppWord = "\u{68AF}\u{5B50}"
    let oldTunnelWord = "\u{7A7F}\u{5899}"
    let oldBlockedWord = "\u{88AB}\u{5899}"
    return s.replacingOccurrences(of: oldProxyWord, with: "代理")
     .replacingOccurrences(of: oldAppWord, with: "代理软件")
     .replacingOccurrences(of: oldTunnelWord, with: "代理")
     .replacingOccurrences(of: oldBlockedWord, with: "链路")
}

struct CardBackground: ViewModifier { func body(content: Content) -> some View { content.background(RoundedRectangle(cornerRadius: 16).fill(CL_CARD).shadow(color: CL_CARD_SHADOW, radius: 8, y: 3)) } }
extension View { var cardStyle: some View { modifier(CardBackground()) } }

// MARK: - 更新检查
struct UpdateInfo {
    var latestVersion: String; var currentVersion: String; var hasUpdate: Bool
    var releaseName: String; var releaseUrl: String; var releaseNotes: String; var tag: String
    var dmgUrl: String = ""
}

extension Notification.Name {
    static let netWatchCheckIntervalChanged = Notification.Name("netWatchCheckIntervalChanged")
}

extension URLSession {
    func synchronousData(for request: URLRequest) -> Data? {
        var result: Data?
        let semaphore = DispatchSemaphore(value: 0)
        let task = self.dataTask(with: request) { data, _, _ in
            result = data
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 15)
        return result
    }
}

// MARK: - 简化数据模型
struct SimpleRisk: Codable {
    var total_score: Int; var risk_level: String; var risk_emoji: String; var tspu_tier: String
    var signals_major: [String]; var signals_minor: [String]
    var proxy_ip: SimpleIP; var api_access: SimpleAPIs
    var proxy_info: SimpleProxyInfo?; var location_history: [SimpleLocHis]?; var location_changes_24h: Int?
    var source_ok: Int = 0; var source_total: Int = 5
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
        source_ok = try c.decodeIfPresent(Int.self, forKey: .source_ok) ?? 0
        source_total = try c.decodeIfPresent(Int.self, forKey: .source_total) ?? 5
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
    var name: String = ""; var running: Bool = false; var installed: Bool = false; var is_active: Bool = false; var http_port: Int = 0; var socks_port: Int = 0
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""; running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false; is_active = try c.decodeIfPresent(Bool.self, forKey: .is_active) ?? false
        http_port = try c.decodeIfPresent(Int.self, forKey: .http_port) ?? 0
        socks_port = try c.decodeIfPresent(Int.self, forKey: .socks_port) ?? 0
    }
}
struct SimpleProxyInfo: Codable {
    var active_app: String = ""; var active_mode: String = ""; var active_port: Int = 0; var sys_proxy_on: Bool = false; var apps: [SimpleProxyApp] = []
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        active_app = try c.decodeIfPresent(String.self, forKey: .active_app) ?? ""
        active_mode = try c.decodeIfPresent(String.self, forKey: .active_mode) ?? ""
        active_port = try c.decodeIfPresent(Int.self, forKey: .active_port) ?? 0
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

// ===================================================================
// 见林风界面层 v5.3 —— 菜单栏常驻 + 折叠分页小窗（重写自旧的窗口式 UI）
// 数据层（Monitor / 各 struct / 颜色 / helper）保留在本文件上半部分
// ===================================================================

let APP_VERSION: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "5.3"
let KAI = "STKaiti"

func kai(_ t: String, _ size: CGFloat) -> Text { Text(t).font(.custom(KAI, size: size)) }

func scoreColor(_ s: Int) -> Color { if s >= 85 { return CL_GREEN }; if s >= 70 { return CL_GREEN.opacity(0.85) }; if s >= 50 { return CL_ORANGE }; return CL_RED }

func verdictNSColor(_ v: String) -> NSColor {
    switch publicText(v) {
    case "正常": return NSColor(red: 0.420, green: 0.478, blue: 0.227, alpha: 1)   // 暖橄榄
    case "国外缓慢": return NSColor(red: 0.729, green: 0.459, blue: 0.090, alpha: 1) // 琥珀
    case "读取中…": return NSColor(red: 0.541, green: 0.510, blue: 0.463, alpha: 1)  // 灰棕
    default: return NSColor(red: 0.753, green: 0.325, blue: 0.180, alpha: 1)        // 朱砂红
    }
}

func shortVerdict(_ v: String) -> String {
    switch publicText(v) {
    case "正常": return "正常"; case "读取中…": return "…"; case "国外缓慢": return "偏慢"
    default: return "异常"
    }
}

extension Monitor {
    // 手动触发一次账号安全体检（用户在「安全」页点按钮时）
    func runRiskCheck(completion: (() -> Void)? = nil) {
        // 防并发：上一次体检还在跑就不再起新进程（切 Tab 回来误点也不会叠两个 risk_check.sh）
        guard !riskChecking else { completion?(); return }
        riskChecking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [self.base + "/risk_check.sh"]
            try? p.run(); p.waitUntilExit()
            self.loadRiskData()
            DispatchQueue.main.async {
                self.riskChecking = false
                completion?()
            }
        }
    }
}

// MARK: - 通用小组件
struct TabButton: View {
    let title: String; let idx: Int; @Binding var sel: Int
    var body: some View {
        Button(action: { sel = idx }) {
            VStack(spacing: 4) {
                Text(title).font(.custom(KAI, size: 14)).foregroundColor(sel == idx ? CL_ACCENT : CL_TERTIARY)
                Rectangle().fill(sel == idx ? CL_ACCENT : Color.clear).frame(width: 22, height: 2)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain)
    }
}

struct CheckRow: View {
    let name: String; let ok: Bool; let detail: String
    var body: some View {
        HStack {
            Text(name).font(.system(size: 13)).foregroundColor(CL_SECONDARY)
            Spacer()
            Text(detail).font(.system(size: 12)).foregroundColor(ok ? CL_GREEN : CL_RED)
        }
        .padding(.vertical, 6)
        .overlay(Rectangle().fill(CL_TERTIARY.opacity(0.22)).frame(height: 0.5), alignment: .bottom)
    }
}

struct RingView: View {
    let frac: Double; let color: Color; let big: String; let small: String
    var body: some View {
        ZStack {
            Circle().stroke(CL_TRACK, lineWidth: 7).frame(width: 84, height: 84)
            Circle().trim(from: 0, to: max(0.02, min(1, frac)))
                .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 84, height: 84)
            VStack(spacing: 1) {
                Text(big).font(.custom(KAI, size: 19)).foregroundColor(CL_PRIMARY)
                Text(small).font(.system(size: 9)).foregroundColor(CL_TERTIARY)
            }
        }
    }
}

// MARK: - 网络页
struct NetworkPage: View {
    @ObservedObject var m: Monitor
    func proxyRunning() -> Bool {
        if m.status?.surge?.running == true { return true }
        if m.status?.proxy_listen == true { return true }
        if let a = m.status?.proxy_app, !a.isEmpty, a != "未识别" { return true }
        if let a = m.simpleRisk?.proxy_info?.active_app, !a.isEmpty { return true }
        return false
    }
    func activeApp() -> String {
        if let a = m.status?.proxy_app, !a.isEmpty, a != "未识别" {
            let mode = m.status?.proxy_mode ?? ""
            let port = m.status?.proxy_port ?? 0
            return port > 0 ? "\(a) \(mode):\(port)" : a
        }
        let a = m.simpleRisk?.proxy_info?.active_app ?? ""
        return a.isEmpty ? "在跑" : a
    }
    func aiOK() -> Bool {
        // 通道断了 AI 必然连不上；安全体检数据可能是十分钟前的旧值，不能据此报“可访问”
        guard m.status?.foreign.ok == true else { return false }
        if let api = m.simpleRisk?.api_access, !api.openai.status.isEmpty {
            return api.openai.status == "可访问" || api.anthropic.status == "可访问" || api.google.status == "可访问"
        }
        return true
    }
    var body: some View {
        let st = m.status
        let v = st?.verdict ?? "读取中…"
        let ms = (st?.proxy?.ms ?? st?.foreign.ms) ?? -1
        return VStack(spacing: 14) {
            RingView(frac: v == "正常" ? 0.92 : (v == "读取中…" ? 0.15 : 0.5),
                     color: verdictColor(v), big: shortVerdict(v), small: ms > 0 ? "\(ms)ms" : "—")
            Text(verdictLabel(v)).font(.custom(KAI, size: 18)).foregroundColor(CL_PRIMARY)
                .multilineTextAlignment(.center)
            VStack(spacing: 0) {
                CheckRow(name: "路由器", ok: st?.gateway.ok == "true", detail: st?.gateway.ok == "true" ? "✓ 通" : "✕ 不通")
                CheckRow(name: "国内网站", ok: st?.domestic.ok ?? false, detail: (st?.domestic.ok ?? false) ? "✓ 通" : "✕ 断")
                CheckRow(name: "代理软件", ok: proxyRunning(), detail: proxyRunning() ? "✓ \(activeApp())" : "✕ 没开")
                CheckRow(name: "代理通道", ok: st?.foreign.ok ?? false, detail: (st?.foreign.ok ?? false) ? "✓ 通" : "✕ 断")
                CheckRow(name: "AI 服务", ok: aiOK(), detail: aiOK() ? "✓ 可访问" : "✕ 受阻")
            }
            HStack(spacing: 5) {
                Circle().fill(m.serviceAlive ? CL_GREEN : CL_RED).frame(width: 6, height: 6)
                Text(m.serviceAlive ? "自动监测中 · \(m.ageSeconds)s 前" : "监测可能停了").font(.system(size: 10)).foregroundColor(CL_TERTIARY)
            }
        }
    }
}

// MARK: - 安全页
struct SecurityPage: View {
    @ObservedObject var m: Monitor
    // 不再用本地 @State running：切 Tab 会销毁本视图丢失状态，改读 Monitor.riskChecking（切 Tab 不丢 + 防并发）
    var body: some View {
        Group {
            if let r = m.simpleRisk, !r.risk_level.isEmpty {
                VStack(spacing: 12) {
                    RingView(frac: Double(r.total_score) / 100.0, color: scoreColor(r.total_score),
                             big: r.total_score > 0 ? "\(r.total_score)" : "—", small: r.risk_level)
                    VStack(spacing: 0) {
                        let loc = "\(r.proxy_ip.city) \(r.proxy_ip.code)".trimmingCharacters(in: .whitespaces)
                        CheckRow(name: "当前出口", ok: !r.proxy_ip.ip.isEmpty, detail: loc.isEmpty ? "未拿到" : loc)
                        CheckRow(name: "被风控概率", ok: r.total_score >= 70, detail: r.total_score > 0 ? "\(100 - r.total_score)/100" : "—")
                        CheckRow(name: "ChatGPT", ok: r.api_access.openai.status == "可访问", detail: r.api_access.openai.status.isEmpty ? "—" : r.api_access.openai.status)
                        CheckRow(name: "Claude", ok: r.api_access.anthropic.status == "可访问", detail: r.api_access.anthropic.status.isEmpty ? "—" : r.api_access.anthropic.status)
                        CheckRow(name: "数据源交叉", ok: r.source_ok >= 3, detail: "\(r.source_ok) / \(r.source_total)")
                    }
                    Text("不做确定承诺，只帮你少瞎猜、多个判断依据。")
                        .font(.system(size: 11)).foregroundColor(CL_TERTIARY)
                        .multilineTextAlignment(.center).padding(8)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.5)))
                    Button(action: { m.runRiskCheck() }) {
                        Text(m.riskChecking ? "正在重新体检…" : "重新体检").font(.system(size: 12)).foregroundColor(CL_ACCENT)
                    }.buttonStyle(.plain).disabled(m.riskChecking)
                }
            } else {
                VStack(spacing: 12) {
                    kai("还没做账号体检", 16).foregroundColor(CL_PRIMARY)
                    Text("用 5 个数据源交叉看看\n你的代理 IP 风险").font(.system(size: 12)).foregroundColor(CL_SECONDARY).multilineTextAlignment(.center)
                    Button(action: { m.runRiskCheck() }) {
                        Text(m.riskChecking ? "体检中…（约 10 秒）" : "做一次体检")
                            .font(.system(size: 13)).foregroundColor(.white)
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(CL_ACCENT))
                    }.buttonStyle(.plain).disabled(m.riskChecking)
                }.padding(.top, 24)
            }
        }
    }
}

// MARK: - 历史页
struct HistoryPage: View {
    @ObservedObject var m: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let hist = m.simpleRisk?.location_history, !hist.isEmpty {
                kai("代理出口变化", 14).foregroundColor(CL_PRIMARY)
                ForEach(Array(hist.suffix(5).reversed().enumerated()), id: \.offset) { _, h in
                    HStack {
                        Circle().fill(h.changed ? CL_ORANGE : CL_GREEN).frame(width: 6, height: 6)
                        Text(h.location.isEmpty ? h.ip : h.location).font(.system(size: 12)).foregroundColor(CL_SECONDARY)
                        Spacer()
                        Text("\(h.score)").font(.system(size: 11)).foregroundColor(CL_TERTIARY)
                    }
                }
                Rectangle().fill(CL_TERTIARY.opacity(0.25)).frame(height: 0.5).padding(.vertical, 4)
            }
            kai("最近事件", 14).foregroundColor(CL_PRIMARY)
            if m.events.isEmpty {
                Text("暂无事件，一切平稳").font(.system(size: 12)).foregroundColor(CL_TERTIARY)
            } else {
                ForEach(Array(m.events.prefix(7).enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .top, spacing: 6) {
                        Text("·").foregroundColor(CL_ACCENT)
                        Text(verdictLabel(e.change)).font(.system(size: 12)).foregroundColor(CL_SECONDARY)
                        Spacer()
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FrequencyControl: View {
    @ObservedObject var m: Monitor
    let options = [15, 30, 60]
    func label(_ v: Int) -> String { v == 60 ? "1 分钟" : "\(v) 秒" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("监测频率").font(.system(size: 12)).foregroundColor(CL_SECONDARY)
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { v in
                    Button(action: { m.setCheckInterval(v) }) {
                        Text(label(v))
                            .font(.system(size: 12, weight: m.checkInterval == v ? .semibold : .regular))
                            .foregroundColor(m.checkInterval == v ? .white : CL_ACCENT)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(m.checkInterval == v ? CL_ACCENT : Color.white.opacity(0.55)))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.38)))
    }
}

// MARK: - 关于页
struct AboutPage: View {
    @ObservedObject var m: Monitor
    func aboutBtn(_ t: String, _ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).foregroundColor(CL_ACCENT).frame(width: 16)
                Text(t).font(.system(size: 13)).foregroundColor(CL_PRIMARY)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.5)))
        }.buttonStyle(.plain)
    }
    var body: some View {
        VStack(spacing: 12) {
            kai("网络体检", 20).foregroundColor(CL_PRIMARY)
            Text("v\(APP_VERSION) · 见林OS").font(.system(size: 11)).foregroundColor(CL_TERTIARY)
            Text("按你选的频率自动体检，断了告诉你哪坏了；\n还能看代理 IP 的封号风险。")
                .font(.system(size: 12)).foregroundColor(CL_SECONDARY).multilineTextAlignment(.center)
            VStack(spacing: 8) {
                aboutBtn("复制体检报告给 AI", "doc.on.doc") {
                    let s = m.diagnosticReport()
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
                }
                aboutBtn(m.checkingUpdates ? "正在检查更新" : "检查更新", "arrow.triangle.2.circlepath") { m.checkForUpdates(manual: true) }
                    .disabled(m.checkingUpdates)
                aboutBtn("打开 GitHub", "link") { if let u = URL(string: "https://github.com/julyyy-666/NetWatch") { NSWorkspace.shared.open(u) } }
                aboutBtn("退出 NetWatch", "power") { NSApp.terminate(nil) }
            }
            if !m.updateCheckMessage.isEmpty {
                Text(m.updateCheckMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(m.updateCheckMessage.contains("失败") ? CL_RED : CL_GREEN)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.45)))
            }
            FrequencyControl(m: m)
        }
    }
}

// MARK: - 更新横幅（下载现成 .dmg 并自动替换当前 App）
struct UpdateBanner: View {
    let info: UpdateInfo
    @State private var downloading = false
    @State private var done = false
    @State private var errorMsg = ""
    var body: some View {
        Button(action: { autoUpdate() }) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundColor(.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text(done ? "正在替换并重启…" : (downloading ? "下载中…" : "发现新版 v\(info.latestVersion)"))
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    if !errorMsg.isEmpty {
                        Text(errorMsg).font(.system(size: 10)).foregroundColor(.white.opacity(0.9))
                    } else if !done && !downloading {
                        Text("点这里自动更新").font(.system(size: 10)).foregroundColor(.white.opacity(0.85))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(CL_ACCENT))
        }.buttonStyle(.plain)
    }
    func autoUpdate() {
        guard !downloading && !done else { return }
        downloading = true
        errorMsg = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let dmg = info.dmgUrl
            let page = info.releaseUrl
            if dmg.isEmpty {
                DispatchQueue.main.async {
                    errorMsg = "没有找到安装包，已打开发布页"
                    if let u = URL(string: page) { NSWorkspace.shared.open(u) }
                    downloading = false
                }
                return
            }
            guard let u = URL(string: dmg), let d = try? Data(contentsOf: u) else {
                DispatchQueue.main.async {
                    errorMsg = "下载失败，已打开发布页"
                    if let p = URL(string: page) { NSWorkspace.shared.open(p) }
                    downloading = false
                }
                return
            }
            let fm = FileManager.default
            let home = NSHomeDirectory()
            let appPath = Bundle.main.bundlePath
            let support = home + "/Library/Application Support/NetWatch"
            let updateDir = NSTemporaryDirectory() + "NetWatchUpdate-\(UUID().uuidString)"
            let dmgPath = updateDir + "/NetWatch-v\(info.latestVersion).dmg"
            let mountPath = updateDir + "/mnt"
            try? fm.createDirectory(atPath: updateDir, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: dmgPath))
            try? fm.createDirectory(atPath: support + "/logs", withIntermediateDirectories: true)
            let helper = support + "/update_helper.sh"
            let script = """
            #!/bin/bash
            set -u
            LOG="\(support)/logs/update.log"
            DMG="\(dmgPath)"
            MOUNT="\(mountPath)"
            APP="\(appPath)"
            APP_DIR="$(dirname "$APP")"
            APP_NAME="$(basename "$APP")"
            TMP_APP="$APP_DIR/.${APP_NAME}.updating.$$"
            OLD_APP="$APP_DIR/.${APP_NAME}.old.$$"
            echo "=== NetWatch update $(date) ===" > "$LOG"
            mkdir -p "$MOUNT"
            if ! hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >> "$LOG" 2>&1; then
              echo "ERROR: mount failed" >> "$LOG"
              exit 1
            fi
            SRC="$(find "$MOUNT" -maxdepth 1 -name "*.app" -type d | head -n 1)"
            if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
              echo "ERROR: app not found in dmg" >> "$LOG"
              hdiutil detach "$MOUNT" >> "$LOG" 2>&1 || true
              exit 1
            fi
            for i in 1 2 3 4 5 6 7 8 9 10; do
              if ! pgrep -f "$APP/Contents/MacOS/NetWatch" >/dev/null 2>&1; then break; fi
              echo "waiting old app $i" >> "$LOG"
              sleep 1
            done
            rm -rf "$TMP_APP" "$OLD_APP" >> "$LOG" 2>&1 || true
            if ! cp -R "$SRC" "$TMP_APP" >> "$LOG" 2>&1; then
              echo "ERROR: copy to temp app failed" >> "$LOG"
              hdiutil detach "$MOUNT" >> "$LOG" 2>&1 || true
              exit 1
            fi
            xattr -cr "$TMP_APP" >> "$LOG" 2>&1 || true
            if [ ! -x "$TMP_APP/Contents/MacOS/NetWatch" ]; then
              echo "ERROR: new app executable missing" >> "$LOG"
              rm -rf "$TMP_APP" >> "$LOG" 2>&1 || true
              hdiutil detach "$MOUNT" >> "$LOG" 2>&1 || true
              exit 1
            fi
            if ! codesign --verify --deep --strict "$TMP_APP" >> "$LOG" 2>&1; then
              echo "ERROR: new app signature check failed" >> "$LOG"
              rm -rf "$TMP_APP" >> "$LOG" 2>&1 || true
              hdiutil detach "$MOUNT" >> "$LOG" 2>&1 || true
              exit 1
            fi
            if [ -e "$APP" ]; then
              if ! mv "$APP" "$OLD_APP" >> "$LOG" 2>&1; then
                echo "ERROR: cannot move old app, check write permission" >> "$LOG"
                rm -rf "$TMP_APP" >> "$LOG" 2>&1 || true
                hdiutil detach "$MOUNT" >> "$LOG" 2>&1 || true
                exit 1
              fi
            fi
            if ! mv "$TMP_APP" "$APP" >> "$LOG" 2>&1; then
              echo "ERROR: cannot install new app, restoring old app" >> "$LOG"
              [ -e "$OLD_APP" ] && mv "$OLD_APP" "$APP" >> "$LOG" 2>&1 || true
              rm -rf "$TMP_APP" >> "$LOG" 2>&1 || true
              hdiutil detach "$MOUNT" >> "$LOG" 2>&1 || true
              exit 1
            fi
            rm -rf "$OLD_APP" >> "$LOG" 2>&1 || true
            hdiutil detach "$MOUNT" >> "$LOG" 2>&1 || true
            rm -rf "\(updateDir)" >> "$LOG" 2>&1 || true
            open "$APP"
            echo "=== done ===" >> "$LOG"
            """
            try? script.write(toFile: helper, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
            launcher.arguments = ["-c", "nohup /bin/bash '\(helper)' >/dev/null 2>&1 &"]
            try? launcher.run()
            DispatchQueue.main.async {
                done = true
                downloading = false
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - 根视图（小窗）
struct RootView: View {
    @ObservedObject var m: Monitor
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(CL_ACCENT).frame(width: 8, height: 8)
                kai("网络体检", 17).foregroundColor(CL_PRIMARY)
                Spacer()
                Button(action: { m.refresh() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundColor(CL_TERTIARY)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            if let u = m.updateInfo, u.hasUpdate {
                UpdateBanner(info: u).padding(.horizontal, 12).padding(.bottom, 8)
            }

            HStack(spacing: 0) {
                TabButton(title: "网络", idx: 0, sel: $tab)
                TabButton(title: "安全", idx: 1, sel: $tab)
                TabButton(title: "历史", idx: 2, sel: $tab)
                TabButton(title: "关于", idx: 3, sel: $tab)
            }
            Rectangle().fill(CL_TERTIARY.opacity(0.22)).frame(height: 0.5)

            ScrollView {
                Group {
                    if tab == 0 { NetworkPage(m: m) }
                    else if tab == 1 { SecurityPage(m: m) }
                    else if tab == 2 { HistoryPage(m: m) }
                    else { AboutPage(m: m) }
                }.padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(tab)   // 切 Tab 时重建 ScrollView，避免上一页的滚动位置残留导致新页首屏被滚走

            Rectangle().fill(CL_TERTIARY.opacity(0.22)).frame(height: 0.5)
            HStack {
                kai("少瞎猜 · 多依据", 11).foregroundColor(CL_ACCENT)
                Spacer()
                Text("@见林 · v\(APP_VERSION)").font(.system(size: 10)).foregroundColor(CL_TERTIARY)
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 360, height: 500)
        .background(CL_BG)
    }
}

// MARK: - 菜单栏控制器
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var cancellable: AnyCancellable?
    var intervalObserver: NSObjectProtocol?
    private let backendQueue = DispatchQueue(label: "com.jianlin.netwatch.backend")

    func applicationDidFinishLaunching(_ n: Notification) {
        // 后台铺设：provisionBackend 内含 launchctl + 跑脚本的同步阻塞，放主线程会拖慢启动、菜单栏图标迟出
        backendQueue.async { self.provisionBackend() }
        monitor.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(togglePopover(_:))
        }
        updateStatusButton()

        popover.contentSize = NSSize(width: 360, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: RootView(m: monitor))

        cancellable = monitor.$status.combineLatest(monitor.$serviceAlive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateStatusButton()
            }
        intervalObserver = NotificationCenter.default.addObserver(forName: .netWatchCheckIntervalChanged, object: nil, queue: .main) { [weak self] note in
            let seconds = (note.object as? Int) ?? Monitor.savedCheckIntervalSeconds()
            self?.applyCheckInterval(seconds)
        }
    }

    func updateStatusButton() {
        guard let b = statusItem?.button else { return }
        let v = monitor.status?.verdict ?? "读取中…"
        let ms = (monitor.status?.proxy?.ms ?? monitor.status?.foreign.ms) ?? -1
        // 只用一个紧凑图标（不带 "42ms" 文字）——刘海 Mac 菜单栏空间紧张时，越窄越不容易被系统挤掉/藏到刘海后面。
        // 状态仍用颜色表达（绿/琥珀/红），延迟看弹窗或鼠标悬停的 tooltip。
        b.attributedTitle = NSAttributedString(string: "")
        b.title = ""
        b.imagePosition = .imageOnly
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let img = NSImage(systemSymbolName: "wifi", accessibilityDescription: "网络体检")?.withSymbolConfiguration(cfg)
        img?.isTemplate = true
        b.image = img
        b.contentTintColor = verdictNSColor(v)
        b.toolTip = "网络体检 · " + publicText(v) + (ms > 0 ? " · \(ms)ms" : "")
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let b = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // 首次启动 / 升级：把打包进 App 的后台脚本铺到 Application Support，按当前用户路径生成并加载 LaunchAgent。
    func provisionBackend() {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let appSup = home + "/Library/Application Support/NetWatch"
        let logs = appSup + "/logs"
        try? fm.createDirectory(atPath: logs, withIntermediateDirectories: true)
        guard let resURL = Bundle.main.resourceURL else { return }
        let backend = resURL.appendingPathComponent("backend")
        let scripts = ["netwatch.sh", "risk_check.sh", "proxy_detect.sh"]
        let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let stampPath = appSup + "/.installed_version"
        let installedVer = (try? String(contentsOfFile: stampPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let refresh = installedVer != appVer
        var copiedAny = false
        for s in scripts {
            let src = backend.appendingPathComponent(s).path
            let dst = appSup + "/" + s
            if refresh || !fm.fileExists(atPath: dst) {
                guard fm.fileExists(atPath: src) else { continue }
                try? fm.removeItem(atPath: dst)
                try? fm.copyItem(atPath: src, toPath: dst)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst)
                copiedAny = true
            }
        }
        let interval = Monitor.savedCheckIntervalSeconds()
        try? "\(interval)".write(toFile: appSup + "/.check_interval", atomically: true, encoding: .utf8)
        installLaunchAgent(label: "com.jianlin.netwatch", script: "netwatch.sh", interval: interval, appSup: appSup, home: home, refresh: refresh)
        installLaunchAgent(label: "com.jianlin.netwatch.risk", script: "risk_check.sh", interval: 600, appSup: appSup, home: home, refresh: refresh)
        if refresh { try? appVer.write(toFile: stampPath, atomically: true, encoding: .utf8) }
        if copiedAny || refresh { runOnce(appSup + "/netwatch.sh"); runOnce(appSup + "/risk_check.sh") }
    }

    func applyCheckInterval(_ seconds: Int) {
        let home = NSHomeDirectory()
        let appSup = home + "/Library/Application Support/NetWatch"
        // 后台串行执行：避免启动铺设和用户切频率同时写 plist / launchctl
        backendQueue.async {
            self.installLaunchAgent(label: "com.jianlin.netwatch", script: "netwatch.sh", interval: seconds, appSup: appSup, home: home, refresh: true)
            self.runOnce(appSup + "/netwatch.sh")
        }
    }

    func installLaunchAgent(label: String, script: String, interval: Int, appSup: String, home: String, refresh: Bool) {
        let fm = FileManager.default
        let laDir = home + "/Library/LaunchAgents"
        try? fm.createDirectory(atPath: laDir, withIntermediateDirectories: true)
        let plistPath = laDir + "/" + label + ".plist"
        if !refresh && fm.fileExists(atPath: plistPath) { return }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>/bin/bash</string><string>\(appSup)/\(script)</string></array>
          <key>StartInterval</key><integer>\(interval)</integer>
          <key>RunAtLoad</key><true/>
          <key>StandardOutPath</key><string>\(appSup)/logs/launchd.out.log</string>
          <key>StandardErrorPath</key><string>\(appSup)/logs/launchd.err.log</string>
          <key>ProcessType</key><string>Background</string>
          <key>LowPriorityIO</key><true/>
        </dict></plist>
        """
        try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        let unload = Process(); unload.executableURL = URL(fileURLWithPath: "/bin/launchctl"); unload.arguments = ["unload", plistPath]
        try? unload.run(); unload.waitUntilExit()
        let load = Process(); load.executableURL = URL(fileURLWithPath: "/bin/launchctl"); load.arguments = ["load", "-w", plistPath]
        try? load.run(); load.waitUntilExit()
    }

    func runOnce(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [path]
        try? p.run()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
