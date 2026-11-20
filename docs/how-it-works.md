# 搜狗输入法是怎么把这些功能拉起来的

以下结论来自对 15.5.0.2004 版的静态分析（imports、字符串交叉引用、capstone 反汇编），以及在一台装好的机器上用 `tasklist /m` 和日志做的观察。地址只对这个版本成立，其他版本的结构应该差不多，偏移会变。

## 一句话版本

决定一个功能组件加不加载的，是全局文件 `Components\ComponentConfig.ini` 里各组件的 `enable` 字段，不是设置界面里的开关。

会把删掉的东西装回来的有三条路：
1. `SogouSvc` 服务：以 SYSTEM 身份静默写安装目录。
2. `SogouComMgr.exe`：发现组件缺失就重新下载，或者按计划升级组件。
3. 腾讯 Shiply 远程配置：通过 `SGBizLauncher.exe` 拉取，由 `biz_helper.exe` 执行。

把这三条路切断，再把组件的 `enable` 关掉，就不需要改任何二进制。

## 启动链

```
任意程序激活输入法
└─ SogouTSF.ime（TSF 外壳）                                                  [打字必需]
   └─ SogouPY.ime（x64 / x86 各一份，加载进每个用输入法的进程）              [打字必需]
      │  沙盒（AppContainer）程序里由 COM 服务 SogouImeBroker.exe 代为承载
      │
      ├─ 进程内 ComManager：读 Components\ComponentConfig.ini
      │    对每个 [bundleN] 段：enable≠0、文件存在、签名校验通过 → LoadLibrary 组件 DLL
      │    ├─ IChat\ichat_bundle(64).dll   AI 汪仔
      │    │     每天无条件拉起 SOGOUSmartAssistant.exe --panel=dailyreport
      │    │     附带腾讯电脑管家的本地文件索引 QMFileSearchCore.dll
      │    ├─ isgpet\isgpet_bundle(64).dll   宠物，满足条件时 isgpet.exe --panel=autorun
      │    ├─ PicFace\PicFace(64).dll        图片表情，联网拉表情包
      │    ├─ game_center\game_center.dll    游戏中心，每日上报
      │    └─ biz_center\biz_bundle.dll      商业中心，见下面 SGTool 子树
      │    组件文件缺失但 enable=1 → SogouComMgr.exe -retrieve（自修复，约 8 小时一次）
      │
      ├─ SGTool.exe -daemon        命令服务器；词库合并、设置界面也靠它，建议保留
      ├─ SogouCloud.exe -daemon    云输入；进程里还加载腾讯 AMS 广告 SDK libamssdk.dll
      ├─ userNetSchedule.exe       账号与词库云同步
      └─ 周期任务（位掩码分发）
           ├─ PinyinUp.exe -s                    升级
           ├─ SogouComMgr.exe -pinyinup -silent  组件下载与升级，会改写 ComponentConfig.ini
           └─ SGBizLauncher.exe -lappid=configupdate
                └─ shiply.dll → 腾讯 rdelivery 远程配置 → ProgramData\SogouInput\ShiplyUpdate

SGTool.exe -daemon
├─ everyhourtask：读远程任务表 hourtask_2，逐条交给 SogouComMgr.exe 执行，典型任务：
│    systoast check（系统通知广告）、dbpdf（PDF）、shellext update（重新注册右键菜单）、
│    imestatuspop（状态栏弹窗）、de run（下载并执行服务端下发的 res.dll）
├─ everydayPingback：SogouToolkits.exe -auto=1 等
├─ 状态栏弹窗：EnableImePop + 服务端开关 → SogouComMgr -invoke BizCenterCom --type=imepop
├─ ServerPopUp：加载 Data\Bin\sgutil.dll / sgtool.dll，每小时查一次服务端弹窗
└─ 用户点击类入口：汪仔、工具箱、AppBox、颜文字、截图

SogouComMgr.exe -invoke BizCenterComBundle → biz_helper.exe --type=...
├─ systoast：用户关掉通知后换一个带新后缀的 AUMID 继续发
├─ dbpdf：经 SogouSvc 提权安装 %LOCALAPPDATA%\sogoupdf（PDF 编辑器、预览处理器）
├─ shellext：regsvr32 重新注册 biz_shellext(64).dll（右键菜单）
└─ bundle inst：重新登记上面各项

SogouSvc（手动启动，靠 COM 按需拉起，以 SYSTEM 身份运行）
└─ 唯一能不弹 UAC 就写 Program Files\SogouInput 的通道，组件重装、升级、修复都走它
```

