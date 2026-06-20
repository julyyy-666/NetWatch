#!/bin/bash
# NetWatch · 网络体检后台脚本（免外部依赖）
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LANG=en_US.UTF-8

DOMESTIC_URL="https://www.baidu.com"
FOREIGN_DIRECT_URL="https://www.gstatic.com/generate_204"
FOREIGN_PROXY_URL="https://www.gstatic.com/generate_204"
SLOW_MS=3000
RETAIN_DAYS=14

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/logs"
mkdir -p "$LOG"

DAY="$(date +%Y-%m-%d)"
SAMPLES="$LOG/samples-$DAY.jsonl"
EVENTS="$LOG/events.jsonl"
ISSUES="$LOG/问题记录.jsonl"
STATETXT="$DIR/当前状态.txt"
STATEJSON="$DIR/状态.json"
LASTV="$LOG/.last_verdict"
LASTC="$LOG/.last_change"
LASTAPP="$LOG/.last_proxy_app"
TS="$(date +%Y-%m-%dT%H:%M:%S%z)"
TSH="$(date +'%Y-%m-%d %H:%M:%S')"
NOW_EPOCH="$(date +%s)"

json_escape() {
  awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\r/,"\\r"); gsub(/\t/,"\\t"); if (NR>1) printf "\\n"; printf "%s",$0}'
}

jstr() { printf '"%s"' "$(printf "%s" "$1" | json_escape)"; }
bool() { [ "$1" = "true" ] && echo true || echo false; }
num() { case "$1" in ""|*[!0-9.-]*) echo -1 ;; *) echo "$1" ;; esac; }

json_get_string() {
  printf "%s" "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" | head -n 1
}

json_get_number() {
  printf "%s" "$1" | sed -n "s/.*\"$2\":\([0-9][0-9]*\).*/\1/p" | head -n 1
}

probe_http() {
  local url="$1" tmo="${2:-5}" proxy="$3" out
  if [ -n "$proxy" ]; then
    out=$(curl -L -s -m "$tmo" -x "$proxy" -o /dev/null -w "%{http_code} %{time_total}" "$url" 2>/dev/null) || out="000 0"
  else
    out=$(curl -L -s -m "$tmo" -o /dev/null -w "%{http_code} %{time_total}" "$url" 2>/dev/null) || out="000 0"
  fi
  local code="${out%% *}" t="${out##* }" ms
  ms=$(awk -v x="$t" 'BEGIN{printf "%d", x*1000}')
  [ "$code" = "000" ] && ms=-1
  echo "$code $ms"
}

get_gw() {
  local gw
  gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
  case "$gw" in *.*.*.*) echo "$gw"; return;; esac
  netstat -rn -f inet 2>/dev/null | awk '$1=="default" && $NF ~ /^en/ {print $2; exit}'
}

probe_gw() {
  local gw="$1" line rtt
  [ -z "$gw" ] && { echo "unknown -1"; return; }
  line=$(ping -c 1 -t 1 "$gw" 2>/dev/null | awk -F'time=' '/time=/{print $2; exit}')
  if [ -n "$line" ]; then
    rtt=$(echo "$line" | awk '{printf "%.1f",$1}')
    echo "true $rtt"
  else
    echo "false -1"
  fi
}

ping_stats() {
  local target="$1" count="${2:-2}" out loss rt avg jit
  [ -z "$target" ] && { echo "-1 -1 -1"; return; }
  out=$(ping -c "$count" -t 3 "$target" 2>/dev/null)
  loss=$(echo "$out" | sed -n 's/.*[, ]\([0-9.]*\)% packet loss.*/\1/p')
  rt=$(echo "$out" | sed -n 's/.* = \(.*\) ms/\1/p')
  avg=$(echo "$rt" | awk -F'/' '{print $2}')
  jit=$(echo "$rt" | awk -F'/' '{print $4}')
  echo "${loss:-100} ${avg:-0} ${jit:-0}"
}

