## BUG-4228 · 歌词模式下阅读器底部迷你播放条与悬浮工具栏留在歌词覆盖层上面
- **报告**：2026-11-07（用户：应用内反馈 zFSpGHJI2b，Android 3.3.0 手机；截图里歌词覆盖层下方叠着阅读器自己的有声书迷你播放条和底部悬浮工具栏）
- **真实性**：✅ 真 bug——底部 chrome 在主 Stack 里排在歌词覆盖层**之上**（`fushi/lib/src/pages/implementations/reader_fushi_page.dart:4533`，要盖住查词弹层），歌词模式只靠 `FushiChromeReveal(visible: !_lyricsMode && …)`（`reader_fushi/chrome.part.dart:3523`）把它藏起来。但同一层又被 `_coveredByLyricsOverlay` 包进 `TickerMode(enabled: !_lyricsOverlayShown)`（`reader_fushi/lyrics.part.dart:576`，BUG-4126 为省电停 Ticker）。进歌词模式时 `visible` 翻 false 与 TickerMode 关闭在同一帧发生，`FushiChromeReveal.didUpdateWidget`（`fushi/lib/src/utils/components/fushi_floating_toolbar.dart`）照常 `animateTo(0)`，弹簧的 Ticker 被静音、永远走不到 0：透明度停在 1、`Offstage` 判据 `v <= 0.001` 不成立，迷你条和工具栏一直画在歌词覆盖层上面。
- **[x] ① 已修复** — `FushiChromeReveal` 的显隐态不再依赖 Ticker 走完：`didUpdateWidget` 只在 Ticker 活着时做动画，`didChangeDependencies` 在 TickerMode 关掉时把两根弹簧直接落到目标值（也覆盖动画进行中被停的情况）。修在组件层，所有放在被停 Ticker 子树里的 chrome 一并受益。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_floating_toolbar_test.dart`：「visible=false 与 TickerMode 关闭同帧」后 chrome 不在树上、恢复后弹回完全不透明；「隐藏动画进行中 Ticker 被停」也收敛到隐藏。改前两条均红。
- **备注**：未在真机复测（按约定不做）；缺口是 Android 手机有声书进歌词模式后底部无阅读器迷你条 / 工具栏。
