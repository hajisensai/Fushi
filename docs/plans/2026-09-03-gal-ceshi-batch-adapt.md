# 计划与台账：ceshi 文件夹 galgame 批量适配（SGRE → PXC2 vol.2 → 其余）

日期：2026-09-03。分支 `worktree-gal-ceshi-batch`（base `develop@443b8a2875`）。

## 用户要求（原话要点）

- 适配 `STEINS.GATE.REBOOT` 与 `PRETTY×CATION2 ラブラブバースデーコレクション vol.2`，尽量高的通用性。
- 游戏内单击查词 + 鼠标悬浮 Shift 查词；左键关闭查词弹窗时**不得**推进到下一句。
- 制卡要有视频、完整句子音频。
- 尽量不看 hook 代码（=优先在 profile / 消费端 / 验证层解决，hook C++ 只读不改）。
- 没安装的直接安装；这两个做完或堵塞后继续同文件夹其余游戏。

## SGRE 台账（SOP §2）

| 类别 | 事实 |
|---|---|
| 样本身份 | `SGRE/sgre_steam.exe` x64，SHA-256 `75a83a0e2a7e22055417ae0474b47be98418c4e42c695c548b558705c404b9d8`（= `kSgreKnownBuilds[0]` / `luna_hook_profiles.tsv` 行）；Steam 模拟 GSE（`steam_api64.dll`），`steam_settings/configs.user.ini` 语言由 english 改为 japanese |
| 进程身份 | Fushi 游戏详情页「启动游戏」→ `fushi_voice_injector.exe`（x64）+ `sgre_steam.exe`（三次会话 PID 41172 / 93332 / 94688，窗口类 `AdvEngine`，首屏全屏 3840×2160，后转窗口 1942×1136） |
| 组件身份 | 已装 Fushi 2.2.4-debug.13075（`D:\APP\Hibiki`，`data/app.so` 含 `_lookupExternal` = BUG-2019 修复在内）；helper x64 `installed.sha256 = 049d3cbd…`；探针 `fushi_voice_lookup_probe`（worktree build-x64）报 IPC v21 |
| 生命周期 | 点击启动 → 3 s 内 injector+游戏起 → 12 s 内 `sensor_installed,luna_known_hook_ready,sampled_input_shield_ready`；进入正文后 `geometry=2/5`（engine_exact_layout / SGRE） |
| 首个未通过边界 | 工作台首次启动停在「等待选择台词线程」（引擎精确线程未自动选，BUG-2068）；其余按下表 |

### 阶段证据

| 阶段 | 证据 |
|---|---|
| process_found | 启动器即本体：`sgre_steam.exe` x64（三次会话 PID 41172 / 93332 / 94688），窗口类 `AdvEngine` 由同一 PID 承载；injector 是它的父进程且不承载窗口/文本/音频 |
| helper_ready | helper x64 `installed.sha256 = 049d3cbd…` 已在目标会话就绪；diag 位 `sensor_installed,luna_known_hook_ready,sampled_input_shield_ready`（启动后 12 s 内） |
| ipc_ready | 探针 `fushi_voice_lookup_probe` 读到 `shm=Local\FushiVoiceHook_<pid> version=21`，生产者（helper）与消费者（Fushi）同时存活 |
| text_ready | 线程「SGRE exact · 0x35aa0」（hook code `ENGINE:SGRE:wind3d11`）逐句到达，与画面一致 |
| resource_ready | 「エル・プサイ・コングルゥ」配对 `voice_body.bin` xWMA（backend `game_resource`），AAC 3.19 s。证据等级只到 **captured**：**未记**与源 entry 的字节哈希一致性，**也未记**纯人声分类（`backend: game_resource` 只说明字节来自资源流，不构成「这 3.19 s 不含 BGM/SE」的证据），因此不得宣称 hash_verified / voice_classified |
| paired | 同一行条目文本 + 音频，工作台「音频就绪」 |
| e2e_verified | Anki note 1788374633826（Lapis）：Sentence `エル・プ<b>サイ</b>・コングルゥ`、SentenceAudio 52 KB AAC 3.19 s、Picture 480×270 AVIF 10 帧 1.25 s |

### 三条交互实测

