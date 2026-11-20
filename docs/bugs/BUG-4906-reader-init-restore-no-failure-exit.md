## BUG-4906 · 阅读器引擎初始化或初次恢复链抛异常时不回执，只能等8秒兜底
- **报告**：2026-11-20（路线图 #3722 c24 / gap-readerjs1-2，代码审读复核「部分成立」：没找到真实抛出路径，属加固）
- **真实性**：✅ 结构缺口（develop @ 7745effa2e）。分页 / 连续 shell 的初次恢复链
  `Promise.all(imagePromises).then(function() { buildNodeOffsets; applySentenceAudioCues; restore })`
  没有 catch（`fushi/lib/src/reader/reader_pagination_scripts.dart:3888`、`:4759`）：链里任一步同步抛出，
  promise 变成无人处理的 rejected，`onRestoreComplete` 永远不来；有声书 cue 应用（`:2476` `_sharedSentenceAudioInitJs`）
  抛出还会连带跳过后面的位置恢复。`initialize()` 自身抛出被 boot 包住（BUG-1017，`:2692`；VN 在
  `reader_visual_novel_scripts.dart:4016`、`:4024`）后同样只打日志。三种情况 Dart 都只能等 8 秒内容就绪兜底
  （`navigation.part.dart` `_startContentReadyTimeout`）才摘遮罩、解开导航态。
- **[x] ① 已修复** — cue 应用单独 try/catch、`console.error` 上报后照常恢复；初次恢复链加 `.catch` →
  `notifyRestoreFailed`，boot 的 catch（分页 / 连续 / VN）同样调用；`notifyRestoreFailed` 发带
  `navigationGeneration` 的 `onRestoreFailed`，每个文档只发一个结局（已发过成功回执不再补发）。Dart 侧注册
  `onRestoreFailed` → `_acceptRestoreFailed`（与成功回执同一代际判据）→ 与 8 秒兜底共用的 `_abortStalledRestore`
  （摘遮罩、`_failNavigation`、放行积压翻页、补 insets、落焦、起计时、提示）。`imagePromises` 未动。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_restore_failure_receipt_test.dart`（Node 真执行三种 shell
  生产文本：cue 抛出照常恢复、恢复 / 建表抛出发失败回执且带代际、成功后再抛不补发、boot 抛出发失败回执；Dart 侧接线
  源码守卫），JS 跑手 `reader_restore_failure_receipt_behavior_test.js`。
- **续修（异步抛出，路线图 #3722 遗留 L5）**：第一轮之后仍有两条到不了失败回执的路：
  ① 恢复入口（`restoreProgress` / `restoreToCharOffset` / `jumpToFragment`）都是 async 函数，第一个
  `await document.fonts.ready`（VN 是 `await this.ensureReady()`）之后抛的异常只让入口返回的 promise 变成 rejected，
  而初次恢复脚本没把它交回链（分页 / 连续 `_paginatedInitialRestoreJs` / `_continuousInitialRestoreJs` 调了不 return，
  VN `_initialRestoreJs` 在 boot 的同步 try 里调），链尾的 catch 根本接不到——所以第一轮的「恢复入口抛出」其实只覆盖
  了同步抛出；② 负责发回执的延后回调（分页 `_settleAndNotify` 的 setTimeout、连续 `_settleAndNotify` 与
  `restoreProgress` 章首 / 章末两条 setTimeout）里抛出，既不在入口 promise 里也不在链里。修法：分页 / 连续的初次
  恢复脚本 `return` 入口 promise 给链；VN 给入口 promise 接 `.catch → notifyRestoreFailed`；上述四个发回执的延后回调
  一律经 `_restoreCallback` 包一层（抛出即 `notifyRestoreFailed`，已发过回执的文档只记 `console.error`）。发回执的
  路径里没有 rAF 回调（逐个核过 `notifyRestoreComplete` 调用点）。测试：同一跑手新增 F（入口 await 之后 reject：
  分页 / 连续链、VN boot）与 G（分页 settle 回调、连续章首恢复回调抛出发失败回执，不抛时只发成功回执）；把修复按文本
  还原后 F、G 均红。
  **审查更正（VN）**：VN 不存在「干等 8 秒」——`initialize()` 的 readyPromise 成功分支与 fail-open 失败分支都先发
  onRestoreComplete（`reader_visual_novel_scripts.dart` `initialize`），入口的 `await ensureReady()` 之后才继续，所以
  入口在那之后抛出时回执早已发过，`notifyRestoreFailed` 不补发。VN 这条 `.catch` 的实际作用是不再留无人处理的
  rejection，并记 `console.error('[FushiVN] initial restore failed', …)`（原先只接 notifyRestoreFailed，而 VN 的
  notifyRestoreFailed 不打日志，异常被静默吞掉）。跑手 VN F1 按生产时序断言「已记日志、无未处理 rejection、只有成功
  回执」，F2 钉住回执尚未发出时的失败回执契约。
- **备注**：第一轮时「恢复函数里 rAF / setTimeout 回调中的**异步**抛出不在本修复覆盖内」，已由上面的续修补上。
  失败回执复用 `reader_content_timeout` 提示文案（「内容加载超时，如显示异常请重新打开」），是否另起专用文案待定。
  设备复测（paginated / continuous / vn 换章、往回翻）未做：本轮所有者定不做设备验证。
