#!/bin/bash
# NetWatch · 账号安全体检（免外部依赖）
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LANG=en_US.UTF-8

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/风险评估.json"
TS="$(date +%Y-%m-%dT%H:%M:%S%z)"
LOCKDIR="$DIR/.risk_check.lock"
LOCK_MAX_AGE=180

cleanup_lock() {
  rmdir "$LOCKDIR" 2>/dev/null || true
}

if ! mkdir "$LOCKDIR" 2>/dev/null; then
  lock_ts="$(stat -f %m "$LOCKDIR" 2>/dev/null || echo 0)"
  now_ts="$(date +%s)"
  if [ "${lock_ts:-0}" -gt 0 ] && [ $((now_ts - lock_ts)) -gt "$LOCK_MAX_AGE" ]; then
    rmdir "$LOCKDIR" 2>/dev/null || true
    mkdir "$LOCKDIR" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap cleanup_lock EXIT INT TERM

json_escape() {
  awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\r/,"\\r"); gsub(/\t/,"\\t"); if (NR>1) printf "\\n"; printf "%s",$0}'
}

jstr() { printf '"%s"' "$(printf "%s" "$1" | json_escape)"; }

json_get_string() {
  printf "%s" "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" | head -n 1
}

extract_query_ip() {
  sed -n 's/.*"query":"\([^"]*\)".*/\1/p' | head -n 1
}

write_error() {
  local message="$1" proxy_info="${2:-{}}"
  local tmp="$OUT.$$"
  cat > "$tmp" <<EOF
{
  "ts": "$TS",
  "total_score": 0,
  "risk_level": "无法检测",
  "risk_emoji": "⚪",
  "risk_tier": "$message",
  "signals_major": ["$message"],
  "signals_minor": [],
  "source_ok": 0,
  "source_total": 5,
  "proxy_ip": {"ip":"","country":"","code":"","city":"","isp":"","asn":"","company_type":"","company_name":"","is_dc":false,"is_vpn":false,"is_proxy":false,"is_tor":false,"is_abuser":false,"hosting":false,"mobile":false},
  "direct_ip": {"ip":"","country":"","code":"","city":"","isp":"","asn":""},
  "api_access": {
    "openai": {"code":"000","status":"不可达"},
    "anthropic": {"code":"000","status":"不可达"},
    "google": {"code":"000","status":"不可达"}
  },
  "proxy_info": $proxy_info,
  "location_history": [],
  "location_changes_24h": 0,
  "unique_locations": []
}
EOF
  mv "$tmp" "$OUT" 2>/dev/null || true
}

PROXY_INFO="$(bash "$DIR/proxy_detect.sh" 2>/dev/null || echo '{}')"
PROXY_URL="$(json_get_string "$PROXY_INFO" proxy_url)"
PROXY_APP="$(json_get_string "$PROXY_INFO" active_app)"

if [ -z "$PROXY_URL" ]; then
  if [ -n "$PROXY_APP" ]; then
    write_error "$PROXY_APP 已识别，但没有检测到本地代理端口；如使用 TUN/增强模式，请开启系统代理或本地 HTTP/SOCKS 端口" "$PROXY_INFO"
  else
    write_error "没有检测到可用代理，先打开代理软件并开启系统代理" "$PROXY_INFO"
  fi
  exit 0
fi

DIRECT_BASIC="$(curl -s -m 6 "http://ip-api.com/json/?fields=query" 2>/dev/null)"
PROXY_BASIC="$(curl -s -m 8 -x "$PROXY_URL" "http://ip-api.com/json/?fields=query" 2>/dev/null)"
DIRECT_IP="$(printf "%s" "$DIRECT_BASIC" | extract_query_ip)"
PROXY_IP="$(printf "%s" "$PROXY_BASIC" | extract_query_ip)"

if [ -z "$PROXY_IP" ]; then
  write_error "代理出口 IP 获取失败，代理软件可能开着但节点不可用" "$PROXY_INFO"
  exit 0
fi

SRC1="$(curl -s -m 8 -x "$PROXY_URL" "http://ip-api.com/json/$PROXY_IP?fields=status,country,countryCode,city,isp,org,as,asname,proxy,hosting,mobile,query" 2>/dev/null)"
SRC2="$(curl -s -m 8 -x "$PROXY_URL" "https://api.ipapi.is/?q=$PROXY_IP" 2>/dev/null)"
SRC3="$(curl -s -m 8 -x "$PROXY_URL" "https://internetdb.shodan.io/$PROXY_IP" 2>/dev/null)"
SRC4="$(curl -s -m 8 -x "$PROXY_URL" "https://api.stopforumspam.org/api?json&ip=$PROXY_IP" 2>/dev/null)"
SRC5="$(curl -s -m 8 -x "$PROXY_URL" "https://api.greynoise.io/v3/community/$PROXY_IP" 2>/dev/null)"
DIRECT_INFO="$(curl -s -m 8 "http://ip-api.com/json/$DIRECT_IP?fields=country,countryCode,city,isp,as" 2>/dev/null)"

