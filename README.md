# NetWatch · 网络体检

> macOS 原生网络监控 + 翻墙安全检测 + ChatGPT/Claude 封禁风险评估

一个 24 小时挂在后台的 macOS 网络监控工具。每分钟给你的网络体检一次，断了自动弹通知告诉你"哪个环节坏了"。还能检测你的翻墙 IP 是不是容易被 ChatGPT/Claude 封号。

## ✨ 功能

### 🏠 网络健康监控
- **分层故障定位**：路由器 → 国内网站 → 翻墙软件 → 代理通道 → 国外网站，哪一层断了都告诉你
- **自动识别翻墙软件**：Surge / Shadowrocket / Clash Verge / ClashX / V2RayX / sing-box
- **系统代理检测**：自动读取 macOS 系统代理设置
- **24 小时时间线**：绿=通 红=断，一眼看出哪天哪个时段网络不稳
- **macOS 通知**：网络断了或恢复时自动弹通知

### 🛡️ 账号安全体检（一键检测）
- **IP 纯净度评分**（0-100 分）：5 个数据源交叉验证
  - [ip-api.com](https://ip-api.com) — 基础 GeoIP + hosting/proxy 标签
  - [ipapi.is](https://ipapi.is) — 精确数据中心检测 + 公司类型 + 滥用评分
  - [Shodan InternetDB](https://internetdb.shodan.io) — 开放端口 / 软件 / 漏洞
  - [StopForumSpam](https://www.stopforumspam.com) — 垃圾行为黑名单
  - [GreyNoise](https://www.greynoise.io) — 已知安全 / 已知恶意分类
- **被风控概率**：基于 IP 纯净度反算 + A/B 分层判决（硬信号 vs 软异常）
- **API 可达性测试**：直接请求 OpenAI / Anthropic / Google AI 端点
- **代理位置历史**：记录你翻墙后每次的出口地点。频繁换地点 → 风控警告 ⚠️

### 🎨 设计
- 原生 SwiftUI，Apple 浅色风格
- 大白话界面，小白也能看懂
- 关掉窗口不退出（留 Dock 后台继续报警）

## 📦 安装

### 方式 1：从源码编译
```bash
git clone https://github.com/julyyy-666/NetWatch.git
cd NetWatch

# 编译 GUI 应用
swiftc main.swift -o NetWatch \
  -framework SwiftUI -framework AppKit -framework Combine \
  -framework CoreFoundation -framework Foundation \
  -target arm64-apple-macos13.0

# 打开应用
open NetWatch
```

### 方式 2：安装后台监控服务
```bash
# 创建 NetWatch 目录
mkdir -p ~/Library/Application\ Support/NetWatch/logs

# 复制脚本
cp netwatch.sh risk_check.sh proxy_detect.sh ~/Library/Application\ Support/NetWatch/

# 安装 LaunchAgent（开机自启）
cp com.jianlin.netwatch.plist ~/Library/LaunchAgents/
cp com.jianlin.netwatch.risk.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.jianlin.netwatch.plist
launchctl load ~/Library/LaunchAgents/com.jianlin.netwatch.risk.plist
```

## 📊 评分系统

| 分数 | 等级 | 含义 |
|------|------|------|
| 85-100 | 🟢 低风险 | IP 干净，API 都能访问 |
| 70-84 | 🟢 中低风险 | 有些小问题但不太可能被封 |
| 50-69 | 🟡 中等风险 | 存在被风控的可能 |
| 30-49 | 🟠 较高风险 | 多个危险信号，建议换节点 |
| 0-29 | 🔴 高风险 | 很可能被封，立即更换 |

### 扣分规则（100 分递减）
- 数据中心 IP → -30 分
- 被标记为 VPN（≥2 源确认）→ -18 分
- Tor 出口节点 → -25 分
- StopForumSpam 黑名单 → -15 分
- 暴露 VPN 协议端口 → -15 分
- API 返回封禁信号 (403/451) → -30 分

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `main.swift` | SwiftUI GUI 应用源码 |
| `netwatch.sh` | 每分钟网络分层探测脚本 |
| `risk_check.sh` | 每 10 分钟安全风险评估脚本 |
| `proxy_detect.sh` | 翻墙软件自动识别脚本 |
| `com.jianlin.netwatch.plist` | 网络监控 LaunchAgent |
| `com.jianlin.netwatch.risk.plist` | 风险评估 LaunchAgent |

## 🔧 配置

编辑 `netwatch.sh` 顶部的可配置区：
```bash
SURGE_HTTP_PORT=6152    # Surge HTTP 代理端口
SURGE_SOCKS_PORT=6153   # Surge SOCKS5 代理端口
DOMESTIC_URL="https://www.baidu.com"
SLOW_MS=3000            # 国外慢于此 = 疑似限速
```

## 🖥️ 系统要求

- macOS 13.0+（Ventura 及以上）
- Apple Silicon（arm64）
- 已安装翻墙软件（Surge / Clash / Shadowrocket 等）

## 📜 License

MIT License - 自由使用和修改

## 🙏 致谢

本项目参考了以下开源项目的设计思路：
- [nitefood/asn](https://github.com/nitefood/asn) — 多源 IP 声誉查询
- [pwnnex/ByeByeVPN](https://github.com/pwnnex/ByeByeVPN) — 100 分递减评分模型
- [autumncry/netstats](https://github.com/autumncry/netstats) — macOS SwiftUI 网络监控架构
