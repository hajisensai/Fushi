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
- **备注**：恢复函数里 rAF / setTimeout 回调中的**异步**抛出不在本修复覆盖内（不经过链），仍由 8 秒兜底收尾。
  失败回执复用 `reader_content_timeout` 提示文案（「内容加载超时，如显示异常请重新打开」），是否另起专用文案待定。
  设备复测（paginated / continuous / vn 换章、往回翻）未做：本轮所有者定不做设备验证。