test_api() {
  local url="$1"
  curl -s -m 10 -x "$PROXY_URL" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null
}

API_OPENAI="$(test_api "https://api.openai.com/v1/models")"
API_ANTHROPIC="$(test_api "https://api.anthropic.com/v1/messages")"
API_GOOGLE="$(test_api "https://generativelanguage.googleapis.com/")"

export TS OUT PROXY_INFO PROXY_IP DIRECT_IP DIRECT_INFO SRC1 SRC2 SRC3 SRC4 SRC5 API_OPENAI API_ANTHROPIC API_GOOGLE

osascript -l JavaScript <<'JXA'
ObjC.import('Foundation')

const env = $.NSProcessInfo.processInfo.environment
function getenv(k) {
  const v = env.objectForKey(k)
  return v ? ObjC.unwrap(v) : ""
}
function safeJson(s) {
  try { return JSON.parse(s || "{}") } catch (e) { return {} }
}
function jget(obj, path, fallback) {
  let cur = obj
  for (const key of path) {
    if (!cur || typeof cur !== "object" || !(key in cur)) return fallback
    cur = cur[key]
  }
  return cur === undefined || cur === null ? fallback : cur
}
function writeFile(path, text) {
  const ns = $.NSString.alloc.initWithUTF8String(text)
  ns.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)
}
function readFile(path) {
  const ns = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)
  return ns ? ObjC.unwrap(ns) : ""
}
function sourceGood(obj) {
  if (!obj || typeof obj !== "object") return false
  if (Object.keys(obj).length === 0) return false
  if (obj.error || obj.status === "fail") return false
  return true
}
function apiStatus(code) {
  // 无凭证裸探测：401/404/405/400/422 都说明网络层能通到服务，只是没鉴权——这不代表账号可用
  if (["401", "404", "405", "400", "422"].includes(code)) return "网络可达"
  if (code === "451") return "地区封锁"   // 唯一真正指向出口被封的信号
  if (code === "429") return "被限流"      // 速率限制，与账号封禁无关
  if (code === "403") return "疑似拦截"    // 多为 CDN 对无 UA/无 key 裸请求的通用拦截
  if (code === "000" || code === "") return "未确认"
  return "未知"
}

const ipapiCom = safeJson(getenv("SRC1"))
const ipapiIs = safeJson(getenv("SRC2"))
const shodan = safeJson(getenv("SRC3"))
const sfs = safeJson(getenv("SRC4"))
const greynoise = safeJson(getenv("SRC5"))
const direct = safeJson(getenv("DIRECT_INFO"))
const proxyInfo = safeJson(getenv("PROXY_INFO"))
const sources = [ipapiCom, ipapiIs, shodan, sfs, greynoise]
const sourceOk = sources.filter(sourceGood).length

let score = 100
const signalsMajor = []
const signalsMinor = []
function flagMajor(text, penalty) { signalsMajor.push(text); score -= penalty }
function flagMinor(text, penalty) { signalsMinor.push(text); score -= penalty }

if (sourceOk < 3) flagMajor(`只有 ${sourceOk}/5 个数据源返回，结果不够可靠`, 35)
else if (sourceOk < 5) flagMinor(`${sourceOk}/5 个数据源返回，建议稍后复查`, 5)

const comProxy = !!jget(ipapiCom, ["proxy"], false)
const comHosting = !!jget(ipapiCom, ["hosting"], false)
const comMobile = !!jget(ipapiCom, ["mobile"], false)

const isDc = !!jget(ipapiIs, ["is_datacenter"], false)
const isVpn = !!jget(ipapiIs, ["is_vpn"], false)
const isProxy2 = !!jget(ipapiIs, ["is_proxy"], false)
const isTor = !!jget(ipapiIs, ["is_tor"], false)
const isAbuser = !!jget(ipapiIs, ["is_abuser"], false)
const dcName = jget(ipapiIs, ["datacenter", "datacenter"], "")
const dcRegion = jget(ipapiIs, ["datacenter", "region"], "")
const compType = jget(ipapiIs, ["company", "type"], "")
const compName = jget(ipapiIs, ["company", "name"], "")
const abuserScore = jget(ipapiIs, ["company", "abuser_score"], "")

