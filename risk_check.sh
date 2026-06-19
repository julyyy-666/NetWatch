#!/bin/bash
# ============================================================
#  NetWatch v3 · API 封禁风险评估引擎 (Multi-Source Edition)
#
#  整合自 nitefood/asn + ByeByeVPN 的评分模型：
#  - 多源交叉验证（ip-api.com + ipapi.is + Shodan + StopForumSpam + GreyNoise）
#  - 100 分递减模型（major/minor signal 分层扣分）
#  - A/B 分层判决（硬签名 vs 软异常累积）
#
#  每 10 分钟由 launchd 调用
# ============================================================
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LANG=en_US.UTF-8

SURGE_HTTP_PORT=6152
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/风险评估.json"
TS="$(date +%Y-%m-%dT%H:%M:%S%z)"
PROXY="http://127.0.0.1:$SURGE_HTTP_PORT"

# ============================================================
# 阶段 1: 获取出口 IP
# ============================================================
DIRECT_IP=$(curl -s -m 8 "http://ip-api.com/json/?fields=query" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('query',''))" 2>/dev/null)
PROXY_IP=$(curl -s -m 8 -x "$PROXY" "http://ip-api.com/json/?fields=query" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('query',''))" 2>/dev/null)

[ -z "$PROXY_IP" ] && { echo '{"error":"无法获取代理IP"}' > "$OUT"; exit 1; }

# ============================================================
# 阶段 2: 多源数据采集（全部经代理查询代理出口 IP）
# ============================================================
# 源 1: ip-api.com (基础 GeoIP + hosting/proxy/mobile 标签)
SRC1=$(curl -s -m 8 -x "$PROXY" "http://ip-api.com/json/$PROXY_IP?fields=status,country,countryCode,city,isp,org,as,asname,proxy,hosting,mobile,query" 2>/dev/null)

# 源 2: ipapi.is (精确 DC 检测 + company type + abuser score)
SRC2=$(curl -s -m 8 -x "$PROXY" "https://api.ipapi.is/?q=$PROXY_IP" 2>/dev/null)

# 源 3: Shodan InternetDB (开放端口 / CPE / CVE / 标签)
SRC3=$(curl -s -m 8 -x "$PROXY" "https://internetdb.shodan.io/$PROXY_IP" 2>/dev/null)

# 源 4: StopForumSpam (黑名单)
SRC4=$(curl -s -m 8 -x "$PROXY" "https://api.stopforumspam.org/api?json&ip=$PROXY_IP" 2>/dev/null)

# 源 5: GreyNoise (噪音分类)
SRC5=$(curl -s -m 8 -x "$PROXY" "https://api.greynoise.io/v3/community/$PROXY_IP" 2>/dev/null)

# 直连 IP 基础信息
DIRECT_INFO=$(curl -s -m 8 "http://ip-api.com/json/$DIRECT_IP?fields=country,countryCode,city,isp,as" 2>/dev/null)

# ============================================================
# 阶段 3: API 可达性测试
# ============================================================
test_api() {
  local url="$1" code
  code=$(curl -s -m 10 -x "$PROXY" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
  echo "$code"
}
API_OPENAI=$(test_api "https://api.openai.com/v1/models")
API_ANTHROPIC=$(test_api "https://api.anthropic.com/v1/messages")
API_GOOGLE=$(test_api "https://generativelanguage.googleapis.com/")

api_status() {
  case "$1" in
    401|404|405|400|422) echo "accessible" ;;
    403|451|429) echo "blocked" ;;
    000) echo "unreachable" ;;
    *) echo "unknown" ;;
  esac
}

# ============================================================
# 阶段 4: 100 分递减评分引擎（学自 ByeByeVPN）
# ============================================================
# 所有解析交给 Python，Shell 只负责数据收集
export PROXY_IP DIRECT_IP DIRECT_INFO SRC1 SRC2 SRC3 SRC4 SRC5
export API_OPENAI API_ANTHROPIC API_GOOGLE TS OUT

python3 -c '
import json, os, re

