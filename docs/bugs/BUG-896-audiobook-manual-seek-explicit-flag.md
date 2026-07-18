## BUG-896 · 有声书暂停态手动 seek 后显式 seek 抑制旗不复位，cue/高亮卡住

- **报告**：2026-07-19（守卫审计批次：原 BUG-061 修复的回归缺口）。
- **真实性**：✅ 真 bug。根因在
  `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart`。链路——
  - 显式 seek 抑制旗 `_explicitSeekInFlight`（`:262` 声明，目标字段
    `_explicitSeekTargetFileIndex` / `_explicitSeekTargetMs` `:263-264`）由
    `_beginExplicitSeek()`（`:799`）置 true，`skipToCue` / `playCueOnce` 立起。
  - 暂停态下 `_updateCurrentCue()` 在显式 seek guard 内 `if (!_player.playing) return;`
    （`:1038`）早退，**永不清旗**——设计如此：暂停态没有真实播放推进，`reached`
    判据会被瞬态旧位置误判为「落定」，所以暂停时一律抑制、保留权威 cue、不清旗
    （BUG-061 的暂停分支）。清旗只发生在上下文边界（`setChapterCues` / 章节恢复
    `notifySectionRestoreCompleted` / 落定 tick `:1045`）与非 sasayaki 即时定位路径。
  - 但三条**手动改位置**路径不复位抑制旗：`seekMs`（拖进度条）、`seekRelative`
    （快进快退，转调 `seekMs`）、`noteManualReaderNavigation`（TOC / 链接 / 搜索 /
    书签 / 翻页）。
  - 缺陷时序：暂停态 `skipToCue` 立旗、记下旧目标 → 用户拖进度条 / 快进
    （`seekMs`）到新位置，旗仍 true、旧 `_explicitSeekTargetFileIndex` /
    `_explicitSeekTargetMs` 未更新 → 用户按播放后 `_updateCurrentCue` 仍以旧目标
    判据，在到达**旧目标**前持续抑制 tick → cue / 高亮卡在旧句。
- **[x] ① 已修复** — 新增私有 helper `_clearExplicitSeekSuppression()`
  （`:811`，`_beginExplicitSeek` 的逆操作：复位旗 false + 清 stale 目标为
  sentinel，维持「flag=false ⟺ 目标 sentinel」不变式）。在 `seekMs`（`:776`，seek
  **之前**调用——让 seek 引发的新位置 tick 不被抑制、立即跟随）与
  `noteManualReaderNavigation`（`:1253`）里调用，`seekRelative` 经 `seekMs` 自动覆盖。
  同时把原有两处上下文边界的裸 `_explicitSeekInFlight = false`（`setChapterCues`
  `:680`、`notifySectionRestoreCompleted` `:1235`）改走同一 helper，统一不变式。
  **不重引 BUG-061**：`skipToCue` / `playCueOnce` 仍照旧立旗，暂停态 guard 内
  `!_player.playing return`（`:1038`）与落定判据原样保留——加载期瞬态抖动抑制、
  暂停态精确定位不变；本修复只在「手动改位置」这一全新用户意图上复位抑制窗，
  没有在别处「不立旗」。改动文件：
  `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart`。
- **[x] ② 已加自动化测试** —
  `hibiki/test/media/audiobook/audiobook_manual_seek_explicit_flag_test.dart`
  （紧邻 BUG-061 姊妹测试 `paused_skip_transient_jumpback_test.dart`，复用同款
  just_audio 平台 mock；本测试的 fake 在 seek/load 时吐带 duration 的事件，让
  `seekMs` 能通过 duration 守卫）。覆盖：① 暂停态 `skipToCue` 立旗 → `seekMs`
  到新位置断言 `explicitSeekInFlightForTesting` 已复位、后续 tick 收敛到新 cue
  而非被旧目标抑制；② `noteManualReaderNavigation` 同样复位；③ 反向守卫——无手动
  seek 时暂停态瞬态 tick 不复位旗、权威 cue 不被覆盖（证明未过度清旗、不重引
  BUG-061）；④ 源码守卫钉住 `seekMs` / `noteManualReaderNavigation` 均调用
  `_clearExplicitSeekSuppression()`。
- **备注**：控制器新增 `@visibleForTesting bool get explicitSeekInFlightForTesting`
  暴露抑制旗供单测断言。「按播放后 cue 恢复跟随」的端到端观感需真机确认
  （needsDevice）。集成负责人统一跑 `dart format` / `flutter test`。
