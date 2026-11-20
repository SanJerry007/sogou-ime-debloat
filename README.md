# sogou-ime-debloat

一个脚本给 Windows 版搜狗输入法去广告、关汪仔、断遥测，只留打字。 Debloat Sogou Pinyin IME on Windows: no ads, no AI assistant, no telemetry, no binary patching.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011-blue?style=flat)](#用法)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue?style=flat)](#用法)
[![Tested: Sogou 15.5](https://img.shields.io/badge/Tested-Sogou%2015.5.0.2004-green?style=flat)](docs/how-it-works.md)
[![No binary patching](https://img.shields.io/badge/Binary%20patching-none-green?style=flat)](docs/how-it-works.md)
[![Auto re-apply](https://img.shields.io/badge/Sogou%20updates-auto%20re--apply-green?style=flat)](#随搜狗更新自动重做)
[![Release](https://img.shields.io/github/v/release/SanJerry007/sogou-ime-debloat?style=flat)](https://github.com/SanJerry007/sogou-ime-debloat/releases)
[![Languages](https://img.shields.io/badge/Languages-%E4%B8%AD%E6%96%87%20%2F%20EN-blue?style=flat)](#english-summary)
[![Last commit](https://img.shields.io/github/last-commit/SanJerry007/sogou-ime-debloat?style=flat)](https://github.com/SanJerry007/sogou-ime-debloat/commits)
[![Stars](https://img.shields.io/github/stars/SanJerry007/sogou-ime-debloat?style=flat)](https://github.com/SanJerry007/sogou-ime-debloat/stargazers)

[中文](#sogou-ime-debloat) | [English](#english-summary)

---

给 Windows 版搜狗拼音输入法做减法：去掉广告弹窗、系统通知广告、AI 汪仔、联网表情包、PDF 编辑器和右键菜单、游戏中心、桌面宠物、腾讯遥测与广告 SDK、自动升级与回装，只留下打字本身。

不改任何二进制。做法是关掉全局组件开关，切断三条会把东西装回来的路径，用同名目录占住那些程序和 SDK 的位置，再用 IFEO 按程序名拦截，升级到新版本目录也照样生效。原理和启动链见 [docs/how-it-works.md](docs/how-it-works.md)。

在 15.5.0.2004 上分析和实测过，其他 15.x 版本的结构应该一致。

## 会去掉什么

| 功能 | 怎么处理 |
|---|---|
| AI 汪仔（含它捎带的腾讯本地文件索引） | 组件关闭，SGWangzai、SOGOUSmartAssistant 占位，组件目录换成空文件 |
| 联网表情包 / 图片表情 | 组件关闭，目录换成空文件 |
| 游戏中心、桌面宠物 | 组件关闭，目录换成空文件 |
| 状态栏弹窗、服务端弹窗、系统通知广告 | 商业中心组件关闭，biz_helper、sgutil/sgtool.dll 占位，通知注册删除并关闭 |
| PDF 编辑器、预览处理器、右键菜单 | 用它自己的卸载器卸载，目录加锁，右键扩展注销并加入系统黑名单 |
| 自动升级、组件回装、远程配置、推广装机 | SogouSvc 禁用，SogouComMgr、PinyinUp、SGBizLauncher、SGDownload 占位 |
| 腾讯遥测 SDK（灯塔 beacon、qimei 设备标识）、Shiply 远程配置 | DLL 占位。它们都是运行时动态加载的，SGTool 照常运行（实测线程数从 48 降到 9） |
| SogouCloud 里的腾讯 AMS 广告 SDK | libamssdk.dll 占位，云候选保留 |
| 崩溃上报、反馈、每日工具集 | crashrpt、sgfeedbackhelper、SogouToolkits 占位 |
| 以上程序换版本目录后重新出现 | IFEO 按文件名拦截：14 个搜狗专用程序名，Debugger 指向一个不存在的路径 |

## 会保留什么

- 打字本身：`SogouPY.ime`、`SogouTSF.ime`、`SogouImeBroker.exe`、词库、皮肤。
- `SGTool.exe`：用户词库合并和设置界面要用它。
- 云输入（`SogouCloud.exe`）。加 `-NoCloud` 可以关掉。
- 语音输入所在的工具箱 `SGSmartAssistant.exe`。加 `-RemoveVoice` 一起去掉。
- 颜文字 `SGKaomoji.exe`（纯本地）。加 `-RemoveKaomoji` 一起去掉。
- 账号与词库云同步（`userNetSchedule.exe`）。加 `-NoSync` 一起去掉。

加 `-BlockNet` 会给当前版本的 SGTool.exe 和 userNetSchedule.exe 加出站防火墙规则。默认不加，因为 SGTool 也负责下载细胞词库和皮肤。

代价：本地图片表情会和联网表情包一起没了；细胞词库不再自动更新；也不会再收到搜狗的安全更新。

## 用法

需要 Windows PowerShell 5.1 或更新的版本，执行时要有管理员权限。从 [Releases](https://github.com/SanJerry007/sogou-ime-debloat/releases) 下载 `SogouDebloat.ps1`，或者克隆本仓库。

推荐直接装成自动模式（见下一节）：

```powershell
# 精简一次，并在搜狗更新后自动重做（管理员 PowerShell）
powershell -ExecutionPolicy Bypass -File .\SogouDebloat.ps1 -Install
```

只想手动跑：

```powershell
# 先演练，只列出会改什么
powershell -ExecutionPolicy Bypass -File .\SogouDebloat.ps1

# 真正执行（在管理员 PowerShell 里）
powershell -ExecutionPolicy Bypass -File .\SogouDebloat.ps1 -Apply

# 只看组件开关表
powershell -ExecutionPolicy Bypass -File .\SogouDebloat.ps1 -ShowComponents
```

执行完重启一次。有两件事要等重启：
1. 正在运行的程序里还加载着旧的组件 DLL。这种情况下脚本会提示，重启后再跑一次 `-Apply` 收尾。
2. `env.ini` 的修改由一个一次性开机任务 `SogouDebloat-EnvIni` 完成。它在开机时以 SYSTEM 身份运行 `%ProgramData%\SogouDebloat\envini.ps1`（只有管理员能改这份脚本），改成功后删除自己，结果写进同目录的 `envini.log`。它通常在登录前跑完；开了自动登录的机器上可能和输入法加载抢先后，没生效就再重启一次。

脚本可以反复执行，已经处理过的项会显示 `SKIP`，任何一步失败时退出码非零。

## 随搜狗更新自动重做

搜狗升级会装进一个新的版本目录，组件可能被重新写回，配置也可能被恢复。`-Install` 就是为这个准备的：

1. 把脚本和你这次用的参数（比如 `-NoSync`）复制到 `%ProgramData%\SogouDebloat`，这个目录只有管理员能改。
2. 注册计划任务 `SogouDebloat-Watch`：每次登录时和每 6 小时，以你的身份、管理员权限、无窗口地跑一次 `-Auto`。
3. 立刻执行一次。

`-Auto` 就是带日志的 `-Apply`。什么都没变时全部是 `SKIP`，不会碰任何东西；搜狗被升级或修复过，它就把精简重做一遍。每次运行的完整输出在 `auto.log`，每次一行的摘要在 `history.log`，都在 `%ProgramData%\SogouDebloat`。

脚本本身不会从网上自动更新，因为让一个管理员权限的任务执行网上下载的代码风险太大。新版本发布后，下载下来重新跑一次 `-Install` 即可。

```powershell
# 取消自动模式，并删掉脚本注册的所有东西（任务、IFEO、防火墙规则、%ProgramData%\SogouDebloat）
powershell -ExecutionPolicy Bypass -File .\SogouDebloat.ps1 -Uninstall
```

重启后在记事本、浏览器和一个商店应用里各打一段拼音，再打开一次搜狗设置，确认一切正常。

## 撤销

1. 跑一次 `-Uninstall`：删掉计划任务、IFEO 拦截、防火墙规则和 `%ProgramData%\SogouDebloat`。
2. 删掉脚本留下的占位目录和占位文件（日志里每一项都有完整路径）。
3. 用搜狗官方安装包覆盖安装。
4. `sc config SogouSvc start= demand`
5. 如果还想要右键菜单，删除 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked` 下那两个搜狗 CLSID。
6. 解除 `%LOCALAPPDATA%\sogoupdf` 上的写入拒绝：`icacls "%LOCALAPPDATA%\sogoupdf" /remove:d %USERNAME%`

覆盖安装会把组件开关恢复成安装包里的默认值。

## 常见问题

**搜狗输入法怎么去广告、关掉弹窗？** 状态栏弹窗、服务端推送弹窗和右下角的系统通知广告都来自商业中心组件和 `biz_helper`、`sgtool.dll` 这一路。脚本把组件开关关掉，再把这几个文件占位，弹窗就不会再出现。

**怎么关闭汪仔（AI 助手）？** 脚本在全局组件配置里关掉汪仔和它捎带的腾讯本地文件索引，并让 `SGWangzai`、`SOGOUSmartAssistant` 无法再被装回或启动。

**联网表情包、图片表情能单独关吗？** 能，它们是独立组件，脚本会关掉并清空目录。本地图片表情会一起消失，颜文字保留。

**SogouCloud.exe 和 SGTool.exe 是什么，能删吗？** `SogouCloud.exe` 是云输入候选，默认保留，只去掉它里面的腾讯 AMS 广告 SDK，加 `-NoCloud` 才整个关掉。`SGTool.exe` 负责用户词库合并和设置界面，不能删，脚本只拿掉它动态加载的遥测和远程配置 DLL。

**搜狗升级以后广告又回来了怎么办？** 用 `-Install` 装成自动模式，升级或修复后它会在下次登录或 6 小时内自动重做。另外脚本禁用了 `SogouSvc` 和组件回装程序，又用 IFEO 按程序名拦截，新版本目录里的同名程序也起不来。

**会不会把输入法弄坏？** 脚本不改任何二进制，只改注册表、组件配置和目录，所有改动都能按上面的「撤销」步骤还原。先不加参数跑一次演练，看清会改什么再执行。

搜索关键词：搜狗输入法 去广告、搜狗输入法 精简、搜狗输入法 纯净版、关闭汪仔、搜狗 弹窗 广告、搜狗 联网表情包、搜狗 自动升级 关闭、SogouCloud、SGTool、SogouSvc、Sogou Pinyin debloat、Sogou IME remove ads、disable telemetry。

## 说明

- 本项目与搜狗、腾讯无关。脚本只修改你自己电脑上已安装的软件。
- 仓库里不带任何密钥。读写组件配置所需的密钥由脚本在运行时，从你本机已安装的搜狗程序里现场定位，只在内存里使用，不写盘。
- 仅供在自己的电脑上个人使用。
- 风险自负。

---

## English summary

A PowerShell script that strips ads, the AI assistant, online stickers, the PDF suite, games, the desktop pet, toast ads and the self-update/re-install machinery from Sogou Pinyin IME on Windows, without patching any binary. It turns off components in the AES-encrypted global `ComponentConfig.ini`, disables `SogouSvc`, unregisters the shell extension, removes the Tencent telemetry and ad SDK DLLs, replaces bloat executables with same-named directories so nothing can write them back, and blocks them by name through IFEO so a new version directory does not bring them back. Run `SogouDebloat.ps1` for a dry run, then `-Install` (or a one-off `-Apply`) from an elevated PowerShell and reboot. `-Install` copies the script to an admin-only `%ProgramData%\SogouDebloat` and registers the task `SogouDebloat-Watch`, which re-applies everything at every logon and every 6 hours, so Sogou upgrades and self-repairs are undone automatically; `-Uninstall` removes it again.

What stays: typing itself, user dictionaries and skins, `SGTool.exe` (dictionary merge and settings), cloud candidates (`SogouCloud.exe`, minus its Tencent AMS ad SDK; `-NoCloud` turns it off), voice input (`-RemoveVoice`), kaomoji (`-RemoveKaomoji`) and account sync (`-NoSync`). `-BlockNet` adds outbound firewall rules for SGTool and userNetSchedule. Everything is reversible; see the 撤销 (undo) section above. Tested on Sogou Pinyin 15.5.0.2004 (Windows 10/11, PowerShell 5.1+). Not affiliated with Sogou or Tencent.
