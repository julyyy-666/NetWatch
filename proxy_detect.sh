#!/bin/bash
# NetWatch · 代理软件自动识别（免外部依赖）
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LANG=en_US.UTF-8

json_escape() {
  awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\r/,"\\r"); gsub(/\t/,"\\t"); if (NR>1) printf "\\n"; printf "%s",$0}'
}

jstr() { printf '"%s"' "$(printf "%s" "$1" | json_escape)"; }

port_open() {
  local host="${1:-127.0.0.1}" port="$2"
  [ -n "$port" ] || return 1
  nc -z -G 1 "$host" "$port" >/dev/null 2>&1
}

running() {
  local pattern="$1" display="${2:-$1}"
  pgrep -ix "$pattern" >/dev/null 2>&1 && return 0
  [ "$display" != "$pattern" ] && pgrep -ix "$display" >/dev/null 2>&1 && return 0
  app_main_running "$display" && return 0
  [ "$display" != "$pattern" ] && app_main_running "$pattern" && return 0
  return 1
}

app_main_running() {
  local app_name="$1"
  LC_ALL=C ps -axo comm=,args= 2>/dev/null | LC_ALL=C awk \
    -v app1="/Applications/${app_name}.app/Contents/MacOS/" \
    -v app2="$HOME/Applications/${app_name}.app/Contents/MacOS/" '
      $1 ~ /(awk|bash|zsh|sh|ps|pgrep|rg)$/ { next }
      index($0, app1) || index($0, app2) { found = 1 }
      END { exit found ? 0 : 1 }
    '
}

installed() {
  [ -d "/Applications/$1.app" ] || [ -d "$HOME/Applications/$1.app" ]
}

proxy_out="$(scutil --proxy 2>/dev/null)"
sys_http_host="$(printf "%s\n" "$proxy_out" | awk -F': ' '/HTTPProxy/{print $2; exit}')"
sys_http_port="$(printf "%s\n" "$proxy_out" | awk -F': ' '/HTTPPort/{print $2; exit}')"
sys_https_port="$(printf "%s\n" "$proxy_out" | awk -F': ' '/HTTPSPort/{print $2; exit}')"
sys_socks_host="$(printf "%s\n" "$proxy_out" | awk -F': ' '/SOCKSProxy/{print $2; exit}')"
sys_socks_port="$(printf "%s\n" "$proxy_out" | awk -F': ' '/SOCKSPort/{print $2; exit}')"

sys_http_on=false
sys_socks_on=false
printf "%s\n" "$proxy_out" | grep -q 'HTTPEnable : 1' && sys_http_on=true
printf "%s\n" "$proxy_out" | grep -q 'HTTPSEnable : 1' && sys_http_on=true
printf "%s\n" "$proxy_out" | grep -q 'SOCKSEnable : 1' && sys_socks_on=true
sys_proxy_on=false
if [ "$sys_http_on" = "true" ] || [ "$sys_socks_on" = "true" ]; then
  sys_proxy_on=true
fi

[ -n "$sys_http_host" ] || sys_http_host="127.0.0.1"
[ -n "$sys_socks_host" ] || sys_socks_host="127.0.0.1"

APP_NAMES=(
  "Surge|Surge|6152|6153"
  "Shadowrocket|Shadowrocket|1080|1081"
  "Clash Verge|Clash Verge|7890|7891"
  "Clash Verge Rev|Clash Verge Rev|7897|7898"
  "ClashX|ClashX|7890|7891"
  "ClashX Pro|ClashX Pro|7890|7891"
  "mihomo|mihomo|7890|7891"
  "FlClash|FlClash|7890|7891"
  "Stash|Stash|6152|6153"
  "Loon|Loon|7222|7222"
  "Quantumult X|Quantumult|9090|9090"
  "V2RayX|V2RayX|1087|1087"
  "V2RayU|V2RayU|1087|1086"
  "sing-box|sing-box|2080|2080"
  "Hiddify|Hiddify|12334|12333"
  "Clash Meta|clash|7890|7891"
)

active_app=""
active_mode=""
active_host=""
active_port=""
proxy_url=""
apps_json=""
first_running_app=""

add_app_json() {
  local name="$1" run="$2" inst="$3" active="$4" http_port="$5" socks_port="$6" http_ok="$7" socks_ok="$8"
  local item
  item=$(printf '{"name":%s,"running":%s,"installed":%s,"is_active":%s,"http_port":%s,"socks_port":%s,"http_ok":%s,"socks_ok":%s}' \
    "$(jstr "$name")" "$run" "$inst" "$active" "${http_port:-0}" "${socks_port:-0}" "$http_ok" "$socks_ok")
  if [ -n "$apps_json" ]; then apps_json="$apps_json,$item"; else apps_json="$item"; fi
}

