# galgame 一键制卡 —— 后续实现交接（handoff）

> 面向接手的另一个 AI/开发者，**自包含**。总设计见 [design.md](design.md)。
> 已完成 A 阶段 Dart 基座 + native loopback + 波形桥 + C.1 注入组件（PR #212）。本文档给出**剩余任务**的落地路径：文件、接缝、gotcha、验证门。
>
> **迁移说明**：本文保留 2026-07-18/19 的历史实现证据；其中 `native/galgame_voice_hook/...` 均指迁出前路径。当前 native 实现在独立仓 `hajisensai/hibiki-hook`（对应 `hook/`、`injector/`、`include/`），新工作必须按 [Galgame Hook 引擎适配 SOP](../../agent/galgame-hooking.md) 和该仓现状定位，不能在 Hibiki 主仓重建旧目录。

## 落地进度

> A5/A6/C.2/C.4 的代码已落地。C.2/C.4 已在真实 32 位 KiriKiriZ 游戏跑通；2026-07-19 又在 SiglusEngine 1.1.141.3 正式版通过 DirectSound 混音捕获与 OVK 干净逐句语音验证。各引擎仍须逐个走原始路径，未覆盖者回退 loopback。

| 任务 | 状态 | 已验证（本地上界） | 仍需真机 |
|---|---|---|---|
| **A5** 波形选区 widget | ✅ 代码完成 | `galgame_waveform_select.dart`/`_dialog.dart` + 8 单测绿 | 目视：能画/能拖/返回值对 |
| **A6** 端到端一键 | ✅ 代码完成 | 接入 `texthooker_page.dart`；`slicePcmByMs` + 单测绿；`_captureGalAudioBytes` 串起 grab→选区→切片→编码→制卡 | galgame 热键→对话框→Anki 出卡（文本+可播音频+画面） |
| **A native 运行验证** | ⏳ 未验证 | loopback native 已编译 | 放声→`grabRecent` 返非零 PCM |
| **C.2** XAudio2 + DirectSound hook | ✅ 真机通过 | MinHook vendored；XAudio2 + DirectSound（含 `CoCreateInstance` 创建 DS）写环形；KiriKiriZ、Siglus x86 真机均读到 44.1kHz/2ch/16-bit 非静音 PCM | 继续覆盖其它引擎 |
| **C.4** EngineHookGalAudioSource+接回 | ✅ 真机通过 | `voice_hook_reader.{h,cpp}`+`app.hibiki.reader/voice_hook` channel（含 `processIsWow64` 与 `rawVoiceReady`）；`EngineHookGalAudioSource` 支持 PCM 与 Siglus raw-only Ogg；A6 已「引擎-hook 优先(按目标位数选 x86/x64 注入器)，不可用回退 loopback」 | 全 UI 热键→Anki 出卡仍可继续走查 |
| **C.3** 逐引擎覆盖 | 🟡 Siglus 已完成 | `SiglusEngine.exe` 专属 OVK 索引/Ogg 捕获，连续两句真机导出与原归档逐字节一致 | Artemis/Unity 等继续覆盖；KiriKiriZ 干净 per-channel 仍未做 |

**接缝提醒**：injector 可执行文件约定放在 app 同级 `voice_hook/<arch>/hibiki_voice_injector.exe`（`_resolveGalInjectorPath({is32Bit})`，按 `EngineHookGalAudioSource.targetIsWow64(pid)` 查目标进程位数选 x86/x64——**KiriKiri 多为 32 位必须 x86 注入器**），由独立仓 `hajisensai/hibiki-hook` 以 CMake（`-A x64` / `-A Win32`）构建后随包分发/按需下载；缺失/位数不符时 A6 自动回退 loopback。C.2 的**校准模式 callsite/音量精筛**是迁出前 TODO，当前应在独立仓 adapter/profile 中按真机证据实现，不应回填旧 `dll_main.cpp` 主干。

## ✅ 真机验证（2026-07-21，ceshi 素材批量制卡流程 + 端到端 AnkiConnect 落卡）

**素材清理（"删掉没句子音频的游戏"）**：逐个核对 `C:\Users\wrds\Downloads\Compressed\ceshi` 归档的逐句语音：