## ComponentConfig.ini

文件内容是 base64，解开后是 AES-256-CBC 密文，明文前 16 字节是随机前缀，后面是以 `[system]` 开头的普通 ini。密钥是搜狗程序里的一个内置常量。

仓库不附带这个密钥，脚本在运行时现场推导：

- CBC 的第二个明文块等于 `D(C2) xor C1`，跟 IV 无关。
- 所以脚本扫描本机已安装的搜狗核心程序（首选 `SogouImeBroker.exe`），把每个候选 32 字节当成密钥去解第二块，解出 `[system]` 的就是真密钥。整个过程约 1 秒。
- 写回时也不需要 IV：保留原文件的第一个密文块，后面各块以它为链接值重新加密。搜狗用自己的 IV 解第一块，得到的仍是原来的随机前缀。
- 密钥只在内存里使用，不写盘。

每个组件有两段：

```
[bundle7]
id=IChatComBundle
forceenable=1      ← 为 1 时组件会被强制启用，也要改成 0
...
[bundle7com0]
id=IChatCom
enable=1           ← 加载开关
```

在一台机器上实测过：`enable=1` 的组件全部被加载，`enable=0` 的一个都没加载。用户目录下另有一份同名文件里的 `[Active]` 段，只被写、不被读。

## 设置开关为什么管不住

- `HKCU\Software\SogouInput.store.user` 里的 `ichatenable`、`gamecenterenable`、`petautorun` 等，只决定入口显不显示，组件照样加载。这些值缺失时等于开启，所以只能写 0，不能删。
- 用户配置 `AppData\LocalLow\SogouPY.users\<编号>\env.ini` 也只管显示。
- 更麻烦的是，输入法把设置放在共享内存里，所有加载了输入法的进程共用一份，刷新时把整份写回 env.ini，写之前还会先去掉只读属性。所以只要还有程序加载着输入法，直接改文件就会被覆盖。脚本的做法是：注册一个一次性开机任务，在用户登录之前改文件，改完删掉自己。

## 脚本为什么不改二进制

分析里找到了可以直接 `ret` 掉的函数，比如 SGTool 里的弹窗例程和 hourtask 分发。但只要改过，Authenticode 签名就失效了。输入法加载组件前会校验签名，而 IME 在拉起 SGTool 之前会不会也校验，没有确认。上面那套“关开关、断三条回装路径、同名目录占位”已经足够，补丁用不上。

## 同名目录占位

把 `xxx.exe` 删掉，在原位置建一个叫 `xxx.exe` 的空目录。之后：
- 任何程序 `CreateProcess("xxx.exe")` 都会失败；拉起方只记一条日志，不会崩溃。
- 更新器、修复器想把文件写回来时，因为同名目录占着位置而失败。

组件文件夹反过来处理：把整个目录删掉，在原位置放一个同名的只读空文件，组件解包器就没法再建出这个目录。

## 第二轮：处理之后还剩什么

关掉组件之后，用线程入口地址、模块和日志又看了一遍（这一轮用的是 Codex），结论如下。

**SGTool 里的腾讯遥测 SDK。** SGTool 会动态加载 `beacon_sdk.dll`（灯塔上报）和 `qimei.dll`（设备标识）。处理前它的 49 个线程里，有 33 个入口在 beacon、4 个在 qimei。所有搜狗二进制的导入表和延迟导入表里都没有这两个 DLL，`SGTool.exe` 在 RVA `0x12d45a` 处检查加载结果，失败就走另一个分支。所以把它们换成同名目录后，SGTool 照常运行，线程数降到 9 个左右。

**SogouCloud 里的 AMS 广告 SDK。** `SearchCand.dll` 在 RVA `0x97ea6` 构造 `biz_center\<版本>\libamssdk.dll` 的路径，在 `0x97285` 调 LoadLibrary，找不到导出就返回 false。所以就算商业中心组件已经 `enable=0`，它照样加载。占位之后 SogouCloud 继续运行，云候选也保留。

