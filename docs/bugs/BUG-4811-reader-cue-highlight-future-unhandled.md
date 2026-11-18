## BUG-4811 · 阅读器 cue 变更回调里放飞的高亮 Future 不接错误，WebView 销毁中抛出的异常成为未处理的异步错误
- **报告**：2026-11-17（用户：小说域优化清单 novel-17b，代码复核时发现，非用户现场报告）
- **真实性**：✅ 真 bug（代码路径确认 + 单测复现「裸放飞 → 未处理的异步错误」，未在真机抓到现场）。根因：
  - `fushi/lib/src/pages/implementations/reader_fushi/audiobook.part.dart` 的 `_onCueChanged` 是播放器 `addListener` 的**同步**回调，里面三处直接调 `AudiobookBridge.highlight(...)`（修复前 `:796` 跨章时清空高亮、`:839` SRT 书不跟随时清空高亮、`:870` 末尾带 cue 的跟随高亮），返回的 Future 既不 await 也不接错误。
  - `fushi/lib/src/media/audiobook/audiobook_bridge.dart:443`（修复前行号）`highlight` 内部 `await controller.evaluateJavascript(...)`，没有 try。WebView 正在销毁 / 换文档时平台调用抛出，异常沿这条没人接的 Future 变成未处理的异步错误（进 zone 的 uncaught handler）。
- **[x] ① 已修复**（9e3e7b92c7e）— 三处调用改成 `unawaited(AudiobookBridge.highlight(...).catchError(AudiobookBridge.logHighlightError))`：仍不 await（同步监听回调不能等），错误由 `AudiobookBridge.logHighlightError` 接住记进 `ErrorLogService`（来源 `AudiobookBridge.highlight`）。不重试——高亮是尽力而为的一次性视觉更新，下一次 cue 变更会重发。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/audiobook_highlight_unawaited_error_test.dart`「放飞的 AudiobookBridge.highlight 的错误出口」：假 WebView 控制器的 `evaluateJavascript` 抛错，接了 `logHighlightError` 时 zone 收不到未处理错误且错误日志多两条；对照用例证明裸放飞的同一个失败确实成为未处理的异步错误。「reader 的 cue 变更回调（源码守卫）」钉住 `audiobook.part.dart` 里每一处 `AudiobookBridge.highlight(` 要么被 await、要么紧跟 `.catchError(AudiobookBridge.logHighlightError)`（`_onCueChanged` 页面私有、行为驱动要真 InAppWebView，只能落在源码层）。
- **备注**：
  - 同样写法的第四处在 `fushi/lib/src/pages/implementations/reader_fushi/lyrics.part.dart:568`（退出歌词模式接回正文后的显式 reveal）。该文件当时被别的在途分支占着（`.worktrees/coordination/claims/` 里歌词相关 claim），本条没动，待那边合入后补同一处理。
  - 未做设备复测：触发条件是「cue 变更恰好落在 WebView 销毁 / 换文档的窗口里」，时序性的，无法稳定人工复现；修复不改变正常路径的调用时序与实参。