| 游戏 / 归档 | 引擎 | 逐句语音归档 | 处置 |
|---|---|---|---|
| 完全時間停止 特典：オフィシャル | 自研 NEKOPACK | `voice.pak` **只 2 条 ogg**（`se.pak` 才 1777 条 SE） | **已删**（正文无逐句语音，是特典赠品） |
| AngelBeats! trial | SiglusEngine | `koe/*.ovk`（29 个 OVK） | 保留（有语音；但非日文 locale 弹 "This Game is Japan Only" 挡门，进不去对白） |
| 天使☆騒々 RE-BOOT!（`bgimage/tenshi_sz.exe`） | KiriKiriZ | `voice.xp3` 2.1GB | 保留（本轮真机测试对象） |
| PRETTY×CATION2 バースデー vol.2（`pxc2_bc_vol2.exe`） | KiriKiri | `birthday_vol2.xp3` 322 条 `azu_*.ogg`（在バースデーアペンド） | 保留（有语音；主 exe 是壁纸/日历/时钟赠品菜单，默认不自动播语音→本轮抓到静音） |
| Sakura Swim Club | Ren'Py | `voice/*.ogg` 1791 条 | 保留（有角色语音，英文文本） |
| ChronoClock trial（`cmvs32.exe`） | CatSystem2 | `voice.cpz` 41MB | 保留（有语音；非日文 locale 弹 cp932 乱码框，进不去对白） |
| カスタムメイド3D2 CHU-B LIP（`.mdf`） | KISS 自研 | `voice_cbl_a/b.arc` 2.2GB | 保留（有语音；3D 换装/舞蹈，非文本对白 galgame，未安装磁盘镜像） |
| 姫様ＬＯＶＥライフ！（`HIMELOVE.ISO`） | AOS | `cv.aos` 675MB | 保留（有语音；未安装 ISO） |
| 恋愛フェイズ（`RENAIPHASE.ISO`） | 戯画自研 | 4.3GB ISO（未展开核对，戯画系语音作） | 保留（未安装 ISO） |

结论：**唯一真正"没句子音频"的是已删的完全時間停止特典**；其余都带逐句语音归档，不属删除范围（非日文 locale 或磁盘镜像未装只是"本机跑不进对白"，不是"无语音"）。

**制卡流程端到端真机（`integration_test/galgame_card_mining_test.dart` + 新增 `galgame_loopback_voiced_test.dart`）**：
- **管线机械链路全通**：native 音频捕获（loopback / voice_hook channel）→ WAV（44 字节头，Anki 直接播）→ WGC 窗口截图 → meta → 外层 `push_galcards.py` 经 AnkiConnect `storeMediaFile`+`addNote` → **6 张卡真进 `galgame_card_test` deck，`[sound:]`/`<img>` 媒体 `retrieveMediaFile` 可取回**（`notesInfo` 复核 6/6）。
- **诚实的质量边界**（本轮暴露，非管线 bug）：
  1. **"启动即抓" ≠ 有对白语音**。`galgame_card_mining_test` 只做"拉起→等 8s→抓 4s"，5 个游戏都停在标题/首启弹窗，抓到的是标题 BGM / 系统残留——SiglusEngine 与 tenshi 两张卡的 WAV **字节完全相同**（同一段 loopback 残留），pxc2 赠品菜单 **peak=0**（静音）。要真语音必须先把游戏驱动进对白行再抓。
  2. **驱动进对白后可抓到真游戏音频**：新增 `galgame_loopback_voiced_test.dart`（只 loopback 轮询、保留峰值最大一段），外层 `tenshi_drive.ps1` 先答掉 KiriKiriZ 首启弹窗（`#32770` No/OK，已持久化：二次启动直进标题）、再对 `TVPMainWindow` 客户区中心连点 137 次推进对白。捕获 **peak=0.5898 / rms=0.1395**（明显高于标题残留 0.3457，且字节相异），证明抓到了推进对白时的真实游戏音频。
  3. **KiriKiriZ 软件混音**：抓到的是"语音+BGM 混音"而非孤立干净语音（与 2026-07-18 otomeki 结论一致，KiriKiriZ 引擎-hook≈loopback）。干净逐句语音只对 per-voice buffer 引擎（Siglus OVK/DirectSound、XAudio2）成立。
  4. **部分引擎 WGC 截图拿不到画面**：天使☆騒々 的 D3D 硬件表面 WGC/PrintWindow 只截到菜单栏+白色画布（`tenshi_voiced.png` 空白）；同批 pxc2 的 GDI 标题画面则被 WGC 完整截到。硬件表面截图是既有限制，非本轮回归。
  5. **首启/locale 门**：AngelBeats(Siglus) 被 "Japan Only" 弹窗、ChronoClock(CatSystem2) 被 cp932 乱码框挡住，非日文 locale 机器上自动化进不到对白——engine-hook 干净语音路径在本机无法对这两个走查。

