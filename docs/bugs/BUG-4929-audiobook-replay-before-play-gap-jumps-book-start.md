## BUG-4929 · 有声书开书未播放时「重播本句」/「下一句」落在句间静音就退回全书第一句
- **报告**：2026-11-17（应用内反馈 Y7g59hUCPn，iOS，单个 m4b 有声书，歌词模式：「打开书还没播放就误按了重播本句，没播当前句，而是把有声书重置到了整本书的第一句；跳转记录也没记这次跳转，回不到原位置」）
- **真实性**：✅ 沿真实代码路径确认（未在设备上复现）。
  - 开书时 `load()` 已把播放器 seek 到恢复点，但当前句只由 `_updateCurrentCue` 填充；它在句间静音（`findCueIndex` 返回 -1）里只「保持上一句」、不新定位（`fushi/lib/src/media/audiobook/audiobook_controller.dart:2418` `if (idx < 0) return;`）。开书还没播放时没有「上一句」可保持，恢复点又常落在句间（暂停 / 3 秒节流落库的位置），于是 `_currentCueIndex` 一直是 -1。歌词层高亮走 `_allBookIndexAt`（gap 取刚播完那句），所以用户看到的是正确的当前句。
  - `replayCurrentCue`（`audiobook_controller.dart:2152`）在 `_currentCueIndex < 0` 时按位置解析，走 `_cueIndexAtFilePosition`（`audiobook_controller.dart:3106`，修复前）：只认句区间命中，gap 一律退到「该文件首句」。单文件 m4b 的该文件首句就是全书第一句（截图里的「表紙」）。`skipByCues` 共用这个起点；`_nextCueIndex`（`audiobook_controller.dart:3122`，修复前）同样在 gap 里退到该文件首句，「下一句」也会被拽回书首。
  - 跳转记录：分诊说 `playCueAndContinue → skipToCue` 不记跳转历史，与代码不符——`skipToCue` 在 seek 前经 `_reportAudioJump` 报 `onBeforeAudioJump`，只是跨度要不小于「返回原位置的跳转距离」（默认 2 分钟）。恢复点离书首不到阈值时这次误跳不进历史，属阈值设计内行为；根因修掉后重播落在当前句附近，本就不是跳转。
- **[x] ① 已修复** — 新增 `_startedCueIndexInFile`（`audiobook_controller.dart:3078`）：在当前文件那一段里取起点不晚于位置的最后一句，与 `_updateCurrentCue` 的「gap 保持上一句」、歌词层 `_allBookIndexAt` 同一口径。`_cueIndexAtFilePosition`（重播 / 跳句起点）在 gap 里取刚播完那句，只有该文件还没有句子开始时才取该文件首句；`_nextCueIndex` 在没有当前句时取刚播完那句的后一条（尾部静音跨到下一个文件首句、全章最后则是边界）。`_prevCueIndex` 本就按「最近一条已开始的句」取，不动。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_replay_cue_button_test.dart`（未定位到句 + 句间静音 / 末句之后重播刚播完那句、早于首句重播首句、跳句起点与下一句同口径）；`fushi/test/media/audiobook/audiobook_cue_playback_order_test.dart`（多文件：gap 下一句取后一条、早于文件首句取该首句、尾部静音跨到下一个文件；旧用例「gap 下一句回本文件首句」按新口径改写）。
- **备注**：iOS 真机未复测（按会话约定不做真机验证）；修复以纯决策单测为准。
