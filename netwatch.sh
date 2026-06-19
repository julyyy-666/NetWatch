#!/bin/bash
# ============================================================
#  网络黑匣子 NetWatch v2 — Surge Edition
#  作者：见林 + Hermes   每分钟由 launchd 调用一次
#  v2: Shadowrocket→Surge；移除废弃VPS；加代理穿透+直连对比
# ============================================================
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LANG=en_US.UTF-8

# ---------------- 可配置区 ----------------
SURGE_HTTP_PORT=6152
SURGE_SOCKS_PORT=6153
SURGE_PROCESS="Surge"
DOMESTIC_URL="https://www.baidu.com"
FOREIGN_DIRECT_URL="https://www.gstatic.com/generate_204"
FOREIGN_PROXY_URL="https://www.gstatic.com/generate_204"
SLOW_MS=3000
RETAIN_DAYS=14
# --------------------------------------------------------------

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/logs"
mkdir -p "$LOG"
DAY="$(date +%Y-%m-%d)"
SAMPLES="$LOG/samples-$DAY.jsonl"
EVENTS="$LOG/events.jsonl"
STATETXT="$DIR/当前状态.txt"
STATEJSON="$DIR/状态.json"
LASTV="$LOG/.last_verdict"
LASTC="$LOG/.last_change"
TS="$(date +%Y-%m-%dT%H:%M:%S%z)"
TSH="$(date +'%Y-%m-%d %H:%M:%S')"
NOW_EPOCH="$(date +%s)"

# ---------------- 探测函数 ----------------
probe_tcp() { nc -z -G 3 "$1" "$2" >/dev/null 2>&1 && echo true || echo false; }

probe_http() {
  local url="$1" tmo="${2:-6}" proxy="$3" out
  if [ -n "$proxy" ]; then
    out=$(curl -s -m "$tmo" -x "$proxy" -o /dev/null -w "%{http_code} %{time_total}" "$url" 2>/dev/null) || out="000 0"
  else
    out=$(curl -s -m "$tmo" -o /dev/null -w "%{http_code} %{time_total}" "$url" 2>/dev/null) || out="000 0"
  fi
  local code="${out%% *}" t="${out##* }"
  local ms; ms=$(awk -v x="$t" 'BEGIN{printf "%d", x*1000}')
  [ "$code" = "000" ] && ms=-1
  echo "$code $ms"
}

get_gw() {
  local gw; gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
  case "$gw" in *.*.*.*) echo "$gw"; return;; esac
  netstat -rn -f inet 2>/dev/null | awk '$1=="default" && $NF ~ /^en/ {print $2; exit}'
}

probe_gw() {
  local gw="$1" line rtt
  [ -z "$gw" ] && { echo "unknown -1"; return; }
  line=$(ping -c 1 -t 2 "$gw" 2>/dev/null | awk -F'time=' '/time=/{print $2; exit}')
  if [ -n "$line" ]; then rtt=$(echo "$line" | awk '{printf "%.1f",$1}'); echo "true $rtt"
  else echo "false -1"; fi
}

ping_stats() {
  local target="$1" count="${2:-5}" out loss rt avg jit
  [ -z "$target" ] && { echo "-1 -1 -1"; return; }
  out=$(ping -c "$count" -t 6 "$target" 2>/dev/null)
  loss=$(echo "$out" | sed -n 's/.*[, ]\([0-9.]*\)% packet loss.*/\1/p')
  rt=$(echo "$out" | sed -n 's/.* = \(.*\) ms/\1/p')
  avg=$(echo "$rt" | awk -F'/' '{print $2}')
  jit=$(echo "$rt" | awk -F'/' '{print $4}')
  echo "${loss:-100} ${avg:-0} ${jit:-0}"
}

# ---------------- 采集 ----------------
# 1. 本地网关
GW_IP="$(get_gw)"
read -r GW_OK GW_RTT <<<"$(probe_gw "$GW_IP")"

# 2. 国内
read -r DOM_CODE DOM_MS <<<"$(probe_http "$DOMESTIC_URL" 5)"
[ "$DOM_CODE" = "200" ] || [ "$DOM_CODE" = "301" ] || [ "$DOM_CODE" = "302" ] && DOM_OK=true || DOM_OK=false

# 3. Surge 进程
SURGE_RUNNING=$(pgrep -x "$SURGE_PROCESS" >/dev/null 2>&1 && echo true || echo false)