choose_active_from_system() {
  if [ "$sys_http_on" = "true" ] && [ -n "$sys_http_port" ] && port_open "$sys_http_host" "$sys_http_port"; then
    active_mode="http"; active_host="$sys_http_host"; active_port="$sys_http_port"
    proxy_url="http://$active_host:$active_port"
    return 0
  fi
  if [ "$sys_socks_on" = "true" ] && [ -n "$sys_socks_port" ] && port_open "$sys_socks_host" "$sys_socks_port"; then
    active_mode="socks"; active_host="$sys_socks_host"; active_port="$sys_socks_port"
    proxy_url="socks5h://$active_host:$active_port"
    return 0
  fi
  return 1
}

choose_active_from_system || true

for row in "${APP_NAMES[@]}"; do
  IFS='|' read -r name pattern http_port socks_port <<<"$row"
  run=false; inst=false; active=false; http_ok=false; socks_ok=false
  running "$pattern" "$name" && run=true
  installed "$name" && inst=true
  [ "$run" = "true" ] && port_open 127.0.0.1 "$http_port" && http_ok=true
  [ "$run" = "true" ] && port_open 127.0.0.1 "$socks_port" && socks_ok=true

  if [ "$run" = "true" ]; then
    [ -n "$first_running_app" ] || first_running_app="$name"
    if [ -n "$active_port" ] && { [ "$active_port" = "$http_port" ] || [ "$active_port" = "$socks_port" ]; }; then
      active=true
      [ -z "$active_app" ] && active_app="$name"
    elif [ -z "$active_port" ] && [ "$http_ok" = "true" ]; then
      active=true; active_app="$name"; active_mode="http"; active_host="127.0.0.1"; active_port="$http_port"; proxy_url="http://127.0.0.1:$http_port"
    elif [ -z "$active_port" ] && [ "$socks_ok" = "true" ]; then
      active=true; active_app="$name"; active_mode="socks"; active_host="127.0.0.1"; active_port="$socks_port"; proxy_url="socks5h://127.0.0.1:$socks_port"
    fi
  fi

  if [ "$run" = "true" ] || [ "$inst" = "true" ]; then
    add_app_json "$name" "$run" "$inst" "$active" "$http_port" "$socks_port" "$http_ok" "$socks_ok"
  fi
done

# 兜底：系统代理没开、进程名也没精确匹配上时，直接扫常见 HTTP/SOCKS 代理端口
if [ -z "$active_port" ] && [ "$sys_proxy_on" != "true" ]; then
  for row in "${APP_NAMES[@]}"; do
    IFS='|' read -r name pattern http_port socks_port <<<"$row"
    if port_open 127.0.0.1 "$http_port"; then
      active_app="$name"; active_mode="http"; active_host="127.0.0.1"; active_port="$http_port"
      proxy_url="http://127.0.0.1:$http_port"
      break
    elif port_open 127.0.0.1 "$socks_port"; then
      active_app="$name"; active_mode="socks"; active_host="127.0.0.1"; active_port="$socks_port"
      proxy_url="socks5h://127.0.0.1:$socks_port"
      break
    fi
  done
fi

if [ -z "$active_app" ] && [ -n "$first_running_app" ]; then
  active_app="$first_running_app"
  active_mode="tun"
  active_port=0
  proxy_url=""
fi

if [ -z "$active_app" ] && [ -n "$active_port" ]; then
  active_app="系统代理"
  add_app_json "系统代理(:$active_port)" true true true "${active_port:-0}" "${active_port:-0}" "$([ "$active_mode" = "http" ] && echo true || echo false)" "$([ "$active_mode" = "socks" ] && echo true || echo false)"
fi

tailscale_running=false
running "Tailscale" "Tailscale" && tailscale_running=true
tailscale_ip=""

printf '{"active_app":%s,"active_mode":%s,"active_host":%s,"active_port":%s,"proxy_url":%s,"sys_proxy_on":%s,"sys_http_host":%s,"sys_http_port":%s,"sys_socks_host":%s,"sys_socks_port":%s,"tailscale":{"running":%s,"ip":%s},"apps":[%s]}\n' \
  "$(jstr "$active_app")" "$(jstr "$active_mode")" "$(jstr "$active_host")" "${active_port:-0}" "$(jstr "$proxy_url")" "$sys_proxy_on" \
  "$(jstr "$sys_http_host")" "${sys_http_port:-0}" "$(jstr "$sys_socks_host")" "${sys_socks_port:-0}" "$tailscale_running" "$(jstr "$tailscale_ip")" "$apps_json"
