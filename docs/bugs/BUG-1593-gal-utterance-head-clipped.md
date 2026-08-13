## BUG-1593 · galgame 制卡语音每句都少一截开头（提交时刻 vs 播放时刻）
- **报告**：2026-08-13（用户：制卡截取的音频都会漏掉前面 2s 左右的内容；游戏 `C:\Users\wrds\Downloads\Compressed\ceshi\恋爱成双`）
- **真实性**：✅ 真 bug，已在用户原始路径复现并量化。根因 `fushi/windows/runner/voice_hook_reader.cpp:1060`（原 `if (d < -200 || d > forward_ms) continue;`）。
- **[x] ① 已修复** — `native/galgame_hook/include/voice_hook_utterance_window.h`（新增，唯一实现）+ `fushi/windows/runner/voice_hook_reader.cpp`（`GrabUtterance` 改用它算下界）+ `native/galgame_hook/tools/ring_probe.cpp`（诊断工具共用同一份，避免排障被带偏）
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/utterance_window_test.cpp`（CTest 目标 `fushi_utterance_window_test`），fixture 全部是真机 dump 出来的时间轴；已做变异实测：把判据改成恒假，6 条断言里 4 条转红。
- **备注**：见下文。

### 台账（真实路径）

| 项 | 值 |
|---|---|
| 游戏 | フタマタ恋愛（恋爱成双 / 劈腿之恋）Ver1.00，KiriKiri2 / KiriKiriZ（`*.xp3` + `*.cf` + `plugin/`） |
| exe | `フタマタ恋愛.exe`，x86（machine 0x014C），SHA-256 `07A2A3D6AA665E3E2C4958FBF9FECFD93A5C9BAAC797813A152736B1EDBA3245` |
| 启动 | 用户原始入口：Locale Emulator（`フタマタ恋愛.exe.le.config`，ja-JP）。复现时用 `voice_hook/x86/fushi_voice_injector.exe --launch <exe> --japanese-locale --hold` |
| 进程 | injector 报 `LAUNCH pid=189452 arch=x86`、`profile=futamata-renai-jp`、`OK hooked ... hooked=1` |
| 文本链 | LunaHook / `ExtKAGParser.dll` 线程，`text_hooked=1` `luna_active=1` |
| 音频链 | DirectSound（每句语音**新建**一个 secondary buffer，source_ptr 每句都变），`48000/1/16`；另有一条长期存在的混音输出源 `48000/2/16` |
| 阶段 | `process_found → helper_ready → ipc_ready → text_ready → pcm_ready → paired` 全通过；结论建立在 paired 这一层，不涉及 `e2e_verified`，`engine-support.yaml` 不动 |

### 根因链

1. `VoiceClip::timestamp_ms` 是 hook 在音频回调里打的 **`GetTickCount64()` 提交时刻**（`native/galgame_hook/hook/dll_main.cpp:417`），不是这段 PCM 被听到的时刻。契约头里那句注释「该 clip 播放时刻」是错的，误导了下游所有判据。
2. 流式引擎必然**按缓冲深度提前提交**。KiriKiri 每句语音新建一个 DirectSound buffer，`Play` 之前把整个缓冲一次性灌满：实测**同一个 tick** 内连着写 `96000B`（1000ms 静音底）+ `4×12000B`（500ms 人声）= **1500ms 音频**。
3. 这一整块的提交时刻比 LunaHook 的文本时刻早 **219ms**（多句实测稳定 203–219ms）。
4. `GrabUtterance` 的窗口下界是写死的 `ts-200`。**219 > 200**，于是那 1500ms 整块**每一句**都出界被丢掉——不是偶发，是确定性地每句都少开头。
5. Dart 侧的增长收敛 `_settleLineUtterance`（BUG-1109）与封口 grab（BUG-1475）都只往**后**补，用的还是同一个 ts 和同一个下界，句首丢了就永远回不来。

### 修法

窗口下界不再是常量，改判「这段是不是被引擎**提前灌进去**的」：区间 `[j, i0)` 承载的音频时长若显著快于它被写入的墙钟跨度（`audio > 1.25 * wall`），说明引擎在按缓冲深度提前提交，这段属于本句开头，下界回退到那里；上限 `kUtteranceMaxBackMs = 6000`。

- **实时写入的混音 / BGM 源 `audio ≈ wall`（实测偏差 <10%），判据不成立，下界原样退回 `ts-200`——取音逐字节等价于旧行为。**
- 判据**不能**逐对比较相邻 clip 间隔：`GetTickCount64` 只有 ~15ms 粒度，同一游戏相邻两句量到的「突发块 → 流式段」间隔一边 62ms 一边 63ms。本修复第一版就是逐对阈值，实测在这点噪声上把一半句子漏掉了；第二版用累计队列模型，又在长流式源上失控（多吞 11750ms BGM）。两次都是真机对照跑出来的，不是推理。

### 真机验证（同一会话，仓库最终实现直接 include 进只读探针对跑）

| 台词 | 现行 | 修正后（裸 / 去静音） | 找回人声 |
|---|---|---|---|
| 「忘れもしないさ、あれは俺に初めての彼女が…」 | 5625ms | 7125 / 6001ms | +376ms |
| 「結愛が彼女紹介してって言うから…」 | 3500ms | 5000 / 3875ms | +375ms |
| 「彼女いっぱい作って遊んでる…」 | 3500ms | 5000 / 3875ms | +375ms |
| 「理由なんて考えず愛しまくればいい…」 | 3500ms | 5000 / 3873ms | +373ms |
| 「刺すんじゃなくて切り落とせば良かったのに」 | 3500ms | 5000 / 3888ms | +388ms |
| 旁白句（无角色语音，选到混音源）×3 | 6250ms | 6250ms | **0（逐字节不变）** |

丢掉的整块恒为 1500ms，其中 1000ms 是缓冲静音底（本来就会被去首尾静音吃掉），**可听的句首损失约 0.4s**——用户报的「2s 左右」是主观量级，实际丢的是每句开头一个词。

### 未解决 / 后续

- 无角色语音的旁白句（主角独白）会被能量选源判据选到混音输出源，取到的是 BGM。本次不动，另立条目。
- `VoiceClip::timestamp_ms` 的注释「该 clip 播放时刻」与实现不符，已在新头文件里把语义写清；契约头那行注释留待与 hook 侧一起改，避免本次 PR 动 IPC 契约。
- 相关：[BUG-1594](BUG-1594-ring-probe-readonly-map-crash.md)（排查本 bug 时撞到的诊断工具崩溃）。