**未真机验证/后续**：① 各游戏"驱动进对白"仍是引擎专属脚本（KiriKiriZ 中心连点可用；Siglus/CatSystem2 需日文 locale 才过门）；② Siglus 干净 OVK 逐句语音本机未复现（AngelBeats trial 被 Japan-only 挡；已验证基线仍是 2026-07-19 anemoi）；③ 天使☆騒々 D3D 画面 WGC 截图空白待查（可能需 window vs monitor 捕获或 DXGI 路径）。证据：`hibiki/.codex-test/windows-itest/win-itest-20260721-15*`、dump 目录 `galcard-out/*.{wav,png,json}`。

## ✅ 真机验证（2026-07-19，SiglusEngine 1.1.141.3 / anemoi 正式版）

- 原始路径：`D:\anemoi\anemoi (正式版)\SiglusEngine.exe`，32 位 x86，SHA-256 `D94C94EB132FB1FCD6C20F35DD16552ED1301708B7A83DE07B275AD26C97D059`。
- Siglus 通过 COM 创建 DirectSound；补 `CoCreateInstance` 后，ring probe 实测 `sr=44100 ch=2 bits=16`、`peak=31799`、`total_written=89556000`，共享内存持续为非静音。
- Enigma 保护壳对 CREATE_SUSPENDED 极早注入并不稳定，复测曾直接报 `Internal Protection Error`。最终产品路径对 basename `SiglusEngine.exe` 改为：正常启动 → 等可见非 `The Enigma Protector` 游戏窗口 → 延迟附着；用户先开游戏再 `--pid` 附着也已真机通过。其它需要抢音频设备的引擎仍保留早注入。
- 保护壳会令 Toolhelp 线程快照失败，导致 MinHook `MH_EnableHook` 返回 `MH_ERROR_MEMORY_ALLOC`。vendored MinHook 增加 `NtGetNextThread` 枚举兜底，仍完整冻结其它线程，不采用不安全的“跳过冻结”。
- `koe/*.ovk` 格式已确认是 `u32 count + count × 16-byte index`，每项含 Ogg 字节数、绝对偏移与 voice id。文件 hook 只在读到索引精确命中的 `OggS` 起点时排队，工作线程重读完整 entry、验证 EOS 后落盘。
- 真实存档连续有声台词导出：`z6038.ovk#113616` 为 34,621 bytes / 2.576327s，`z6038.ovk#189706` 为 64,298 bytes / 4.301723s；均为 Vorbis 44.1kHz mono，导出 SHA-256 与 OVK 对应 entry 完全一致。由此证明是原始逐句角色语音，不含 DirectSound 输出端的 BGM 混音。
- 最终 DLL 对用户手动启动的进程晚附着后再次导出 `z6038.ovk#189706`（64,298 bytes），`reserved_luna=0xf3000000` 表示 hooks ready、OVK opened、voice queued/dumped 均命中。补完产品路径后，`hibiki_voice_injector.exe --launch "D:\anemoi\anemoi (正式版)\SiglusEngine.exe" --hold` 也成功正常进标题、延迟附着 pid、从存档导出 `586970156_z6038.ovk_189706.ogg`；该文件 SHA-256 `476F35F8A554A335910825D8D69A5C3C875E9E45A30E67289ADA7D3DB8FAEA58` 与 OVK entry 完全一致，并可转码为 44.1kHz mono AAC（53,816 bytes）。晚附着可能没有 DirectSound PCM/文本时间戳，因此 reader 新增 `rawVoiceReady`：Dart 保留引擎源，制卡优先精确时间配对；无时间戳则只选本 injector 会话之后最新的 Ogg，避免跨局误配。
- Hibiki Windows 集成测试在进入用例前被本机缺少 Windows SDK 10.0.26100 `GameInput.h` 阻断；这是仓库 `gamepads_windows` 已注明的构建前置条件，不是本次 Siglus 代码失败。native x86/x64、Dart 音频测试和真实晚附着路径均另行验证。