def safe_json(s, default=None):
    try: return json.loads(s)
    except: return default if default is not None else {}

def jget(d, *keys, default=None):
    for k in keys:
        if isinstance(d, dict): d = d.get(k)
        else: return default
        if d is None: return default
    return d

# --- 解析各源 ---
ipapi_com = safe_json(os.environ.get("SRC1",""))
ipapi_is  = safe_json(os.environ.get("SRC2",""))
shodan    = safe_json(os.environ.get("SRC3",""))
sfs       = safe_json(os.environ.get("SRC4",""))
greynoise = safe_json(os.environ.get("SRC5",""))
direct    = safe_json(os.environ.get("DIRECT_INFO",""))

# --- 100 分递减引擎 ---
score = 100
signals_major = []
signals_minor = []

def flag_major(text, penalty):
    global score
    signals_major.append(text)
    score -= penalty

def flag_minor(text, penalty=3):
    global score
    signals_minor.append(text)
    score -= penalty

# --- 源 1: ip-api.com ---
com_proxy   = jget(ipapi_com, "proxy", default=False)
com_hosting = jget(ipapi_com, "hosting", default=False)
com_mobile  = jget(ipapi_com, "mobile", default=False)

# --- 源 2: ipapi.is ---
is_dc     = jget(ipapi_is, "is_datacenter", default=False)
is_vpn    = jget(ipapi_is, "is_vpn", default=False)
is_proxy2 = jget(ipapi_is, "is_proxy", default=False)
is_tor    = jget(ipapi_is, "is_tor", default=False)
is_abuser = jget(ipapi_is, "is_abuser", default=False)
dc_name   = jget(ipapi_is, "datacenter", "datacenter", default="")
dc_region = jget(ipapi_is, "datacenter", "region", default="")
comp_type = jget(ipapi_is, "company", "type", default="")
comp_name = jget(ipapi_is, "company", "name", default="")
abuser_score = jget(ipapi_is, "company", "abuser_score", default="")

# --- 多源 GeoIP 共识（学自 ByeByeVPN）---
vpn_sources = 0
proxy_sources = 0
hosting_sources = 0

if com_hosting: hosting_sources += 1
if is_dc: hosting_sources += 1
if com_proxy: proxy_sources += 1
if is_proxy2: proxy_sources += 1
if is_vpn: vpn_sources += 1

# Tor: 1 个源就足够（很少误报）
if is_tor:
    flag_major("ipapi.is 标记为 Tor 出口节点", 25)

# VPN: 需要 ≥2 个源共识
if vpn_sources >= 2:
    flag_major(f"{vpn_sources} 个源标记为 VPN（多源共识）", 18)
elif vpn_sources == 1:
    flag_minor("1 个源标记 VPN（单源，可能是误报）", 2)

# Proxy: 需要 ≥2 个源
if proxy_sources >= 2:
    flag_major(f"{proxy_sources} 个源标记为代理（多源共识）", 12)
elif proxy_sources == 1:
    flag_minor("1 个源标记为代理", 2)

# 数据中心 IP：精确 DC 检测
if is_dc and dc_name:
    flag_major(f"数据中心 IP: {dc_name}" + (f" ({dc_region})" if dc_region else ""), 30)
elif com_hosting:
    flag_major("ip-api.com 标记为 hosting IP", 25)

# abuser score
if is_abuser:
    flag_major("ipapi.is 标记为滥用者 (is_abuser=true)", 20)

# 公司类型
if comp_type and comp_type not in ("isp", ""):
    if comp_type in ("hosting", "cloud"):
        flag_minor(f"公司类型: {comp_type}", 5)
    else:
        flag_minor(f"公司类型异常: {comp_type}", 8)

# --- 源 3: Shodan 指纹分析 ---
shodan_ports = jget(shodan, "ports", default=[]) or []
shodan_tags  = jget(shodan, "tags", default=[]) or []
shodan_vulns = jget(shodan, "vulns", default=[]) or []
shodan_cpes  = jget(shodan, "cpes", default=[]) or []