trim_file() {
  local f="$1" keep="$2" tmp="$1.tmp"
  [ -f "$f" ] || return 0
  local lines
  lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
  [ "${lines:-0}" -le "$keep" ] && return 0
  tail -n "$keep" "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f"
}

find "$LOG" -name 'samples-*.jsonl' -mtime +"$RETAIN_DAYS" -delete 2>/dev/null || true

PROXY_INFO="$(bash "$DIR/proxy_detect.sh" 2>/dev/null || echo '{}')"
PROXY_APP="$(json_get_string "$PROXY_INFO" active_app)"
PROXY_MODE="$(json_get_string "$PROXY_INFO" active_mode)"
PROXY_HOST="$(json_get_string "$PROXY_INFO" active_host)"
PROXY_PORT="$(json_get_number "$PROXY_INFO" active_port)"
PROXY_URL="$(json_get_string "$PROXY_INFO" proxy_url)"

[ -n "$PROXY_APP" ] || PROXY_APP="未识别"
[ -n "$PROXY_MODE" ] || PROXY_MODE="none"
[ -n "$PROXY_HOST" ] || PROXY_HOST="127.0.0.1"
[ -n "$PROXY_PORT" ] || PROXY_PORT=0
PROXY_RECOGNIZED=false
[ "$PROXY_APP" != "未识别" ] && PROXY_RECOGNIZED=true
PROXY_READY=false
[ -n "$PROXY_URL" ] && PROXY_READY=true

GW_IP="$(get_gw)"
read -r GW_OK GW_RTT <<<"$(probe_gw "$GW_IP")"

read -r DOM_CODE DOM_MS <<<"$(probe_http "$DOMESTIC_URL" 4)"
DOM_OK=false
[ "$DOM_CODE" = "200" ] || [ "$DOM_CODE" = "301" ] || [ "$DOM_CODE" = "302" ] && DOM_OK=true

read -r LGW_LOSS LGW_AVG LGW_JIT <<<"$(ping_stats "$GW_IP" 2)"
read -r NET_LOSS NET_AVG NET_JIT <<<"$(ping_stats 223.5.5.5 2)"

read -r DIRECT_CODE DIRECT_MS <<<"$(probe_http "$FOREIGN_DIRECT_URL" 4)"
DIRECT_OK=false
[ "$DIRECT_CODE" = "204" ] || [ "$DIRECT_CODE" = "200" ] && DIRECT_OK=true

if [ "$PROXY_READY" = "true" ]; then
  read -r PROXY_CODE PROXY_MS <<<"$(probe_http "$FOREIGN_PROXY_URL" 6 "$PROXY_URL")"
else
  PROXY_CODE="000"; PROXY_MS=-1
fi

PROXY_OK=false
[ "$PROXY_CODE" = "204" ] || [ "$PROXY_CODE" = "200" ] && PROXY_OK=true
PROXY_SLOW=false
[ "$PROXY_OK" = "true" ] && [ "$PROXY_MS" -gt "$SLOW_MS" ] 2>/dev/null && PROXY_SLOW=true

if [ "$DOM_OK" = "false" ] && [ "$GW_OK" != "true" ]; then
  VERDICT="本地网络断开"; REASON="路由器不通，国内网站也打不开 → 先看 Wi-Fi/网线/路由器"
elif [ "$DOM_OK" = "false" ]; then
  VERDICT="宽带/运营商异常"; REASON="路由器还通，但国内网站打不开 → 可能是宽带或运营商问题"
elif [ "$PROXY_RECOGNIZED" = "false" ]; then
  VERDICT="代理软件未运行"; REASON="没检测到可用代理端口 → 打开代理软件并开启系统代理"
elif [ "$PROXY_READY" = "false" ]; then
  VERDICT="代理端口未开启"; REASON="$PROXY_APP 在跑，但没检测到本地代理端口 → 如用 TUN/增强模式，请开启系统代理或本地 HTTP/SOCKS 端口"
