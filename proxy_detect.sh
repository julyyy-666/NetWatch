#!/bin/bash
# NetWatch · 代理软件自动识别
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

python3 <<'PY'
import json
import subprocess


def run(args, timeout=3):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def pgrep(name):
    return subprocess.run(["pgrep", "-f", name], capture_output=True).returncode == 0


def port_open(port):
    if not port:
        return False
    return subprocess.run(["nc", "-z", "-G", "1", "127.0.0.1", str(port)], capture_output=True).returncode == 0


def app_installed(name):
    return subprocess.run(["test", "-d", f"/Applications/{name}.app"], capture_output=True).returncode == 0


proxy_out = run(["scutil", "--proxy"])
sys_http_port = ""
sys_socks_port = ""
for line in proxy_out.splitlines():
    if "HTTPPort" in line:
        sys_http_port = line.split(":", 1)[1].strip()
    if "SOCKSPort" in line:
        sys_socks_port = line.split(":", 1)[1].strip()

sys_proxy_on = "HTTPEnable : 1" in proxy_out or "HTTPSEnable : 1" in proxy_out or "SOCKSEnable : 1" in proxy_out

tailscale_ip = ""
tailscale_out = run(["tailscale", "ip", "-4"])
if tailscale_out.strip():
    tailscale_ip = tailscale_out.strip().splitlines()[0]

proxies = [
    {"name": "Surge", "http": 6152, "socks": 6153},
    {"name": "Shadowrocket", "http": 1080, "socks": 1081},
    {"name": "Clash Verge", "http": 7890, "socks": 7891},
    {"name": "ClashX", "http": 7890, "socks": 7891},
    {"name": "V2RayX", "http": 1087, "socks": 1087},
    {"name": "sing-box", "http": 2080, "socks": 2080},
]

apps = []
active_app = ""
for proxy in proxies:
    name = proxy["name"]
    http_port = proxy["http"]
    socks_port = proxy["socks"]
    running = pgrep(name)
    installed = app_installed(name)
    if not running and not installed:
        continue

    is_active = running and (str(http_port) == sys_http_port or str(socks_port) == sys_socks_port)
    if is_active:
        active_app = name

    apps.append({
        "name": name,
        "running": running,
        "installed": installed,
        "http_port": http_port,
        "socks_port": socks_port,
        "http_ok": port_open(http_port) if running else False,
        "socks_ok": port_open(socks_port) if running else False,
        "is_active": is_active,
    })

if not active_app:
    active_app = next((app["name"] for app in apps if app["running"]), "")

print(json.dumps({
    "active_app": active_app,
    "sys_proxy_on": sys_proxy_on,
    "sys_http_port": sys_http_port,
    "sys_socks_port": sys_socks_port,
    "tailscale": {"running": pgrep("Tailscale"), "ip": tailscale_ip},
    "apps": apps,
}, ensure_ascii=False))
PY