# 4. Surge 端口
SURGE_HTTP_OK=$(probe_tcp 127.0.0.1 "$SURGE_HTTP_PORT")
SURGE_SOCKS_OK=$(probe_tcp 127.0.0.1 "$SURGE_SOCKS_PORT")

# 5. 网络质量
read -r LGW_LOSS LGW_AVG LGW_JIT <<<"$(ping_stats "$GW_IP" 5)"
read -r NET_LOSS NET_AVG NET_JIT <<<"$(ping_stats 223.5.5.5 5)"

# 6. 国外直连 (不经过代理)
read -r DIRECT_CODE DIRECT_MS <<<"$(probe_http "$FOREIGN_DIRECT_URL" 6)"
DIRECT_OK=false
[ "$DIRECT_CODE" = "204" ] || [ "$DIRECT_CODE" = "200" ] && DIRECT_OK=true

# 7. 国外经 Surge 代理
if [ "$SURGE_HTTP_OK" = "true" ]; then
  read -r PROXY_CODE PROXY_MS <<<"$(probe_http "$FOREIGN_PROXY_URL" 8 "http://127.0.0.1:$SURGE_HTTP_PORT")"
else
  PROXY_CODE="000"; PROXY_MS=-1
fi
PROXY_OK=false
[ "$PROXY_CODE" = "204" ] || [ "$PROXY_CODE" = "200" ] && PROXY_OK=true
PROXY_SLOW=false
[ "$PROXY_OK" = "true" ] && [ "$PROXY_MS" -gt "$SLOW_MS" ] 2>/dev/null && PROXY_SLOW=true

# ---------------- 判定决策树 ----------------
if [ "$DOM_OK" = "false" ] && [ "$GW_OK" != "true" ]; then
  VERDICT="本地网络断开"; REASON="网关不通且国内站打不开 → Wi-Fi/网线/路由器问题"
elif [ "$DOM_OK" = "false" ]; then
  VERDICT="宽带/ISP故障"; REASON="本地链路正常但国内站打不开 → 宽带出口或运营商问题"
elif [ "$SURGE_RUNNING" = "false" ]; then
  VERDICT="Surge 未运行"; REASON="Surge 进程不在 → 需要启动 Surge.app"
elif [ "$SURGE_HTTP_OK" = "false" ] && [ "$SURGE_SOCKS_OK" = "false" ]; then
  VERDICT="Surge 端口异常"; REASON="Surge 在跑但 HTTP($SURGE_HTTP_PORT)/SOCKS($SURGE_SOCKS_PORT) 端口都没在听 → 检查 Surge 配置"
elif [ "$PROXY_OK" = "false" ]; then
  VERDICT="代理隧道异常"; REASON="Surge 在听但经代理访问国外失败 → 代理节点不可用/被墙干扰"
elif [ "$PROXY_SLOW" = "true" ]; then
  VERDICT="国外缓慢"; REASON="经 Surge 代理延迟 ${PROXY_MS}ms (阈值${SLOW_MS}ms) → 可能限速"
else
  VERDICT="正常"; REASON="各层均正常 · Surge 代理通畅"
fi

case "$VERDICT" in
  正常) LIGHT="🟢";;
  国外缓慢) LIGHT="🟡";;
  *) LIGHT="🔴";;
esac

# ---------------- 写采样 JSONL ----------------
jq -nc \
  --arg ts "$TS" --arg verdict "$VERDICT" --arg reason "$REASON" \
  --arg gwip "$GW_IP" --arg gwok "$GW_OK" --argjson gwrtt "${GW_RTT:--1}" \
  --argjson domok "$DOM_OK" --arg domcode "$DOM_CODE" --argjson domms "${DOM_MS:--1}" \
  --argjson surgeRunning "$SURGE_RUNNING" \
  --argjson surgeHttp "$SURGE_HTTP_OK" --argjson surgeSocks "$SURGE_SOCKS_OK" \
  --argjson proxyok "$PROXY_OK" --arg proxycode "$PROXY_CODE" --argjson proxyms "${PROXY_MS:--1}" --argjson proxyslow "$PROXY_SLOW" \
  --argjson directok "$DIRECT_OK" --argjson directms "${DIRECT_MS:--1}" \
  --argjson lgwloss "${LGW_LOSS:--1}" --argjson lgwavg "${LGW_AVG:--1}" --argjson lgwjit "${LGW_JIT:--1}" \
  --argjson netloss "${NET_LOSS:--1}" --argjson netavg "${NET_AVG:--1}" --argjson netjit "${NET_JIT:--1}" \
  '{ts:$ts,verdict:$verdict,reason:$reason,
    gateway:{ip:$gwip,ok:$gwok,rtt_ms:$gwrtt},
    domestic:{ok:$domok,code:$domcode,ms:$domms},
    surge:{running:$surgeRunning,http_port:$surgeHttp,socks_port:$surgeSocks},
    proxy:{ok:$proxyok,code:$proxycode,ms:$proxyms,slow:$proxyslow},
    direct:{ok:$directok,ms:$directms},
    foreign:{ok:$proxyok,code:$proxycode,ms:$proxyms,slow:$proxyslow},
    quality:{local:{loss:$lgwloss,avg:$lgwavg,jitter:$lgwjit},net:{loss:$netloss,avg:$netavg,jitter:$netjit}}}' >> "$SAMPLES" 2>/dev/null

