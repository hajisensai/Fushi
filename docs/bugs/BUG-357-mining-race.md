## BUG-357 · 制卡并发race媒体/句子错配
- **报告**：2026-06-20（用户：TODO-644）
- **真实性**：✅ 真 bug（时序 race，单线程事件循环下隔离失效）。根因 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`：
  - `_prepareMiningContext`（`async`）在第一个 await `await TtsChannel.instance.extractAudioSegment(...)`（让出事件循环数百 ms）**之后**才读两个共享可变成员：`appModel.currentMediaSource?.currentCueSentence.text`（构造 `AnkiMiningContext.cueSentence`）和 `_cachedSentenceOffset`（构造 `AnkiMiningContext.sentenceOffset`）。
  - 第二次查词 `_handleTextSelected` 在其首个 await 前**同步**改写这两个成员：`setCurrentSentence` / `_syncCueSentence()`（写 `currentCueSentence`）+ `_cachedSentenceOffset = data.sentenceOffset`。
  - 快速连制两张卡（两个 mine button，popup.js 的 per-button guard 互不影响）→ 第一张卡 await 返回后读到第二个词的 cue 句 / 加粗偏移（错配）；若第二次中途 dismiss 清 null 则第一张丢失。
  - `onMineFromPopup` / `onUpdateFromPopup` 此前**无 in-flight 锁**，两次 prepare→mine 真正交错。
- **[x] ① 已修复** — 两步根因修复（commit 见末尾）：
  1. **await 前快照**：`_prepareMiningContext` 在 `extractAudioSegment` await 之前把 `currentCueSentence` / `_cachedSentenceOffset` 读成局部 `final snapshotCueSentence` / `snapshotSentenceOffset`，await 之后只用局部值构造 `AnkiMiningContext`（`reader_hibiki_page.dart` `_prepareMiningContext`，await 后不再读这两个成员）。消除「await 后读可变成员」整类。
  2. **制卡串行化**：抽出纯 helper `SerialTaskQueue`（`hibiki/lib/src/utils/misc/serial_task_queue.dart`，`enqueue` 把任务挂 Future 链尾，前一个完成含失败后才启动下一个，失败不阻断队列、不丢弃请求）；`onMineFromPopup` / `onUpdateFromPopup` 改 `return _miningQueue.enqueue(() => _onMineFromPopupInner(...))` 串行执行。排队而非丢弃 → 两张卡都正确。
  - 第 2 根因核查（媒体整项缺失）：ffmpeg 句子音频裁剪失败路径**非静默**——`extractAudioSegmentViaFfmpeg` 全失败分支（失败/超时/ffmpeg 缺失）都经 `onFailure` 回传 → `_prepareMiningContext` 命中 `if (requestedSentenceAudioClip && sasayakiAudioPath == null)` → 清理 + 记日志 + 弹 `card_export_failed_detail` toast + 返回 `context: null` 中止整张卡。不会产出无音频的成功卡。故媒体整项缺失若 race 修复后仍现，倾向真机上 ffmpeg 慢/缺失导致显式中止（非本次代码缺陷），待真机确认是否第 2 根因。
- **[x] ② 已加自动化测试** —
  - 行为（red→green）：`hibiki/test/utils/misc/serial_task_queue_test.dart`（串行化：第二任务在第一完成前不启动；快照各自正确不交错；失败不阻断后续；对照组证明未串行化会交错）。
  - 源码守卫：`hibiki/test/reader/reader_mining_race_guard_test.dart`（断言 `_prepareMiningContext` await 前快照、await 后不读 `currentCueSentence`/`_cachedSentenceOffset`、`AnkiMiningContext` 用快照值、制卡/覆盖经 `_miningQueue.enqueue`）。
  - 现有守卫同步更新：`hibiki/test/reader/reader_mining_audio_guard_test.dart`（sentenceOffset 改断言 await 前快照链）。
- **备注**：Dart 单线程事件循环，根因是隔离+时序，未引入更多并发。媒体整项缺失第 2 根因待真机确认。提交在分支 `todo-644-mining-race`，由 PM 合并，未 push、未合 develop。