# VPN 面板端口簇检测（学自 ByeByeVPN 的 3x-ui 端口簇检测）
PANEL_PORTS = {2053, 2083, 2087, 2096, 8443, 8880, 6443, 7443, 9443}
VPN_PORTS   = {8388, 8488, 1080, 1081, 1194, 51820}
panel_hits  = [p for p in shodan_ports if p in PANEL_PORTS]
vpn_port_hits = [p for p in shodan_ports if p in VPN_PORTS]

if vpn_port_hits:
    flag_major(f"暴露 VPN 协议端口: {vpn_port_hits}", 15)
if len(panel_hits) >= 2:
    flag_major(f"代理面板端口簇: {panel_hits}（可能是 3x-ui/x-ui）", 15)
elif len(panel_hits) == 1:
    flag_minor(f"疑似代理面板端口: {panel_hits}", 3)

# Shodan tags 含 vpn/proxy/tor
if "vpn" in shodan_tags:
    flag_major("Shodan 标记为 VPN", 10)
if "proxy" in shodan_tags:
    flag_minor("Shodan 标记为 proxy", 5)

# CVE 数量
if len(shodan_vulns) >= 5:
    flag_minor(f"Shodan 发现 {len(shodan_vulns)} 个已知漏洞", 5)

# --- 源 4: StopForumSpam ---
sfs_appears = jget(sfs, "ip", "appears", default="0")
sfs_freq    = jget(sfs, "ip", "frequency", default="0")
if str(sfs_appears) == "1":
    flag_major(f"StopForumSpam 黑名单 (出现 {sfs_freq} 次)", 15)

# --- 源 5: GreyNoise ---
gn_noise = jget(greynoise, "noise", default=False)
gn_riot  = jget(greynoise, "riot", default=False)
gn_class = jget(greynoise, "classification", default="")
gn_name  = jget(greynoise, "name", default="")

if gn_class == "malicious":
    flag_major(f"GreyNoise 分类为恶意: {gn_name}", 20)
elif gn_class == "benign" or gn_riot:
    # 已知安全 IP，可以抵消部分扣分
    score = min(score + 10, 100)
    signals_minor.append(f"GreyNoise 已知安全 ({gn_name})")

# --- API 可达性 ---
api_envs = {"openai": "API_OPENAI", "anthropic": "API_ANTHROPIC", "google": "API_GOOGLE"}
api_results = {}
for name, env in api_envs.items():
    code = os.environ.get(env, "000")
    if code in ("401","404","405","400","422"):
        status = "accessible"
    elif code in ("403","451","429"):
        status = "blocked"
        flag_major(f"{name} API 返回封禁信号 ({code})", 30)
    elif code == "000":
        status = "unreachable"
        flag_major(f"{name} API 完全不可达", 20)
    else:
        status = "unknown"
    api_results[name] = {"code": code, "status": status}

# --- 最终评分 ---
score = max(0, min(100, score))

# 风险分级
if score >= 85:
    risk_level, risk_emoji = "低风险", "🟢"
elif score >= 70:
    risk_level, risk_emoji = "中低风险", "🟢"
elif score >= 50:
    risk_level, risk_emoji = "中等风险", "🟡"
elif score >= 30:
    risk_level, risk_emoji = "较高风险", "🟠"
else:
    risk_level, risk_emoji = "高风险", "🔴"

# A/B 分层判决（学自 ByeByeVPN 的 TSPU 模型）
a_hits = len(signals_major)
b_hits = len(signals_minor)
if a_hits >= 2:
    tspu_tier = "高风险 · 多个硬信号命中"
elif a_hits == 1:
    tspu_tier = "需关注 · 1 个硬信号"
elif b_hits >= 3:
    tspu_tier = "监控中 · 软异常累积"
elif b_hits >= 1:
    tspu_tier = "低风险 · 少量软异常"
else:
    tspu_tier = "安全 · 各源无异常"

