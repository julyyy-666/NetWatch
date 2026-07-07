# NetWatch · 网络体检

一个放在 macOS 菜单栏里的网络体检小工具。

它会自动帮你看清楚：到底是 Wi-Fi / 路由器坏了，国内网络不通，代理软件没开，还是代理通道出问题。也能顺手给当前代理出口 IP 做个信誉体检，看它对 ChatGPT / Claude 这类服务的网络通道通不通。

> 说明：信誉体检只看这个出口 IP 干不干净、网络能不能通到服务，**不预测账号会不会被封**——封号取决于账号行为，不是 IP。

> 当前版本：v5.7 内测版
> 这是我个人 build 的第一个 vibecoding 产品，欢迎提意见、报 bug、提新需求。

## 下载安装

1. 打开 [Releases](https://github.com/julyyy-666/NetWatch/releases/latest)
2. 下载最新的 `NetWatch-vX.X.dmg`
3. 双击打开，把「网络体检」拖进「应用程序」
4. 第一次打开：在「应用程序」里右键点「网络体检」→「打开」→ 再点一次「打开」

第一次右键打开，是因为目前还没有做 Apple 公证。打开一次后，后面正常双击就能用。

打开后看屏幕右上角菜单栏，会出现一个小图标。点一下，就能看到网络、安全、历史、关于四个页面。

## 它能做什么

- 每 15 秒、30 秒或 1 分钟自动体检一次
- 自动判断是哪一层出问题：路由器、国内网站、代理软件、代理通道、AI 服务
- 自动识别常见代理软件：Surge、Shadowrocket、Clash Verge、ClashX、Loon、Quantumult X、V2RayX、sing-box、Hiddify 等
- 自动记录之前出过的问题，方便回头看
- 一键给代理出口 IP 做信誉体检（看 IP 干不干净、网络通不通，不预测账号封禁），给出大白话结果
- 「身份」页做一致性自查：系统时区 / 语言 / 已装中文字体是否与出口 IP 自洽（比如挂美国节点但时区还在上海、或装了方正等国产字体，就会提示穿帮），给出让环境自洽的建议；只减少「地区不一致」这类误判信号，不承诺不封号。其中时区是 Claude Code 命令行真会读的，字体只有浏览器登录 claude.ai 时才可能被网页 canvas 探到
- 有新版时，App 内可以自动下载、替换并重启

## 适合谁

- 经常分不清“是网断了，还是代理节点坏了”的人
- 经常用 ChatGPT / Claude，想知道当前代理 IP 是否稳定的人
- 不想看命令行，只想点开一个小窗口看结论的人

## 已知限制

- 目前是内测版，不是商业正式版。
- 第一次打开需要右键打开一次。
- 如果你的代理软件只开了 TUN / 增强模式，但没有开放本地 HTTP 或 SOCKS 端口，NetWatch 会提示“代理软件在跑，但端口没开”。这种情况下建议在代理软件里开启系统代理或本地端口。
- 如果 App 被系统或管理员权限安装在只读位置，自动更新可能无法静默替换，会保留旧版本并记录失败原因。
- 15 秒检测是 launchd 尽力而为，电脑休眠或低电量时可能被系统合并。

## 反馈

欢迎在 [Issues](https://github.com/julyyy-666/NetWatch/issues) 留言：

- 你用的是什么 Mac 和 macOS 版本
- 你用的是什么代理软件
- 菜单栏显示是否正常
- 哪个提示你看不懂
- 你还希望它加什么功能

## 开发者构建

```bash
git clone https://github.com/julyyy-666/NetWatch.git
cd NetWatch
scripts/build.sh
```

构建产物在 `dist/`：

- `NetWatch.app`
- `NetWatch-vX.X.dmg`

要求：macOS 13.0+，Xcode Command Line Tools。

## 项目结构

| 文件 | 说明 |
| --- | --- |
| `main.swift` | 菜单栏 App 和界面 |
| `netwatch.sh` | 网络分层体检脚本 |
| `risk_check.sh` | 代理 IP 安全体检脚本 |
| `proxy_detect.sh` | 代理软件识别脚本 |
| `scripts/build.sh` | 一键打包 `.app` 和 `.dmg` |
| `.github/workflows/release.yml` | 打 tag 自动出安装包 |

## License

MIT License

## 致谢

- [nitefood/asn](https://github.com/nitefood/asn)
- [pwnnex/ByeByeVPN](https://github.com/pwnnex/ByeByeVPN)
- [autumncry/netstats](https://github.com/autumncry/netstats)
- [LinXiaoTao/FuckClaude](https://github.com/LinXiaoTao/FuckClaude) — 身份页中文字体等检测信号清单参考
- [Azurboy/GeoMirror](https://github.com/Azurboy/geomirror) — 浏览器地区一致性信号思路参考
