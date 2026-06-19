#!/bin/bash
# NetWatch · 代理软件自动识别
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# 系统代理
SYS_PROXY=$(scutil --proxy 2>/dev/null)
SYS_HTTP_PORT=$(echo "$SYS_PROXY" | awk '/HTTPPort/{print $3}')
SYS_SOCKS_PORT=$(echo "$SYS_PROXY" | awk '/SOCKSPort/{print $3}')
SYS_HTTP_ON=$(echo "$SYS_PROXY" | awk '/HTTPEnable/{print $3}')
SYS_SOCKS_ON=$(echo "$SYS_PROXY" | awk '/SOCKSEnable/{print $3}')

# Tailscale
TS_IP=$(tailscale ip -4 2>/dev/null | head -1)

# 输出 JSON
python3 << 'PYEOF'
import json, subprocess, os

def pgrep(name):
    r = subprocess.run(["pgrep", "-f", name], capture_output=True)
    return r.returncode == 0

def port_open(port):
    if not port: return False
    r = subprocess.run(["nc", "-z", "-G", "1", "127.0.0.1", str(port)], capture_output=True)
    return r.returncode == 0

def app_installed(name):
    r = subprocess.run(["ls", f"/Applications/{name}.app"], capture_output=True)
    return r.returncode == 0

PROXIES = [
    {"name": "Surge",        "http": 6152, "socks": 6153},
    {"name": "Shadowrocket", "http": 1080, "socks": 1081},
    {"name": "Clash Verge",  "http": 7890, "socks": 7891},
    {"name": "ClashX",       "http": 7890, "socks": 7891},
    {"name": "V2RayX",       "http": 1087, "socks": 1087},
    {"name": "sing-box",     "http": 2080, "socks": 2080},
]

sys_http = os.popen("echo $SYS_HTTP_PORT").read().strip()
# That won't work in heredoc. Let me use environ properly.
PYEOF

# Direct approach - all in Python with os.popen for scutil
python3 -c "
import json, subprocess, os

def pgrep(name):
    r = subprocess.run(['pgrep', '-f', name], capture_output=True, text=True)
    return r.returncode == 0

def port_open(port):
    if not port: return False
    r = subprocess.run(['nc', '-z', '-G', '1', '127.0.0.1', str(port)], capture_output=True)
    return r.returncode == 0

def app_installed(name):
    r = subprocess.run(['ls', f'/Applications/{name}.app'], capture_output=True)
    return r.returncode == 0

# Read system proxy
import re
proxy_out = subprocess.run(['scutil', '--proxy'], capture_output=True, text=True).stdout
sys_http_port = ''
sys_socks_port = ''
for line in proxy_out.split('\n'):
    if 'HTTPPort' in line: sys_http_port = line.split(':')[1].strip()
    if 'SOCKSPort' in line: sys_socks_port = line.split(':')[1].strip()
    if 'HTTPEnable' in line: sys_http_on = line.split(':')[1].strip()

sys_proxy_on = 'HTTPEnable : 1' in proxy_out or 'HTTPSEnable : 1' in proxy_out

# Tailscale
ts_ip = ''
try:
    ts_ip = subprocess.run(['tailscale', 'ip', '-4'], capture_output=True, text=True, timeout=3).stdout.strip().split('\n')[0]
except: pass
ts_running = pgrep('Tailscale')

PROXIES = [
    {'name': 'Surge',        'http': 6152, 'socks': 6153},
    {'name': 'Shadowrocket', 'http': 1080, 'socks': 1081},
    {'name': 'Clash Verge',  'http': 7890, 'socks': 7891},
    {'name': 'ClashX',       'http': 7890, 'socks': 7891},
    {'name': 'V2RayX',       'http': 1087, 'socks': 1087},
    {'name': 'sing-box',     'http': 2080, 'socks': 2080},
]

apps = []
active_app = ''
for p in PROXIES:
    name = p['name']; hp = p['http']; sp = p['socks']
    running = pgrep(name)
    installed = app_installed(name)
    if not running and not installed:
        continue
    hp_ok = port_open(hp) if running else False
    sp_ok = port_open(sp) if running else False
    is_active = (str(hp) == sys_http_port) or (str(sp) == sys_socks_port)
    if is_active and running:
        active_app = name
    apps.append({
        'name': name, 'running': running, 'installed': installed,
        'http_port': hp, 'socks_port': sp,
        'http_ok': hp_ok, 'socks_ok': sp_ok,
        'is_active': is_active and running
    })

if not active_app:
    for a in apps:
        if a['running']:
            active_app = a['name']; break

data = {
    'active_app': active_app,
    'sys_proxy_on': sys_proxy_on,
    'sys_http_port': sys_http_port,
    'sys_socks_port': sys_socks_port,
    'tailscale': {'running': ts_running, 'ip': ts_ip},
    'apps': apps
}
print(json.dumps(data, ensure_ascii=False))
"