## ✅ 真机验证（2026-07-18，KiriKiriZ / `otomeki.exe` 32 位 DirectSound 游戏）

**捕获管线本身跑通了**（首个真实 galgame 验证）：
- 新增 injector **`--launch <exe>` CREATE_SUSPENDED 早注入模式**（`injector_main.cpp`）——KiriKiriZ 启动时创建一次 DirectSound 设备，post-hoc attach 会漏掉；早注入在游戏 WinMain 前把 hook 装好。新增 x64 诊断读取器 **`tools/ring_probe.cpp`**（`hibiki_voice_ring_probe <pid>`，读共享内存打印 hooked/格式/total_written/peak）。
- 实测：x86 injector `--launch otomeki.exe --hold` → `OK hooked hooked=1` → ring_probe 读到 **`sr=44100 ch=2 bits=16`、`total_written` 以 ~174KB/s（=44100×2×2，实时字节率）持续增长、`peak` 恒在数千（SOUND 非静音）**。证明：早注入命中、`DirectSoundCreate`→`CreateSoundBuffer`→`Unlock` hook 生效、干净 PCM 真的进了共享内存环形、外部进程可读。

**关键发现（诚实，影响 C-path 前提）**：捕获到的是**连续单流、恰好等于主输出字节率**——说明 **KiriKiriZ 是软件混音后走单个 DirectSound 输出 buffer**，故 DS-输出 hook 抓到的是**混音（标题界面=BGM）而非孤立干净语音**。即：**对 KiriKiriZ，引擎-hook 与 loopback 等效（都是混音），拿不到「干净语音」这个 C-path 卖点**。干净语音优势只对**每音/每 voice 独立 buffer** 的引擎成立（经典 KiriKiri 的 per-sound DS buffer、XAudio2 的 per-source-voice）。KiriKiriZ 要干净语音得 hook 其**引擎内部 per-channel 混音输入**（KiriKiriZ 专属，=C.3 深度活），或直接用 loopback（等效更省）。

**另一影响**：C.4 现设计是 Hibiki attach 用户已启动的游戏（post-hoc）——对 KiriKiriZ 这类**启动即建音频设备**的引擎会漏，必须 Hibiki 自己经 injector `--launch` 启动游戏才行（UX/设计取舍：Hibiki 拉起游戏 vs 附着到已开游戏）。

### launch 模式已接进 Hibiki（用户已确认「拉起游戏」这个取舍无所谓）

- **`EngineHookGalAudioSource` 加 launch 模式**：给 `launchExe`（而非 `targetPid`）即走 `injector --launch <exe> --hold`，从 injector stdout 的 `OK hooked pid=<N>` 解析游戏子进程 PID（纯函数 `parseInjectorHookedPid`），再 open 共享内存。`exeIs32Bit(path)` 读 PE COFF Machine 字段（0x014c=x86→true / 0x8664=x64→false）为**待启动的 exe**选 x86/x64 注入器（launch 时游戏还没进程，不能用 `processIsWow64`）。`gamePid` getter 暴露命中 PID。
- **texthooker UX**：AppBar 加「拉起 galgame（引擎-hook）」按钮（`_launchGalgameEngineHook`）——选 exe→按位数选注入器→拉起+早注入→就绪后以引擎-hook 为音频源，并按游戏 PID 从 `listWindows()`（已带 `pid`）找主窗口绑定（制卡截图）。失败明确 toast、不静默；起不来仍可用「绑窗+loopback」。
- 验证：analyze 0 issue、`galgame_audio` 37 测过（含 `parseInjectorHookedPid`/`exeIs32Bit` 单测）。

### ✅✅ 全链真机集成测试通过（2026-07-18，在真实 hibiki.exe 测试宿主内）

`integration_test/galgame_engine_hook_launch_test.dart`：在真实 hibiki.exe 里直接跑 `EngineHookGalAudioSource(launchExe).start()` → `injector --launch` 拉起 otomeki.exe → 早注入 → DirectSound hook → 共享内存环形 → **hibiki.exe 自己的 `voice_hook` native channel `grabRecent(3000)`**。结果：
```
GALTEST OK fmt=44100/2/16 float=false pcmBytes=529200   (=3s×44100×2×2，非静音；All tests passed)
```
即**整条 Dart 编排 + native voice_hook channel + 早注入 + DS 捕获在真实 app 进程里端到端跑通、抓到真实 3 秒非静音 PCM**（不再只是「Dart 编译验证 + 底层单独真机」）。

