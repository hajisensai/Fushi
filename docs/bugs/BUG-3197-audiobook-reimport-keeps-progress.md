## BUG-3197 · 重新导入字幕后有声书音频进度被重置
- **报告**：2026-10-09（群反馈，Android：给有声书重新导入字幕后，音频播放进度被重置，书的阅读页数不受影响；仓库所有者已确认理解）
- **真实性**：✅ 真 bug（代码路径推导 + 单测复现；未在用户设备上复现原始操作）。音频进度 `audiobook_pos_<key>` 存的是**全书毫秒**（`fushi/lib/src/media/audiobook/audiobook_controller.dart:668` `globalPosition` = 前面各文件「时长」之和 + 当前文件内偏移），但多文件有声书的「文件时长」不是音频真实时长，而是**从 cue 推出来的**（该文件内 cue 的最大 `endMs`，原 `_rebuildFileDurations`；`preload: false` 开书时拿不到真实时长）。开书恢复时按**当前 cue** 推出的时长把全书毫秒拆回（文件下标, 文件内偏移）（`audiobook_controller.dart:726` `splitGlobalMs`、`:889` 恢复 seek）。换一份字幕 = 换一组文件时长，同一个毫秒数就指向别的文件 / 别的偏移；新字幕把多文件 cue 全落在文件 0（单时间轴 SRT 在时长探测失败时不重分文件）时，整本直接被钳回第一个文件，用户看到的就是「进度被重置」。阅读页数存在 `reader_positions`，与 cue 无关，所以不受影响。两条写入路径都会把旧编码留下来：
  1. 库里的值：重新导入写 cue 的唯一入口 `AudiobookRepository.saveCues` / `SrtBookRepository.saveCues` 只整组替换 cue，不碰进度。
  2. 活会话：阅读器内重新导入后 `_resolveAudioSlot(forceReload: true)` 先 `session.stop()`，`stopPlayback` 按控制器手里的**旧 cue** 编码把当前位置再落一次库，然后新会话按新 cue 解码。
  与 PR #2023（`pr/interconnect-refetch-assets`，BUG-3098）不重叠：那边修的是互联包第二次导入撞 `UNIQUE(uid)`，没有改进度编码；它新增的「只更新字幕」（`importAudioSubtitlePackage`）直接调 `_db.replaceCuesForBook`，合入后也应改走本修复的换算（见备注）。
- **[x] ① 已修复** — 进度按真实时间位置（文件下标 + 文件内偏移）保留，只换编码，不按 cue 序号：
  - 新增 `packages/fushi_audio/lib/src/audiobook/audiobook_position_rebase.dart`：`audiobookFileDurationsFromCues`（cue 推文件时长的唯一口径，控制器 `_rebuildFileDurations` 改为调用它）+ `rebaseAudiobookGlobalPositionMs`（按旧时长拆、按新时长合，最后一个文件内的偏移不钳制）。
  - `AudiobookRepository.saveCues` / `SrtBookRepository.saveCues` 替换 cue 后调 `rebaseStoredPositionForCueChange` 换算库里的进度；**不盖** `audiobook_pos_at_` 时间戳（同一个位置换写法，不能让开书 LWW 无故偏向音频，BUG-2328）。
  - `AudiobookSession._stopInternal` 在 `stopPlayback` **之后**按库里当前那份 cue 给 stop 采样的位置换编码再落一次（`_reencodeAgainstStoredCues` → `AudiobookPlayerController.reencodeStoppedPositionForCues`，只有两边推出的文件时长不同才换），于是最后落库的是新编码；播放器本身的（文件, 偏移）不变。不放在 stop 之前：那要先 await 一次读库，`stopPlayback` 的同步采样 / 止声 fence / 位置写接链被推到异步缺口之后，`now_listening_mini_bar_exit_flash_test` 三条用例实测各吃满 10 分钟超时（PR #2032 首轮 CI 红）。
  - 单文件有声书天然不受影响（全书毫秒 = 文件内毫秒），换算对它是恒等。
- **[x] ② 已加自动化测试** —
  - `packages/fushi_audio/test/audiobook/audiobook_reimport_keeps_position_test.dart`：换算纯函数（多文件换编码、片尾不钳、单文件 / 0 恒等、时长推算）；`AudiobookRepository.saveCues` 换一份条数与切句都不同的字幕后，按新 cue 拆回仍是同一文件同一偏移、时间戳不变；同一时间轴不动进度；`SrtBookRepository.saveCues` 按 uid 键同样保留。去掉换算后该文件红。
  - `fushi/test/media/audiobook/audiobook_session_test.dart`「BUG-3197 stop re-encodes the live position against the replaced cues」：会话用旧 cue 恢复到文件 1 第 3 秒、库里换成新 cue 后 stop，落库值是新编码（12000 + 3000）。去掉 `_reencodeAgainstStoredCues` 后红。
- **备注**：
  - 未在 Android 真机复现原始操作路径（本任务按要求只开 PR）；根因与修复是平台无关的 Dart 层。
  - 已知剩余窗口：书架上重新导入字幕时，若这本书正在后台播放且之后进程被直接杀掉（没走 stop），期间周期写入仍是旧编码。重新进书时阅读器会把新 cue 灌进活控制器、编码随即切换，正常 stop 也会对齐，只有「不经 stop 直接被杀」这一种会留旧编码。
  - PR #2023 合入后，其 `importAudioSubtitlePackage` 写 cue 的地方应同样换算进度（复用 `rebaseStoredPositionForCueChange`）。