# --- 组织 IP 信息 ---
proxy_ip_info = {
    "ip": os.environ.get("PROXY_IP",""),
    "country": jget(ipapi_com, "country", default=""),
    "code": jget(ipapi_com, "countryCode", default=""),
    "city": jget(ipapi_com, "city", default=""),
    "isp": jget(ipapi_com, "isp", default=""),
    "asn": jget(ipapi_com, "as", default=""),
    "company_type": comp_type,
    "company_name": comp_name,
    "abuser_score": abuser_score,
    "dc_name": dc_name,
    "dc_region": dc_region,
    "is_dc": is_dc,
    "is_vpn": is_vpn,
    "is_proxy": com_proxy or is_proxy2,
    "is_tor": is_tor,
    "is_abuser": is_abuser,
    "hosting": com_hosting,
    "mobile": com_mobile,
}

direct_ip_info = {
    "ip": os.environ.get("DIRECT_IP",""),
    "country": jget(direct, "country", default=""),
    "code": jget(direct, "countryCode", default=""),
    "city": jget(direct, "city", default=""),
    "isp": jget(direct, "isp", default=""),
    "asn": jget(direct, "as", default=""),
}

shodan_info = {
    "ports": shodan_ports[:10],
    "tags": shodan_tags,
    "vulns_count": len(shodan_vulns),
    "cpes": shodan_cpes[:5],
}

reputation = {
    "stopforumspam": {"appears": str(sfs_appears) == "1", "frequency": int(sfs_freq) if str(sfs_freq).isdigit() else 0},
    "greynoise": {"noise": gn_noise, "riot": gn_riot, "classification": gn_class, "name": gn_name},
    "vpn_sources": vpn_sources,
    "proxy_sources": proxy_sources,
    "hosting_sources": hosting_sources,
}

# Load proxy detection
import subprocess as _sp
try:
    proxy_info = json.loads(_sp.run(["bash", os.path.dirname(os.environ.get("OUT",".")) + "/proxy_detect.sh"], capture_output=True, text=True, timeout=10).stdout)
except:
    proxy_info = {}

# Location history: append current record, keep last 50
history_file = os.path.dirname(os.environ["OUT"]) + "/代理位置历史.jsonl"
history = []
try:
    with open(history_file) as f:
        history = [json.loads(l) for l in f if l.strip()][-49:]
except: pass

# Check if location changed from last record
_p_city = jget(ipapi_com, "city", default="")
_p_code = jget(ipapi_com, "countryCode", default="")
current_loc = _p_city + " " + _p_code
last_loc = history[-1].get("location","") if history else ""
loc_changed = current_loc != last_loc

# Always append (so we have timestamps even if same location)
history.append({
    "ts": os.environ["TS"],
    "ip": os.environ.get("PROXY_IP",""),
    "location": current_loc,
    "isp": jget(ipapi_com, "isp", default=""),
    "score": score,
    "proxy_app": proxy_info.get("active_app",""),
    "changed": loc_changed
})
with open(history_file, "w") as f:
    for h in history:
        f.write(json.dumps(h, ensure_ascii=False) + "\n")

# Count location changes (for risk: frequent changes = higher risk)
loc_changes = sum(1 for h in history if h.get("changed"))
unique_locations = list(dict.fromkeys(h.get("location","") for h in history if h.get("location")))

data = {
    "ts": os.environ["TS"],
    "total_score": score,
    "risk_level": risk_level,
    "risk_emoji": risk_emoji,
    "tspu_tier": tspu_tier,
    "signals_major": signals_major,
    "signals_minor": signals_minor,
    "a_hits": a_hits,
    "b_hits": b_hits,
    "proxy_ip": proxy_ip_info,
    "direct_ip": direct_ip_info,
    "shodan": shodan_info,
    "reputation": reputation,
    "api_access": api_results,
    "proxy_info": proxy_info,
    "location_history": history[-20:],
    "location_changes_24h": loc_changes,
    "unique_locations": unique_locations[-10:],
}

with open(os.environ["OUT"], "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print(json.dumps(data, ensure_ascii=False, indent=2))
'