let vpnSources = 0
let proxySources = 0
let hostingSources = 0
if (comHosting) hostingSources += 1
if (isDc) hostingSources += 1
if (comProxy) proxySources += 1
if (isProxy2) proxySources += 1
if (isVpn) vpnSources += 1

if (isTor) flagMajor("ipapi.is 标记为 Tor 出口节点", 25)
if (vpnSources >= 2) flagMajor(`${vpnSources} 个源标记为 VPN`, 18)
else if (vpnSources === 1) flagMinor("1 个源标记 VPN，可能误报", 2)
if (proxySources >= 2) flagMajor(`${proxySources} 个源标记为代理`, 12)
else if (proxySources === 1) flagMinor("1 个源标记为代理", 2)
if (isDc && dcName) flagMajor(`数据中心 IP: ${dcName}${dcRegion ? " (" + dcRegion + ")" : ""}`, 30)
else if (comHosting) flagMajor("ip-api.com 标记为 hosting IP", 25)
if (isAbuser) flagMajor("ipapi.is 标记为滥用者", 20)
if (compType && !["isp", ""].includes(compType)) {
  if (["hosting", "cloud"].includes(compType)) flagMinor(`公司类型: ${compType}`, 5)
  else flagMinor(`公司类型异常: ${compType}`, 8)
}

const shodanPorts = jget(shodan, ["ports"], []) || []
const shodanTags = jget(shodan, ["tags"], []) || []
const shodanVulns = jget(shodan, ["vulns"], {}) || {}
const panelPorts = new Set([2053, 2083, 2087, 2096, 8443, 8880, 6443, 7443, 9443])
const vpnPorts = new Set([8388, 8488, 1080, 1081, 1194, 51820])
const panelHits = shodanPorts.filter(p => panelPorts.has(Number(p)))
const vpnHits = shodanPorts.filter(p => vpnPorts.has(Number(p)))
if (vpnHits.length) flagMajor(`暴露代理协议端口: ${JSON.stringify(vpnHits)}`, 15)
if (panelHits.length >= 2) flagMajor(`代理面板端口簇: ${JSON.stringify(panelHits)}`, 15)
else if (panelHits.length === 1) flagMinor(`疑似代理面板端口: ${JSON.stringify(panelHits)}`, 3)
if (shodanTags.includes("vpn")) flagMajor("Shodan 标记为 VPN", 10)
if (shodanTags.includes("proxy")) flagMinor("Shodan 标记为 proxy", 5)
const vulnCount = Array.isArray(shodanVulns) ? shodanVulns.length : Object.keys(shodanVulns).length
if (vulnCount >= 5) flagMinor(`Shodan 发现 ${vulnCount} 个已知漏洞`, 5)

const sfsAppears = String(jget(sfs, ["ip", "appears"], "0"))
const sfsFreq = String(jget(sfs, ["ip", "frequency"], "0"))
if (sfsAppears === "1") flagMajor(`StopForumSpam 黑名单 (出现 ${sfsFreq} 次)`, 15)

const gnNoise = !!jget(greynoise, ["noise"], false)
const gnRiot = !!jget(greynoise, ["riot"], false)
const gnClass = jget(greynoise, ["classification"], "")
const gnName = jget(greynoise, ["name"], "")
if (gnClass === "malicious") flagMajor(`GreyNoise 分类为恶意: ${gnName}`, 20)
else if (gnClass === "benign" || gnRiot) {
  score = Math.min(score + 10, 100)
  signalsMinor.push(`GreyNoise 已知安全 (${gnName})`)
}

const apiCodes = {
  openai: getenv("API_OPENAI") || "000",
  anthropic: getenv("API_ANTHROPIC") || "000",
  google: getenv("API_GOOGLE") || "000"
}
// API 探测只反映“这个出口 IP 的网络层能否触达 AI 服务”，不等于账号会不会被封。
// 因此只有 451（法律/地区封锁）作为较弱硬信号，429/403 不再重罚。
const apiResults = {}
for (const [name, code] of Object.entries(apiCodes)) {
  const status = apiStatus(code)
  if (status === "地区封锁") flagMajor(`${name} 在该出口被地区封锁 (${code})`, 15)
  else if (status === "疑似拦截") flagMinor(`${name} 裸连接被拦 (${code})，通常是无凭证探测所致，与账号无关`, 3)
  else if (status === "未确认") flagMinor(`${name} 本次未探测到`, 2)
  // 网络可达 / 被限流：不扣分（限流是正常速率控制）
  apiResults[name] = {code, status}
}

