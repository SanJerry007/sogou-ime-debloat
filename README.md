# sogou-ime-debloat

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

## 说明

- 本项目与搜狗、腾讯无关。脚本只修改你自己电脑上已安装的软件。
- 脚本里的 AES key 和 IV 是从 `SogouComMgr.exe` 里分析出来的，只用来读写本机的组件配置文件。
- 风险自负。

---

**English summary.** A PowerShell script that strips ads, the AI assistant, online stickers, the PDF suite, games, the desktop pet, toast ads and the self-update/re-install machinery from Sogou Pinyin IME on Windows, without patching any binary. It turns off components in the AES-encrypted global `ComponentConfig.ini`, disables `SogouSvc`, unregisters the shell extension, removes the Tencent telemetry and ad SDK DLLs, replaces bloat executables with same-named directories so nothing can write them back, and blocks them by name through IFEO so a new version directory does not bring them back. Run `SogouDebloat.ps1` for a dry run, then `-Apply` from an elevated PowerShell and reboot.
