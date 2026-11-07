## BUG-4227 · 歌词模式切回阅读器再切回歌词，阅读器悬浮底栏（迷你播放条）浮在歌词页上
- **报告**：2026-11-07（用户：「歌词模式切换阅读器又切回去会导致阅读器的悬浮底栏出现在歌词模式里面」，附 Windows 截图）
- **真实性**：✅ 真 bug。阅读器悬浮样式底栏 `_buildFloatingBottomChrome`（`fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart:3523`）在歌词模式靠 `FushiChromeReveal(visible: !_lyricsMode && …)` 收起；而整条底栏外面包着 `_coveredByLyricsOverlay`（`reader_fushi/lyrics.part.dart:576`），覆盖层在场时 `TickerMode(enabled: false)`。首次进歌词时底栏通常本就收着（值 0）没事；从阅读器回来底栏已弹出（值 1），再进歌词那一帧 visible→false 与 TickerMode 关同时到达，`FushiChromeReveal` 的收起弹簧（`fushi/lib/src/utils/components/fushi_floating_toolbar.dart` `didUpdateWidget`）ticker 被静音、一帧都走不了，冻在 1——不透明、不 offstage，整条迷你播放条盖在歌词播放控件上。
- **[x] ① 已修复**（pr/lyrics-floating-bar-reveal）— `FushiChromeReveal` 新增 `_settle()`：ticker 不可用（`TickerMode.valuesOf(context).enabled == false`）时直接落到目标值，不起动画；`didChangeDependencies` 里 TickerMode 关掉时也把正在进行的动画走完。修在组件层，所有包在 TickerMode 关闭层里的 reveal 都不再冻在半路。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_floating_toolbar_test.dart`：「chrome reveal hides when tickers mute in the same frame」「chrome reveal settles when tickers mute mid-animation」。
- **备注**：未在真 app 上复测原始路径（歌词⇄阅读切换），待用户人眼确认。