安全隔离（关键，供复现）：测试**不初始化 AppModel/Drift DB**（只 pump 平凡 widget），且经 `tool/run_windows_itest.ps1` 用 **`HIBIKI_TEST_ROOT`** 把数据根重定向到一次性 `isolated-root`——**绝不碰生产库**（`D:\APP\HIBIKI_date` 是 `data_root` pref 覆盖的产物；`HIBIKI_TEST_ROOT` 在 `_resolveSupportRoot` app_paths.dart:147-148 是**第一分支**、短路 pref）。且当前分支 schemaVersion=45，打开更高版本库会**抛 `HibikiDatabaseDowngradeException` 拒绝、不 DROP**（database.dart:403-420 已根因拦截旧红线）。测试用 env `GALTEST_GAME_EXE`/`GALTEST_INJECTOR` 指素材，缺则 skip（CI/无游戏机自动跳过）。生产 Hibiki 进程全程未受影响、游戏+injector 测后按 PID 精确收尸。

**仍未做**：干净语音（KiriKiriZ 软件混音 → DS 输出 hook 抓的是混音，非孤立语音；需引擎内部 per-channel = C.3）；波形选区对话框 + Anki 出卡的**全 UI**（原生 file picker 那段）焦点驱动走查。

### ✅✅✅ 多游戏端到端**真卡进 Anki**（2026-07-18）

