# sogou-ime-debloat

一个脚本给 Windows 版搜狗输入法去广告、关汪仔、断遥测，只留打字。 Debloat Sogou Pinyin IME on Windows: no ads, no AI assistant, no telemetry, no binary patching.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011-blue?style=flat)](#用法)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue?style=flat)](#用法)
[![Tested: Sogou 15.5](https://img.shields.io/badge/Tested-Sogou%2015.5.0.2004-green?style=flat)](docs/how-it-works.md)
[![No binary patching](https://img.shields.io/badge/Binary%20patching-none-green?style=flat)](docs/how-it-works.md)
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

需要 Windows PowerShell 5.1 或更新的版本，执行时要有管理员权限。

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

脚本可以反复执行，已经处理过的项会显示 `SKIP`，任何一步失败时退出码非零。搜狗升级或重装之后再跑一次即可。

重启后在记事本、浏览器和一个商店应用里各打一段拼音，再打开一次搜狗设置，确认一切正常。

## 撤销

1. 删掉脚本留下的占位目录和占位文件（日志里每一项都有完整路径）。
2. 用搜狗官方安装包覆盖安装。
3. `sc config SogouSvc start= demand`
4. 删除 `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options` 下脚本建的那些项（Debugger 值是 `...\SogouDebloat-blocked\blocked.exe` 的）。
5. 删除计划任务 `SogouDebloat-EnvIni`、目录 `%ProgramData%\SogouDebloat`，以及名字以 `SogouDebloat block` 开头的防火墙规则（如果用过 `-BlockNet`）。
6. 如果还想要右键菜单，删除 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked` 下那两个搜狗 CLSID。
7. 解除 `%LOCALAPPDATA%\sogoupdf` 上的写入拒绝：`icacls "%LOCALAPPDATA%\sogoupdf" /remove:d %USERNAME%`

覆盖安装会把组件开关恢复成安装包里的默认值。

## 常见问题

**搜狗输入法怎么去广告、关掉弹窗？** 状态栏弹窗、服务端推送弹窗和右下角的系统通知广告都来自商业中心组件和 `biz_helper`、`sgtool.dll` 这一路。脚本把组件开关关掉，再把这几个文件占位，弹窗就不会再出现。

**怎么关闭汪仔（AI 助手）？** 脚本在全局组件配置里关掉汪仔和它捎带的腾讯本地文件索引，并让 `SGWangzai`、`SOGOUSmartAssistant` 无法再被装回或启动。

**联网表情包、图片表情能单独关吗？** 能，它们是独立组件，脚本会关掉并清空目录。本地图片表情会一起消失，颜文字保留。

**SogouCloud.exe 和 SGTool.exe 是什么，能删吗？** `SogouCloud.exe` 是云输入候选，默认保留，只去掉它里面的腾讯 AMS 广告 SDK，加 `-NoCloud` 才整个关掉。`SGTool.exe` 负责用户词库合并和设置界面，不能删，脚本只拿掉它动态加载的遥测和远程配置 DLL。

**搜狗升级以后广告又回来了怎么办？** 脚本禁用了 `SogouSvc` 和组件回装程序，又用 IFEO 按程序名拦截，新版本目录里的同名程序也起不来。真的升级或重装之后再跑一次 `-Apply` 即可。

**会不会把输入法弄坏？** 脚本不改任何二进制，只改注册表、组件配置和目录，所有改动都能按上面的「撤销」步骤还原。先不加参数跑一次演练，看清会改什么再执行。

搜索关键词：搜狗输入法 去广告、搜狗输入法 精简、搜狗输入法 纯净版、关闭汪仔、搜狗 弹窗 广告、搜狗 联网表情包、搜狗 自动升级 关闭、SogouCloud、SGTool、SogouSvc、Sogou Pinyin debloat、Sogou IME remove ads、disable telemetry。

## 说明

- 本项目与搜狗、腾讯无关。脚本只修改你自己电脑上已安装的软件。
- 脚本里的 AES key 和 IV 是从 `SogouComMgr.exe` 里分析出来的，只用来读写本机的组件配置文件。
- 风险自负。

---

## English summary

A PowerShell script that strips ads, the AI assistant, online stickers, the PDF suite, games, the desktop pet, toast ads and the self-update/re-install machinery from Sogou Pinyin IME on Windows, without patching any binary. It turns off components in the AES-encrypted global `ComponentConfig.ini`, disables `SogouSvc`, unregisters the shell extension, removes the Tencent telemetry and ad SDK DLLs, replaces bloat executables with same-named directories so nothing can write them back, and blocks them by name through IFEO so a new version directory does not bring them back. Run `SogouDebloat.ps1` for a dry run, then `-Apply` from an elevated PowerShell and reboot.

What stays: typing itself, user dictionaries and skins, `SGTool.exe` (dictionary merge and settings), cloud candidates (`SogouCloud.exe`, minus its Tencent AMS ad SDK; `-NoCloud` turns it off), voice input (`-RemoveVoice`), kaomoji (`-RemoveKaomoji`) and account sync (`-NoSync`). `-BlockNet` adds outbound firewall rules for SGTool and userNetSchedule. Everything is reversible; see the 撤销 (undo) section above. Tested on Sogou Pinyin 15.5.0.2004 (Windows 10/11, PowerShell 5.1+). Not affiliated with Sogou or Tencent.