score = Math.max(0, Math.min(100, score))
let riskLevel = "高风险", riskEmoji = "🔴"
if (score >= 85) { riskLevel = "低风险"; riskEmoji = "🟢" }
else if (score >= 70) { riskLevel = "中低风险"; riskEmoji = "🟢" }
else if (score >= 50) { riskLevel = "中等风险"; riskEmoji = "🟡" }
else if (score >= 30) { riskLevel = "较高风险"; riskEmoji = "🟠" }

let riskTier = "信誉差 · 多个硬信号命中"
const aHits = signalsMajor.length
const bHits = signalsMinor.length
if (aHits === 0 && bHits === 0) riskTier = "干净 · 各源无异常"
else if (aHits === 0 && bHits < 3) riskTier = "较干净 · 少量软异常"
else if (aHits === 0) riskTier = "留意 · 软异常累积"
else if (aHits === 1) riskTier = "需关注 · 1 个硬信号"

const proxyIpInfo = {
  ip: getenv("PROXY_IP"),
  country: jget(ipapiCom, ["country"], ""),
  code: jget(ipapiCom, ["countryCode"], ""),
  city: jget(ipapiCom, ["city"], ""),
  isp: jget(ipapiCom, ["isp"], ""),
  asn: jget(ipapiCom, ["as"], ""),
  company_type: compType,
  company_name: compName,
  abuser_score: abuserScore,
  dc_name: dcName,
  dc_region: dcRegion,
  is_dc: isDc,
  is_vpn: isVpn,
  is_proxy: comProxy || isProxy2,
  is_tor: isTor,
  is_abuser: isAbuser,
  hosting: comHosting,
  mobile: comMobile
}
const directIpInfo = {
  ip: getenv("DIRECT_IP"),
  country: jget(direct, ["country"], ""),
  code: jget(direct, ["countryCode"], ""),
  city: jget(direct, ["city"], ""),
  isp: jget(direct, ["isp"], ""),
  asn: jget(direct, ["as"], "")
}
const reputation = {
  stopforumspam: {appears: sfsAppears === "1", frequency: Number(sfsFreq) || 0},
  greynoise: {noise: gnNoise, riot: gnRiot, classification: gnClass, name: gnName},
  vpn_sources: vpnSources,
  proxy_sources: proxySources,
  hosting_sources: hostingSources
}
const shodanInfo = {
  ports: shodanPorts.slice(0, 10),
  tags: shodanTags,
  vulns_count: vulnCount,
  cpes: (jget(shodan, ["cpes"], []) || []).slice(0, 5)
}

const historyFile = getenv("OUT").replace(/\/[^/]+$/, "") + "/代理位置历史.jsonl"
let history = []
const rawHistory = readFile(historyFile)
if (rawHistory) {
  history = rawHistory.split(/\n/).filter(Boolean).map(line => {
    try { return JSON.parse(line) } catch (e) { return null }
  }).filter(Boolean).slice(-49)
}
const currentLoc = `${proxyIpInfo.city} ${proxyIpInfo.code}`.trim()
const lastLoc = history.length ? (history[history.length - 1].location || "") : ""
const locChanged = !!currentLoc && currentLoc !== lastLoc
history.push({
  ts: getenv("TS"),
  ip: proxyIpInfo.ip,
  location: currentLoc,
  isp: proxyIpInfo.isp,
  score,
  proxy_app: proxyInfo.active_app || "",
  changed: locChanged
})
writeFile(historyFile, history.map(h => JSON.stringify(h)).join("\n") + "\n")

const uniqueLocations = [...new Set(history.map(h => h.location).filter(Boolean))]
const data = {
  ts: getenv("TS"),
  total_score: score,
  risk_level: riskLevel,
  risk_emoji: riskEmoji,
  risk_tier: riskTier,
  signals_major: signalsMajor,
  signals_minor: signalsMinor,
  a_hits: aHits,
  b_hits: bHits,
  source_ok: sourceOk,
  source_total: 5,
  proxy_ip: proxyIpInfo,
  direct_ip: directIpInfo,
  shodan: shodanInfo,
  reputation,
  api_access: apiResults,
  proxy_info: proxyInfo,
  location_history: history.slice(-20),
  location_changes_24h: history.filter(h => h.changed).length,
  unique_locations: uniqueLocations.slice(-10)
}
const text = JSON.stringify(data, null, 2)
writeFile(getenv("OUT"), text)
text
JXA
