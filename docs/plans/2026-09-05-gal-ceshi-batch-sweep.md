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