elif [ "$PROXY_OK" = "false" ]; then
  VERDICT="代理通道异常"; REASON="$PROXY_APP 已识别，但经代理访问国外失败 → 换节点或检查代理设置"
elif [ "$PROXY_SLOW" = "true" ]; then
  VERDICT="国外缓慢"; REASON="$PROXY_APP 经代理延迟 ${PROXY_MS}ms → 可能节点慢或链路拥堵"
else
  VERDICT="正常"; REASON="$PROXY_APP 正在工作，代理通畅（${PROXY_MODE}:${PROXY_PORT}）"
fi

case "$VERDICT" in
  正常) LIGHT="🟢";;
  国外缓慢) LIGHT="🟡";;
  *) LIGHT="🔴";;
esac

STATE_LINE=$(printf '{"ts":%s,"verdict":%s,"reason":%s,"gateway":{"ip":%s,"ok":%s,"rtt_ms":%s},"domestic":{"ok":%s,"code":%s,"ms":%s},"surge":{"running":%s,"http_port":%s,"socks_port":%s},"proxy_app":%s,"proxy_mode":%s,"proxy_port":%s,"proxy":{"ok":%s,"code":%s,"ms":%s,"slow":%s},"direct":{"ok":%s,"ms":%s},"foreign":{"ok":%s,"code":%s,"ms":%s,"slow":%s},"quality":{"local":{"loss":%s,"avg":%s,"jitter":%s},"net":{"loss":%s,"avg":%s,"jitter":%s}}}' \
  "$(jstr "$TS")" "$(jstr "$VERDICT")" "$(jstr "$REASON")" "$(jstr "${GW_IP:-未知}")" "$(jstr "$GW_OK")" "$(num "$GW_RTT")" \
  "$(bool "$DOM_OK")" "$(jstr "$DOM_CODE")" "$(num "$DOM_MS")" \
  "$(bool "$PROXY_RECOGNIZED")" "$(bool "$PROXY_READY")" "$(bool "$PROXY_READY")" \
  "$(jstr "$PROXY_APP")" "$(jstr "$PROXY_MODE")" "$(num "$PROXY_PORT")" \
  "$(bool "$PROXY_OK")" "$(jstr "$PROXY_CODE")" "$(num "$PROXY_MS")" "$(bool "$PROXY_SLOW")" \
  "$(bool "$DIRECT_OK")" "$(num "$DIRECT_MS")" \
  "$(bool "$PROXY_OK")" "$(jstr "$PROXY_CODE")" "$(num "$PROXY_MS")" "$(bool "$PROXY_SLOW")" \
  "$(num "$LGW_LOSS")" "$(num "$LGW_AVG")" "$(num "$LGW_JIT")" "$(num "$NET_LOSS")" "$(num "$NET_AVG")" "$(num "$NET_JIT")")

printf "%s\n" "$STATE_LINE" >> "$SAMPLES" 2>/dev/null
STATE_TMP="$STATEJSON.$$"
printf "%s\n" "$STATE_LINE" > "$STATE_TMP" 2>/dev/null && mv "$STATE_TMP" "$STATEJSON" 2>/dev/null

PREV="$(cat "$LASTV" 2>/dev/null)"
PREV_C="$(cat "$LASTC" 2>/dev/null)"
PREV_APP="$(cat "$LASTAPP" 2>/dev/null)"

write_event() {
  local change="$1" verdict="$2" reason="$3" note="$4"
  printf '{"ts":%s,"change":%s,"verdict":%s,"reason":%s,"note":%s}\n' \
    "$(jstr "$TS")" "$(jstr "$change")" "$(jstr "$verdict")" "$(jstr "$reason")" "$(jstr "$note")" >> "$EVENTS" 2>/dev/null
}