tail -n 1 "$SAMPLES" > "$STATEJSON" 2>/dev/null

# ---------------- 状态变化 → 事件 + 通知 ----------------
PREV="$(cat "$LASTV" 2>/dev/null)"
PREV_C="$(cat "$LASTC" 2>/dev/null)"
if [ "$VERDICT" != "$PREV" ]; then
  DUR=""
  if [ -n "$PREV" ] && [ -n "$PREV_C" ]; then
    secs=$(( NOW_EPOCH - PREV_C )); mins=$(( secs / 60 ))
    DUR="（上一状态[$PREV]持续约 ${mins} 分钟）"
  fi
  CHANGE="${PREV:-启动} → $VERDICT"
  jq -nc --arg ts "$TS" --arg change "$CHANGE" --arg verdict "$VERDICT" \
     --arg reason "$REASON" --arg dur "$DUR" \
     '{ts:$ts,change:$change,verdict:$verdict,reason:$reason,note:$dur}' >> "$EVENTS" 2>/dev/null
  if [ "$VERDICT" = "正常" ]; then
    osascript -e "display notification \"$REASON $DUR\" with title \"🟢 网络已恢复正常\"" >/dev/null 2>&1
  else
    osascript -e "display notification \"$REASON\" with title \"$LIGHT 网络异常：$VERDICT\"" >/dev/null 2>&1
  fi
  echo "$VERDICT" > "$LASTV"
  echo "$NOW_EPOCH" > "$LASTC"
fi
[ -z "$PREV" ] && { echo "$VERDICT" > "$LASTV"; echo "$NOW_EPOCH" > "$LASTC"; }

# ---------------- 人类可读快照 ----------------
glyph() { [ "$1" = "true" ] && echo "🟢" || echo "🔴"; }
fmt_ms() { [ "$1" -lt 0 ] 2>/dev/null && echo "—" || echo "${1}ms"; }

LAST_FAIL="$(grep -v '"verdict":"正常"' "$EVENTS" 2>/dev/null | tail -n 1 | jq -r '"\(.ts[0:16] | sub("T";" "))  \(.verdict)"' 2>/dev/null)"

cat > "$STATETXT" <<EOF
网络黑匣子 NetWatch v2 · 最近一次检查
================================================
检查时间：$TSH
总  判  定：$LIGHT  $VERDICT
判定依据：$REASON

  本地网关 ${GW_IP:-未知}	$( [ "$GW_OK" = "true" ] && echo "🟢 通 (${GW_RTT}ms)" || echo "🔴 不通" )
  国内(百度)		$(glyph "$DOM_OK") $DOM_CODE ($(fmt_ms "${DOM_MS:--1}"))
  Surge 进程		$(glyph "$SURGE_RUNNING") $( [ "$SURGE_RUNNING" = "true" ] && echo "运行中" || echo "未运行" )
  Surge HTTP $SURGE_HTTP_PORT	$(glyph "$SURGE_HTTP_OK")
  Surge SOCKS $SURGE_SOCKS_PORT	$(glyph "$SURGE_SOCKS_OK")
  国外(经Surge)		$(glyph "$PROXY_OK") $PROXY_CODE ($(fmt_ms "${PROXY_MS:--1}"))$( [ "$PROXY_SLOW" = "true" ] && echo " ⚠️偏慢" )
  国外(直连)		$(glyph "$DIRECT_OK") ($(fmt_ms "${DIRECT_MS:--1}"))

最近一次异常：${LAST_FAIL:-（暂无记录）}

说明：🟢正常 🟡偏慢 🔴故障。完整历史见 logs/events.jsonl
本文件每分钟自动刷新一次。
EOF

exit 0
