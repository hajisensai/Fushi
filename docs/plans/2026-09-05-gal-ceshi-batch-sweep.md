# ceshi 批量真机探针清单（2026-09-05）

**这份文档只记测量，不升任何引擎的 `current_status`、不加 `verified_games`。**
本轮全部停在 install / observe 阶段：没有一局跑过「字形命中 → 卡片渲染 → 制卡 E2E」。
按 `native/galgame_hook/CLAUDE.md` 的证据门，这类读数只够支撑
`process_found → helper_ready → ipc_ready → text_observed / resource_observed`，
不构成任何支持声明。

## 方法

不经 Fushi：`fushi_voice_injector --launch <exe> --workdir <dir> [--japanese-locale] --hold`
直驱，再用 `fushi_voice_lookup_probe`（它自己置 `lookup_enabled`）与 `fushi_voice_ring_probe`
读共享内存。这条配方绕开了「隔离 Fushi 每 1.25 s 抢前台」那个长期堵点。
脚本 `batch_probe.ps1`：每局开始前重查 `GetLastInputInfo`，用户一回到键盘立刻中止。

helper：x86 `7cdec3f936f6d042c8b7e140fb4b19cc6dcf5c3f3813b877b382cd67c902ad9f` /
x64 `1a4eba2de8793ecb886824bc7188fd30d3c27d60d4e78235bb8773227a1758a4`（双架构 CTest 62/62）。
所有诊断字都经 `galhook.py explain-diag` 符号化，未手拆十六进制。

游戏目录名含日文与全角，Windows PowerShell 5.1 处理这类路径到处是坑，
所以脚本一律按 **ASCII 的 exe 文件名递归搜索 + 路径最浅优先**定位，
避开非 ASCII 字面量；含空格的 exe 必须手工加引号（PS 5.1 的 `-ArgumentList`
数组是直接空格拼接的，`Sakura Swim Club.exe` 因此曾被 injector 看成三个参数
并报 `gameExeMissing`）。

## 结果

| 游戏 | 引擎 | 文本 | 音频 / 资源 | 游戏内查词传感器 |
|---|---|---|---|---|
| AngelBeats 体験版 | Siglus | `text_hooked=1`，Luna 已连，本局 0 条（标题画面） | — | ❌ `lookup_diag=0xB0000000`，只有 `siglus_profile_checked/executable_read/machine_matched`，**没有** `sensor_installed` |
| FORTUNE×WORLD 体験版 | Siglus | `luna_active=1`，`text_events=51` | `VisualArtsOvkHooksReady` + **`VisualArtsOvkCaptured`** | ❌ 同上，无 `sensor_installed` |
| Sakura Swim Club | Ren'Py | `text_hooked=1`，本局 0 条 | `FfmpegResourceHooksReady` | ✅ `lookup_diag=0xB0000041` = `sensor_installed` \| `expression_ready` |
| PRETTY×CATION2 vol.2 | KiriKiri | `text_hooked=1`，本局 0 条 | — | ✅ `0xB0000141` = `sensor_installed` \| `expression_ready` \| `classic_patch_installed`；exporter 走路径 ①（`reserved_luna` 无 `0x1000000`） |
| ATRI -My Dear Moments- | KiriKiri | `luna_active=1`，`text_events=2` | `KirikiriVorbisOpenHookReady`，`voice_clips=108`，PCM 48000/1/16 | ✅ `0xB0000041` = `sensor_installed` \| `expression_ready` |
| chronoclock 体験版 v2（`cmvs64.exe`） | CMVS | `text_hooked=1`，`text_events=1` | 无 CMVS 专属诊断位 | ❌ `lookup_diag=0x00000000` |
| アマカノ3 | Artemis | `luna_active=1`，`text_events=2` | **`ArtemisPfsHooksReady` + `ArtemisPfsVoiceCaptured`**，`voice_clips=12`，PCM 44100/2/16 | ❌ 该引擎未实现查词传感器 |
| manosaba Ver1.0.3 | Unity IL2CPP | `luna_active=1`，`text_events=474` | **`unity_events=1`**，`unity_last="Bgm_036_001_Loop"` | ❌ 该引擎未实现查词传感器 |

## 值得记的四条

1. **游戏内查词传感器的覆盖面本轮实质变了。** 修完 BUG-2121 四段 + BUG-2144 + BUG-2145 之后，
   `sensor_installed` 在 **4 个 KiriKiri 样本**（Fate/stay night[Realta Nua]、フタマタ恋愛、
   PRETTY×CATION2、ATRI）与 **Ren'Py（Sakura Swim Club）** 上都出现了。
   engine-support.yaml 里"游戏内查词只在带 textrender.dll 的 KiriKiri Z build 上存在"
   这句话在 install 这一层已经不成立。**但仍不改状态**：本轮没有一局做过命中/渲染/制卡。