if [ "$VERDICT" != "$PREV" ]; then
  DUR=""
  if [ -n "$PREV" ] && [ -n "$PREV_C" ]; then
    secs=$(( NOW_EPOCH - PREV_C )); mins=$(( secs / 60 ))
    DUR="上一状态[$PREV]持续约 ${mins} 分钟"
  fi
  CHANGE="${PREV:-启动} → $VERDICT"
  write_event "$CHANGE" "$VERDICT" "$REASON" "$DUR"
  if [ "$VERDICT" != "正常" ]; then
    printf '{"ts":%s,"verdict":%s,"reason":%s,"proxy_app":%s,"proxy_mode":%s,"proxy_port":%s}\n' \
      "$(jstr "$TS")" "$(jstr "$VERDICT")" "$(jstr "$REASON")" "$(jstr "$PROXY_APP")" "$(jstr "$PROXY_MODE")" "$(num "$PROXY_PORT")" >> "$ISSUES" 2>/dev/null
  fi
  if [ "$VERDICT" = "正常" ]; then
    osascript -e "display notification \"$REASON $DUR\" with title \"🟢 网络已恢复正常\"" >/dev/null 2>&1
  else
    osascript -e "display notification \"$REASON\" with title \"$LIGHT 网络异常：$VERDICT\"" >/dev/null 2>&1
  fi
  echo "$VERDICT" > "$LASTV"
  echo "$NOW_EPOCH" > "$LASTC"
fi

if [ "$PROXY_APP" != "$PREV_APP" ] && [ "$PROXY_APP" != "未识别" ]; then
  write_event "代理切换：${PREV_APP:-未知} → $PROXY_APP" "$VERDICT" "$REASON" "${PROXY_MODE}:${PROXY_PORT}"
  echo "$PROXY_APP" > "$LASTAPP"
fi

[ -z "$PREV" ] && { echo "$VERDICT" > "$LASTV"; echo "$NOW_EPOCH" > "$LASTC"; }

trim_file "$EVENTS" 2000
trim_file "$ISSUES" 1000

glyph() { [ "$1" = "true" ] && echo "🟢" || echo "🔴"; }
fmt_ms() { [ "$1" -lt 0 ] 2>/dev/null && echo "—" || echo "${1}ms"; }
LAST_FAIL="$(tail -n 1 "$ISSUES" 2>/dev/null | sed -n 's/.*"verdict":"\([^"]*\)".*/\1/p')"

STATETXT_TMP="$STATETXT.$$"
cat > "$STATETXT_TMP" <<EOF
网络体检 · 最近一次检查
================================================
检查时间：$TSH
总  判  定：$LIGHT  $VERDICT
判定依据：$REASON

  本地网关 ${GW_IP:-未知}        $( [ "$GW_OK" = "true" ] && echo "🟢 通 (${GW_RTT}ms)" || echo "🔴 不通" )
  国内网站              $(glyph "$DOM_OK") $DOM_CODE ($(fmt_ms "${DOM_MS:--1}"))
  代理软件              $(glyph "$PROXY_RECOGNIZED") $PROXY_APP
  代理端口              $(glyph "$PROXY_READY") ${PROXY_MODE}:${PROXY_PORT}
  国外(经代理)          $(glyph "$PROXY_OK") $PROXY_CODE ($(fmt_ms "${PROXY_MS:--1}"))$( [ "$PROXY_SLOW" = "true" ] && echo " ⚠️偏慢" )
  国外(直连)            $(glyph "$DIRECT_OK") ($(fmt_ms "${DIRECT_MS:--1}"))

最近一次问题：${LAST_FAIL:-（暂无记录）}

说明：🟢正常 🟡偏慢 🔴故障。完整历史见 logs/events.jsonl 和 logs/问题记录.jsonl
EOF
mv "$STATETXT_TMP" "$STATETXT" 2>/dev/null || true

exit 0