| 交互 | 结果 |
|---|---|
| 悬浮 + 短按 Shift | 命中 → 游戏内弹卡（いて→射手、サイ→psi）；**授权点击风险前 hits 恒 0**（registry 未把 SGRE 设为 Active provider）——授权后才通 |
| 左键单击字形 | 命中 → 弹卡（話→はなし），台词不推进 |
| 点卡外关闭 | 8 次：7 次被 WH_MOUSE_LL + DirectInput 盾成对吞掉、台词不推进；**1 次泄漏**（会话中途刚点「确认点击风险」后的第一张卡，快速 60 ms 单击，VK_LBUTTON 读回按下 = LL 钩子没吞），新会话（授权由记忆恢复）首张卡未复现 |

## 本轮修改（host 侧，Dart）

- BUG-2067 列表显示折叠中间态：`texthooker_word_cache.dart`（id+文本判据）。
- BUG-2068 引擎精确线程自动选择：session `_maybeAutoSelectEngineExactThread`（`ENGINE:` 前缀，≥3 行）。
- BUG-2069 动图覆盖整句：`captureWindowGifBytes(targetDuration:)` + `galAnimatedFrameBudget`（8 s 上限）；资源音频路径写 `durationMs`（`adts_duration.dart`）；审查补 `trimSurplusAnimationFrames`（预算收缩后把多抓的帧在编码前裁掉，否则文档说的「null 退回旧行为」不成立）。
- BUG-2078 Ctrl 快进折叠：仅建档，本轮未修（根因未定）。
- `engine-support.yaml`：SGRE 状态保持 implemented_unverified（真相源有哈希钉住的结构化证据契约，本轮未产出该记录），E2E 证据写入 notes / evidence 文本。

## ATRI -My Dear Moments-（KiriKiri Z，第二款）

| 项 | 结果 |
|---|---|
| 身份 | `ATRI-MyDearMoments-.exe` x86，SHA-256 `4705821E…A58A48E3`，KiriKiri Z 1.2.0.3，`wuopus.dll` 语音，DARKSiDERS Steam 模拟（`ds.ini` Language 由 schinese 改 japanese；首启游戏内把 Main Text 切到日本語） |
| 启动 | 库内启动（先经「导入 → 添加游戏」文件对话框让库刷新）→ 早注入、已转区 CP932、`sensor_installed`、几何 provider KiriKiri TJS（runtime_layout） |
| 线程 | 需手选「TextRender · 0x6e0bc571」（EmbedKrkrZ / KiriKiriZ 线程混入系统串或逐字重绘），干净 |
| 查词 | 单击字形 → 命中 → 直接路由弹卡（の / はい）；点卡外（真实 mouse_event）→ LL 钩子吞掉、卡关闭、台词不推进（2/2） |
| 制卡 | note 1788380145993：Sentence 「……<b>はい</b>」、Picture AVIF、SentenceAudio = **5 s 系统混音降级**（`engine_utterance_unavailable`，75 条全部降级）→ BUG-2070（wuopus 语音未进资源/PCM 路径，需 native 侧另开） |
| 观察 | Ctrl 快进时 TextRender 连续重绘被折叠成一条超长台词（已拆出 **BUG-2078**，现象已观察、根因未定） |

## 未做 / 堵塞

- SGRE：逐句资源音频的**字节哈希一致性**与**纯人声分类**两项证据未采（yaml evidence 已显式写明缺失）；DirectInput 盾 1,000 次交易门未跑；那 1 次泄漏未定根因（怀疑 needsRiskAcceptance→activeNative 正边沿与首张卡 Reveal 的 LL 钩子装配竞态，需要在改代码前先做可复现实验）；新构建真机复验三条 host 改动待做。
- PXC2 vol.2：`pxc2_bc_vol2.exe` 是 KiriKiri2 光盘 autorun 菜单，`main_data/` 只有 patch1~5 + `birthday_vol2.xp3`，要复制进 `PxC2.exe` 目录；本机三个副本都没有本体 → 堵塞（需要 PRETTY×CATION2 本体，KiriKiri Z + E-mote，走 `kirikiri_z`）。
- 其余游戏（盘点见任务 #3）：未开始。

## 风险
- 驱动真游戏会占用用户桌面焦点；只用窗口模式、PostMessage 不夺前台。
- 不得把游戏素材当测试资产提交；证据只留元数据/哈希/必要截图（`.codex-test/` 不入库）。