**`shiply.dll`** 是腾讯 Shiply 远程配置 SDK，原本的使用者 SGBizLauncher 已经被拦，这里一并占位。

**仍在输入法本体里、没法单独拦的部分。** 下面这些代码都在 `SogouPY.ime` 本身里。它以 DLL 形式加载进每个用输入法的程序，防火墙按程序做规则时，没法把它的流量和宿主程序本身的流量分开：
- `http://ping.pinyin.sogou.com/smartinfo.gif` 和 `imechecksig.gif` 上报。x64 引用点在 `0xeb06f`、`0x14fb5d`、`0x151a32`、`0x19549a`。
- x86 版有 `http://ime.sogou.com/version.txt` 版本请求，引用点 `0x1301c5`，受一个配置字段门控。
- 生成 `--appid=pingbackbeacon` 命令交给 SGTool 去发。SGTool 里的 beacon 已经不在了，这条路发不出去。

要把这些也去掉，只能在 DNS 或代理层屏蔽 `ping.pinyin.sogou.com`、`ime.sogou.com` 这类搜狗专用主机，或者改二进制。不建议在全机 hosts 里屏蔽腾讯共用的域名（`rdelivery.qq.com`、`oth.eve.mdt.qq.com`），那样会连带影响别的腾讯软件。

**账号同步。** `userNetSchedule.exe` 不常驻，但每天会被拉起好几次。用不到同步就加 `-NoSync`。

**占用。** 处理后三个常驻进程（SGTool、SogouCloud、SogouImeBroker）合计私有内存不到 80 MB。每个宿主程序只映射 `SogouTSF.ime`、`SogouPY.ime`、`Resource.dll` 三个模块，不可共享的驻留页每个宿主只有零点几 MB。

## IFEO 拦截

占位目录只对当前版本目录有效。搜狗升级会装进一个新的版本目录，原来被拦掉的程序就回来了。脚本因此另外在 `Image File Execution Options\<程序名>` 下设 `Debugger`，指向一个不存在的路径。之后任何用这个文件名创建的进程都会失败，不管是谁、用 CreateProcess、ShellExecute 还是 COM 发起的。只拦 14 个搜狗专用的程序名，不碰 `crashrpt.exe`、`pdfsdk.exe` 这类别的软件也可能用的通用名字。IFEO 管不了 LoadLibrary，所以 DLL 仍然靠占位。

## 设置共享区

运行中的设置放在 `Local\sgime_env_fm1.v3.filemap.sogouime<后缀>` 这个共享内存段里，由 `Local\userenv.mutex.sogouime*` 几个互斥量保护。SGTool 的 `UserEnv::MergeSave`（RVA `0x698820`）流程是：合并、序列化回共享区、写文件、在映射头 `+4` 处 `lock xadd` 递增代际计数。外部程序要可靠地改运行中的设置，需要完整复现这套协议，目前还没解析完，所以脚本用的是开机任务。

## 签名校验

- IME 启动外部程序前确实会做签名检查：x64 启动包装器 `0x1ba610` → `0x1bccd0` → `0x1bfbd0` → `0x1d5240`。
- 组件 DLL 在 LoadLibrary 之前有一道独立的证书检查：x64 在 `0x2f2984`，用到组件目录里的 `certificate` 文件。
- `HWSignature.dll` 导出的是 `GenHWID`，是硬件标识生成器，本身不是验签函数。
- 注册表里的 `NoCheckSignature` 能放宽这整套校验，但不要去设它。

这也是脚本不改二进制的原因之一。
## 已知的限制

- 以管理员身份运行新版安装包，会把这些改动全部撤销。之后重跑一次脚本即可。
- 版本目录或组件版本号变了，脚本会自动找到新路径：优先取注册表 `HKLM\SOFTWARE\WOW6432Node\SogouInput` 的 `Version`。
- 32 位视图里“此电脑”CLSID 下有一条右键菜单挂载项，归 TrustedInstaller 所有，删不掉。它指向的 CLSID 已经删除并拉黑，留下的只是一个空引用。