`integration_test/galgame_card_mining_test.dart`：宿主内逐游戏 injector `--launch` 拉起 → 引擎-hook 抓（抓不到/静音回退 **loopback**，保证每游戏都有音频）→ 截窗口 → **dump WAV+PNG+meta 到 `GALTEST_OUT`**；外层脚本经 AnkiConnect `storeMediaFile`+`addNote` 推卡（runner 隔离环境里 Dart→AnkiConnect 不稳，故拆「宿主内抓+dump」与「外层推卡」）。实测 **4 张带可播放音频的卡进 `galgame_card_test`**：`otomeki.exe`(KiriKiriZ)=**engine-hook** 44100/2/16+截图；`pxc2_bc_vol2`(hibiki works)/`Sakura Swim Club`(Ren'Py)/`全年齢時間停止`(WAFFLE)=**loopback** 48000/2/32（这仨引擎非 DS/XAudio2 per-voice，引擎-hook 未命中→自动回退 loopback 混音，仍出卡）。

**gotcha**：① Ren'Py 顶层 exe 是启动器、真游戏是子 python 进程 → 引擎-hook 注入到启动器抓不到、`Process.killPid(启动器pid)` 杀不掉子进程（要按窗口 pid 补杀）。② PS `Start-Process -ArgumentList` **数组形式重引号打断含空格/方括号的游戏路径**，须单字符串 `--launch "<exe>" --hold`（Dart `Process.start(List)` 无此问题）。③ 直接 `flutter test -d windows` 缺 runner 的构建设置会 native-assets build 失败，须走 `tool/run_windows_itest.ps1`。

## 0. 当前状态（起点）

- **分支** `worktree-galgame-mining`（base `develop`），**PR #212（draft）**。仓库 `D:\APP\vs_claude_code\hibiki`（Melos workspace，Flutter app 在 `hibiki/`）。
- **工具链**：Flutter `3.44.0` / Dart `3.12.0`，路径 `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat`（不在 PATH）。CMake 4.x + VS2022（`flutter build windows` 与独立 cmake 均验证可用）。GitHub 走代理 `export HTTPS_PROXY=http://127.0.0.1:34151 HTTP_PROXY=http://127.0.0.1:34151`。
- **纪律（CLAUDE.md，强制）**：根因修复不打补丁；改前读最近的 `CLAUDE.md`；用独立 worktree；函数带类型注解；**声明「修好」前必须真机复测原始失败路径**；提交只 stage 本轮文件（禁 `git add -A`）；push 前跑全量 `flutter analyze`（CI 把 warning 当致命）+ `flutter test`。
- **已落地件（可直接依赖，均已单测/编译验证）**：
  - `hibiki/lib/src/mining/external_window_mining.dart` — `buildExternalWindowRequest({fields, sentence, screenshotBytes, audioBytes, audioName, ...})` 已透传音频。
  - `hibiki/lib/src/mining/galgame_audio_encode.dart` — `PcmFormat`、`buildWavBytes`、`pcmDurationMs`、`pcmSliceToAacBytes(...)`（PCM→WAV→AAC）。
  - `hibiki/lib/src/mining/galgame_audio_source.dart` — `GalAudioSource` 抽象、`GalAudioSlice`、`LoopbackGalAudioSource`（`app.hibiki.reader/audio_loopback` channel）。
  - `hibiki/lib/src/mining/galgame_waveform.dart` — `pcmToEnergyEnvelope(pcm, format)` → 逐窗 RMS dBFS。
  - `hibiki/windows/runner/audio_loopback_capture.{h,cpp}` — WASAPI loopback 环形缓冲 native（A 阶段音频源）。
  - `hajisensai/hibiki-hook` 独立仓 — C.1 注入组件（injector + hook DLL + IPC 契约；迁出前路径为 `native/galgame_voice_hook/`）。

## 1. 铁律（贯穿所有剩余任务）

1. **`providedAudioBytes` 引擎逐字节写盘不重编码**（`hibiki/lib/src/mining/immersion_mining_engine.dart:173`）→ 塞进制卡的音频**必须是已封装容器**（aac/m4a），裸 PCM 先过 `pcmSliceToAacBytes`。
2. **视频波形对话框 `SubtitleWaveformZoomView` 不可整体复用**——它是字幕对轴、产出 `delayMs`、无框选、音频硬绑 videoPath+ffmpeg。**只复用渲染层**：`SubtitleWaveformPainter` / `timeToX`（`hibiki/lib/src/media/video/subtitle_waveform_painter.dart`）+ `downsampleEnergyEnvelope`（`hibiki/lib/src/media/video/audio_energy_probe.dart:260`）。
3. **注入代码绝不进 `hibiki.exe` 本体**（报毒污染全 app）。`hajisensai/hibiki-hook` 独立仓构建/分发；hibiki.exe 只**读**注入组件建好的共享内存（读共享内存不是注入、不被标记）。
4. **音频 hook 回调零阻塞**（C.2）：回调里只 memcpy + 更新 `write_pos`/`total_written`，写盘/编码/锁/IPC 全部移出——回调阻塞即爆音。
5. **中文源码 native**：CMake 必须 `/utf-8`（否则中文 locale 下 MSVC 按 GBK 误读致编译失败；当前配置见 hibiki-hook 独立仓的 `CMakeLists.txt`）。

---

## 2. A5 —— 波形选区 widget

**目标**：给一段 `GalAudioSlice`，弹对话框画波形、用户拖一个范围选区、返回 `(startMs, endMs)`；VAD 给默认框。

**文件**：新增 `hibiki/lib/src/mining/galgame_waveform_select_dialog.dart` + 纯逻辑 `galgame_waveform_select.dart`（几何/VAD 便于单测）。

**接缝**：
- 数据：`pcmToEnergyEnvelope(slice.pcm, slice.format)` → dB 帧 → `downsampleEnergyEnvelope(frames, targetBuckets)` → 0..1 桶（喂 painter）。
- 渲染：`SubtitleWaveformPainter`（cues 传 `const []` → 只画波形+中线；见 painter `cueBoundariesMs` 空分支）。
- 交互：叠一层 `GestureDetector`，`onPanStart/Update` 把像素 x 反算成 ms（`timeToX` 的逆：`ms = (x / width) * durationMs`，`durationMs = pcmDurationMs(slice.pcm.length, slice.format.byteRate)`），产出 `RangeSelection(startMs,endMs)`。
- **VAD 默认框**（纯函数）：在 dB 帧上取阈值（如 `峰值 - 20dB` 或绝对 `-40dBFS`），找**最后一段**连续高于阈值的区间作默认起止（galgame 一句语音通常是缓冲尾部最近一段）。用户可拖动微调。

**gotcha**：`downsampleEnergyEnvelope` 吃 dB 帧不是 PCM（故有 `pcmToEnergyEnvelope` 桥）；桶数少时退化为 min/max 归一化，正常。

**验证门**：
- 纯函数单测（`test/mining/`）：像素↔ms 映射、VAD 默认区间（造响/静窗 PCM 断言默认框落在响区）。
- 真机目视：对话框能画、能拖、返回值正确。

---

## 3. A6 —— 端到端一键（A 阶段可交付里程碑）

**目标**：galgame 里按热键 → 抓 loopback 切片 → 波形选区 → 抓当前帧 → 制卡出「句子+句子音频+画面」。

**接入点**：`hibiki/lib/src/pages/implementations/texthooker_page.dart` 的外部窗口挖矿流（`onMineEntry` ~L81-140，现已做 `{截图+文本}→mine`）。**文本（`fields['sentence']`）和画面（`WindowCaptureChannel.captureWindow(hwnd)`）已现成**，只补音频这条线。

**数据流**（全部现成件串起来）：
1. 会话开始时 `LoopbackGalAudioSource().start()`（拿 `PcmFormat`），关闭时 `stop()`。
2. 热键：`grabRecent(backMs)`（如 8000）→ `GalAudioSlice`。
3. A5 对话框 → `(startMs,endMs)`。
4. **切片**（新增纯函数 `slicePcmByMs(pcm, format, startMs, endMs)`，帧对齐，可单测）→ 子 PCM。
5. `pcmSliceToAacBytes(pcm: 子PCM, format, tempDir, outputExtension: immersionMiningAudioExtension())` → aac 字节。
6. `WindowCaptureChannel.captureWindow(gameHwnd)` → png（点词时游戏画面）。
7. `buildExternalWindowRequest(fields, sentence, screenshotBytes: png, audioBytes: aac)` → `ImmersionMiningEngine.mine(req, compression, tempDir, repo)`。

**gotcha**：loopback 抓的是**混音**（BGM+语音），A6 交付的是「能用」的混音卡；干净语音是 C。`requireAudio` 由 `buildExternalWindowRequest` 在有音频时自动开。

**验证门**：真机 galgame，热键→对话框→Anki 里出卡（正面文本 + 可播音频 + 画面），留截图 + 卡证据。

---

## 4. A native 运行验证（补 A4 的运行门）

`flutter build windows` 已编译过 `audio_loopback_capture.cpp`。**运行**未验证：跑 app → `start()` → 放一段系统声音 → `grabRecent(3000)` → 断言返回非全零 PCM、格式合理（48k/2ch 常见）。可加一个 debug 页/日志钩子取证。静音包按零写（`AUDCLNT_BUFFERFLAGS_SILENT` 已处理）。

---

## 5. C.2 —— XAudio2/DirectSound 语音捕获 hook（C 的核心，需真实 galgame）

**历史位置**：迁出前为 `native/galgame_voice_hook/hook/dll_main.cpp` 的 `HookWorker`。当前实现位于 hibiki-hook 独立仓；按 `hook/adapter_registry.inc` 与 `hook/adapters/` 定位，不再往 `dll_main.cpp` 堆引擎逻辑。

**依赖**：引入 **MinHook**（MIT，与 GPLv3 兼容）做 inline/vtable hook。当前 vendored 位置是 hibiki-hook 独立仓的 `third_party/minhook/`。

**XAudio2 路径**（现代 VN 主流）：
- XAudio2 的语音接口是 COM vtable，`SubmitSourceBuffer` 不能 `GetProcAddress`。方案：hook `IXAudio2::CreateSourceVoice`（vtable 索引固定）→ 每次创建 source voice 时记下它的 `WAVEFORMATEX`（填 `SharedHeader` 格式）并 vtable-hook 该 voice 的 `SubmitSourceBuffer`。
- 拿到 `IXAudio2` 实例的途径：hook 导出的 `XAudio2Create`（`xaudio2_9.dll`/`xaudio2_8.dll`；旧版经 `CoCreateInstance`）→ 包裹返回的接口。
- `SubmitSourceBuffer` hook 内：读 `XAUDIO2_BUFFER`（`pAudioData`/`AudioBytes`/`PlayBegin`/`PlayLength`），把 `[PlayBegin,PlayLength)` 段 PCM **memcpy 进 `SharedHeader` 之后的环形缓冲**（`ring_capacity` 处起），单写者只推 `write_pos`（回绕）+ `total_written`（单调）——**只 memcpy，无锁无分配无 IO**，然后调原函数。首帧填 `sample_rate/channels/bits_per_sample/is_float/block_align`。
- 环形写逻辑照抄 A 阶段 `audio_loopback_capture.cpp` 的 `RingAppendLocked`（但这里单写者无需锁，volatile 即可）。

**DirectSound 路径**（旧引擎）：hook `IDirectSoundBuffer::Lock`/`Play`（或 `DirectSoundCreate`），同理在混音前取 buffer 段。

**校准模式**（`SharedHeader::calibrating`）：混音后分不清语音/BGM/SE，但引擎级能按**哪个 source voice/callsite** 分。首次识别产生角色语音的 callsite（抓一次调用栈 / 按格式启发式），让用户确认，存 `game.exe SHA + callsite RVA`；正常模式只捕获该 callsite，BGM/SE 连 memcpy 都不做。

**gotcha**：32 位游戏→x86 build（DLL 位数必须匹配）；部分引擎经 wrapper 用 XAudio2；anti-tamper 游戏可能拒注入；hook 装在工作线程（已避 loader lock）。

**验证门**：真实 XAudio2 galgame，注入 → 播一句语音 → 共享内存环形缓冲填入**非静音、与该语音吻合**的 PCM；主观听感无爆音/卡顿。无 galgame 不能声明 C.2 完成——别写没法验证的 hook 逻辑当完成。

---

## 6. C.4 —— `EngineHookGalAudioSource` + 接回 Hibiki

**目标**：Hibiki 用引擎 hook 的干净语音，复用 A 的同一波形选区 + 制卡出口。

**架构（隔离红线的落法）**：
1. Hibiki 主进程把 `hibiki_voice_injector.exe --pid <游戏PID> --hold` 当**子进程**拉起（注入这一步的报毒代码在隔离组件里）。
2. hibiki.exe **自己的** native（新增，如 `hibiki/windows/runner/voice_hook_reader.{h,cpp}` + channel `app.hibiki.reader/voice_hook`）**按名打开**共享内存（`SharedMemoryName(pid)`，契约源见 hibiki-hook 独立仓 `include/voice_hook_ipc.h`，runner 保持同步副本）→ `grabRecent(backMs)`：按 `write_pos`/`total_written`/`ring_capacity`/格式算最近 N 毫秒 PCM。**读共享内存不是注入、不被杀软标记**，可安全进 hibiki.exe。
3. Dart 新增 `EngineHookGalAudioSource implements GalAudioSource`（`galgame_audio_source.dart`），`grabRecent` 走上面的 voice_hook channel——**和 `LoopbackGalAudioSource` 同接口**，A5/A6 上层零改动。
4. 加「音频来源」开关：loopback(A) / 引擎 hook(C)，hook 不可用（未注入/无该引擎）自动回退 A。

**验证门**：真机 galgame，切到引擎 hook 源 → 出卡音频是**干净语音**（无 BGM）；hook 不可用时无缝回退 loopback。

---

## 7. C.3 —— 逐引擎覆盖

C.2 打通一个引擎后，按引擎补 callsite/接口差异（KiriKiri/吉里吉里、Artemis、Ren'Py、Unity、各自研）。每个引擎：识别方式 + voice callsite + 是否循环 buffer。未覆盖引擎自动回退 A。维护一张 `game.exe SHA/引擎 → callsite RVA` 表。

---

## 8. 建议顺序 & 依赖

```
A5 (波形 widget) ──► A6 (端到端一键，A 阶段可交付) ──► A native 运行验证
                                                        └► 先交付「能用的混音一键制卡」

C.2 (XAudio2 hook，需 galgame + MinHook) ──► C.4 (EngineHookGalAudioSource 接回) ──► C.3 (逐引擎)
     └► C.2 产出数据后 C.4 才有源可读
```

- **先把 A5→A6 做完**：这是用户能马上用上的「一键 + 波形选区 + 混音音频 + 画面」，价值最大、全可在本机+真机验证。
- **C.2 起需要一台装了目标 galgame 的 Windows**，且 hook 逻辑只能在真实游戏上验证——没有游戏别硬写。
- 每一步遵守：纯逻辑先抽出来单测；native 先 `cmake`/`flutter build windows` 编译；端到端必真机复测原始路径留证据。
