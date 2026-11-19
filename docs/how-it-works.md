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

文件内容是 base64，解开后是 AES-256-CBC 密文，key 和 IV 写死在 `SogouComMgr.exe` 里（脚本开头的常量就是它们）。明文前 16 字节是随机前缀，后面是普通 ini。每个组件有两段：

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

## 已知的限制

- 以管理员身份运行新版安装包，会把这些改动全部撤销。之后重跑一次脚本即可。
- 版本目录或组件版本号变了，脚本会自动找到新路径。
- 32 位视图里“此电脑”CLSID 下有一条右键菜单挂载项，归 TrustedInstaller 所有，删不掉。它指向的 CLSID 已经删除并拉黑，留下的只是一个空引用。