2. **Siglus 的 exact profile 没命中这两个 build。** 两局都是
   `siglus_profile_checked` + `executable_read` + `machine_matched` 三个位都亮、却没有
   `sensor_installed` —— 即哈希 allowlist 里没有这两份 `SiglusEngine.exe`，
   落到 attached_calibrated 兜底，查词传感器随之缺席。这不是 bug，是 profile 覆盖面问题。

3. **アマカノ3 是 Artemis 的新标题且资源层真的抓到了**（`ArtemisPfsVoiceCaptured`）。
   yaml 的 `verified_games` 目前只有アマナツ体験版。要把アマカノ3 加进去必须走完整证据链
   （同会话内 文本 → 对应资源 → 配对 → 截图 → 真卡），本轮**没有**做，故不加。

4. **CMVS 目前读不出「adapter 是否命中并安装」。** chronoclock 上除了通用的
   startup/Luna 位之外没有任何 CMVS 专属诊断位，`lookup_diag` 全零。
   该引擎台账里写的 Next gate 是"探针 `cmvs probe=1 installed=1`"，但当前没有任何工具能
   打出这一对读数——这是诊断面的缺口，不是"探针失败"。补这个缺口应当是 CMVS 的下一步，
   与本仓其它引擎无关，须在 CMVS 自己的 worktree 里做。

## 顺带修掉的一个自造问题

第一局（AngelBeats，Siglus）读出 `xaudiodiag2=0x6000000c` =
`ExporterScanRan` | `ExporterScanNoCandidate` —— BUG-2145 新加的 KiriKiri exporter 扫描位
在 **Siglus** 进程上点亮了。行为本身正确（没有导出 `V2Link` 的模块，正确拒绝），
但 `ScanLinkedPluginsForExporter` 是被通用启动路径调到的，所有引擎都会走进来，
位在非 KiriKiri 进程上亮起就是**含义不实**。已改成凑不够 `kMinPlugins` 个插件时
一个位都不置，并加了两条守卫不变式 + 2 条变异自测。
同一个 AngelBeats、同一份 helper 复验：`0x6000000c` → `0x0000000c`。

## 未跑到的

- `STEINS.GATE.REBOOT`（SGRE）：本轮未跑；台账要求先在 1080p 窗口模式补测（BUG-2083）。
- 「昨日魔女今日的梦」：**Unreal Engine**（`Binaries\Win64\*-Win64-Shipping.exe` +
  `Engine\Extras\Redist` 标准布局），此前被记作 Unity，是**误判**。仓库 17 个引擎里
  没有 Unreal 家族，属真正的新引擎缺口，需要独立任务与独立 worktree。
- 8 个未解压的 ISO/MDS/RAR 目录（屋上の百合霊さん、カスタムメイド3D2、姫様LOVEライフ、
  恋愛フェイズ 等）：树里 0 个 exe，需要先挂载/解压才能进队列。

## 补记（同日稍晚）：未解压目录已分类 + SGRE 实测

上文「未跑到的」里那 8 个未解压目录，以及 SGRE，本轮都补上了。

### 光盘不必安装就能定引擎

`7z l <iso>` 列目录即可——游戏 exe 与归档通常就在盘上（只有整包 installer 的除外）。
再抽最小集（exe + 小归档，约 25 MB）做静态 probe，**不安装、不写注册表、不改系统**。
安装是用户的决定（改注册表/安装目录/可能要序列号），不无人值守地做。

| 盘 | 引擎 | 判据（实测） |
|---|---|---|
| カスタムメイド3D2 CHU-B LIP（KISS） | **Unity (Mono)** | `data\CM3D2OHx64_Data\Managed\*.dll`；x86/x64 双 exe；`data\GameData\*.arc` |
| 姫様ＬＯＶＥライフ！（Princess Sugar） | **AOS 系 —— 新引擎** | `bgm/cv/grp/scr/se.aos`；`.aos` 头 = 4 字节零 + 两个小端长度 + **归档自身文件名的 ASCII**；游戏 exe x86 862 KB，导入 DDRAW/DINPUT/DSOUND/d3d9/d3dx9_43。`cv.aos` 675 MB 是语音库 |
| 恋愛フェイズ（戯画） | **PAC 系 —— 新引擎** | 魔数 **`PACv`**（`Se.pac` 是 `PACu`，头后紧跟 `OggS`）；`RenaiPhase.exe` 节名随机化 + `.detour` 节 = **加壳**。`Voice.pac` 739 MB。**与仓库的 `qlie_filepack` 不是一回事**——QLIE 的魔数是 `FilePackVer` |
| 屋上の百合霊さん フルコーラス（ライアーソフト） | 未知 | 盘上只有 `INSTALL.EXE` + `INSTALL.DAT`，游戏在安装包里，不装就量不到 |

