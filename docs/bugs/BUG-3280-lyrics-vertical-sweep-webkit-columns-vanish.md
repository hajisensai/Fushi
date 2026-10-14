## BUG-3280 · iOS竖排歌词播放时长句后几列消失
- **报告**：2026-10-10 应用内反馈 #AA5rY6cdvb（iOS 27.2 / iPhone：歌词模式竖排播放时，估计是句子过长，显示不全或者直接消失）
- **真实性**：✅ 真 bug（按代码路径与 WebKit 已知行为定位，未在 iOS 真机复现）。`fushi/lib/src/media/audiobook/lyrics_mode_html.dart:400-408`（修前）的逐字扫过规则给当前句 `.tx` 行内盒铺 `linear-gradient` + `background-clip: text` + `-webkit-text-fill-color: transparent`，靠 `box-decoration-break: slice` 让渐变跨行接续。WebKit 只实现前缀版 `-webkit-box-decoration-break`，且在 slice 下给 `background-clip: text` 的多段行内盒只在第一段铺背景（CSS-Tricks 等记录的「多行渐变文字只有第一行有」）。竖排长句会折成多列 = 多段，后几列文字透明、又没有背景可透 → 看不见。两个条件都吻合反馈：只在**播放**时出现（扫过只在 `:not(.ly-paused)` 时生效）、只影响**长句**（单列句子只有一段）。Blink（Windows / Android）正确实现 slice，不受影响。
- **[x] ① 已修复** — 加 `@supports not (box-decoration-break: slice)` 回退：不认识无前缀 slice 的引擎（WebKit）对扫过规则改用 `-webkit-box-decoration-break: clone`，每段各铺一份渐变，文字一定可见（代价是 WebKit 上多列同步扫过、不跨列接续）。按能力判，不按 UA / 平台特判。提交 `9880325ff1`（分支 `cc/fb-lyrics-mode`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_mode_feedback_batch_test.dart`（`BUG-3280` 组）：回退块存在、作用于扫过选择器、写 clone，且位于 slice 声明之后（同特异性后者胜）。
- **备注**：CSS 生成器层测试只能钉住规则；WebKit 真实渲染需在 iOS / macOS 上复测（本批没有 iOS 设备，未验）。
  - 2026-10-14 **iOS 模拟器实测这里的 clone 回退无效**：与 slice 一样整句消失。已改为把 `.tx` 变成 inline-block，见 BUG-3346。