`_x_yurirei` / `_x_yurirei2` / `_x_renaiphase` 是上表前几项的重复副本，不是独立标题；
`[150925][戯画] 恋愛フェイズ` 目录里只有一个更新补丁 exe，正片在 `_x_renaiphase` 的 ISO 里。

这两个新引擎（AOS / PAC）在**只有静态身份**的那一刻都还不够建 adapter：按
`native/galgame_hook/CLAUDE.md` 的证据门那只到 `observed`。后来只读挂载原盘拿到运行期证据后，
**AOS 建了**（见文末）；**PAC 仍然没有**——它连不弹错误框都做不到（见「恋愛フェイズ：受阻」）。

### STEINS;GATE REBOOT（SGRE）

`sgre_steam.exe` x64，injector 直驱：

```
lookup_diag = 0x00200001 = sensor_installed | luna_known_hook_ready
xaudiodiag2 = SgreFamilyMatched | SgreAnchorsResolved   （不是 Unresolved）
hookdiag    = StartupAudioHooksReady | UnityResourceExtractorReady
              | LunaHostReady | LunaConnected | LunaOutputObserved
text_events = 11   voice_clips = 0（标题画面，未走台词）
```

injector 日志里 `known hook HQFN-24@328E0:sgre_steam.exe result=1`——钉定的 Luna hook 命中。
**这一局是默认显示模式**；BUG-2083 要求的 1080p 窗口模式补测**没做**，故不改 SGRE 的状态。

### Siglus 那两条「exact profile 未命中」已核实到哈希

上文只写了「哈希 allowlist 里没有这两份」，本轮把它核到底了（allowlist 在
`hook/adapters/siglus_lookup.h`，是**字节数组常量**不是十六进制串——按十六进制串去 grep
会抽出 0 条、得到一个什么也没证明的空集断言）：

| | SHA-256 |
|---|---|
| 钉定 anemoi | `d94c94eb132fb1fcd6c20f35dd16552ed130170b7a83de07b275ad26c97d059d` |
| 钉定 Summer Pockets RB | `190df9a72929bd6b6327e773952b5c507c69052bc6d3ff16a4868bd1ff1791fd` |
| 实测 FORTUNE×WORLD 体験版 | `03bf6429290ed2f2dabaf9bc4c0e42f1ca18dfe2d0bbf4e9cfbaaacd4f6e117e`（9604608 B） |
| 实测 AngelBeats 体験版 | `c09a0a415f2333fff53fe648245a268c6b15e9e40074d9c18ba0bed5c21dd0ee`（7666176 B） |

两份都不在 allowlist 里 → 落到 attached_calibrated 兜底，查词传感器随之缺席。
这是 profile 覆盖面问题，不是 bug。

### 顺带确证的一个跨引擎诊断缺口

`AdapterDiagnostics`（`id/applicable/installed/flags`）每个 adapter 都实现了，
但全仓**只有 `tests/adapter_contract_test.cpp` 在读**——运行期没有任何消费方。
于是**任何引擎**都读不出「adapter 是否命中并安装」；CMVS 台账里那条
「探针 `cmvs probe=1 installed=1`」的 Next gate 读不出来，不是探针失败，
而是这个只写接口的表现。补它要改 IPC 契约（升 `kSharedVersion` + 两侧同 PR），
本轮不动，单独立项。

### 恋愛フェイズ（PACv）：受阻，未推进

同样只读挂载原盘后直接起 `RenaiPhase.exe`：进程活着，但立刻弹
`ErrorMessageBoxClass`，按钮写着「誤動作回避ファイルダウンロード」——
要官方补丁/认证下载才跑得起来。`text_events=0`、`voice_clips=0`。
这不是能无人值守推进的边界，记为受阻，**没有**为它建 adapter。

### 已落地的两个新引擎

- **Unreal（IoStore）** → PR #1217，分支 `worktree-gal-unreal-kinomajo`
- **AOS / SFA（Princess Sugar 系）** → PR #1218，分支 `worktree-gal-aos-sfa`

两者都 `implemented_unverified`、`verified_games` 为空，逐门证据各自写在自己的台账里。
