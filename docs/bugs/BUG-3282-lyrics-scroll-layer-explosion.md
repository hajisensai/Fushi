## BUG-3282 · 歌词滚动帧率低
- **报告**：2026-10-11 应用内反馈 #mXdnw8AFLi（Windows：歌词滚动帧数低并且不支持无极滚动）
- **真实性**：✅ 真 bug（两处，按代码路径定位；未在真机量帧率）。
  - `fushi/lib/src/media/audiobook/lyrics_mode_html.dart:344`（修前）`will-change: transform, opacity` 挂在裸 `.cue` 上：歌词页最多 600 行（`kLyricsModeMaxInitialCues`），每行都被提升成独立合成层且不能合并，滚动 / 换行时合成器要搬几百张图层。真正会动的只有当前行 ±3（`setCue` 只改这个窗口的 class）。
  - 「不支持无极滚动」：`lyrics_mode_html.dart:634-642`（修前）竖排把滚轮纵向量投影成横滚时直接 `scrollLeft -= px`，一格滚轮 100px 瞬移，是一顿一顿的有级滚动；横排走浏览器原生平滑滚轮没有这个问题（反馈人同时报了竖排查词问题，用的是竖排）。
- **[x] ① 已修复** — `will-change` 只给 `.cue.current` 与 `.near-1..3`；竖排滚轮量累加进目标位置，按帧指数逼近（`__lyricsWheelStep`，连续滚只推远目标、顶到边界即停，「减弱动态效果」下仍一步落位），程序化回中（`scrollToCenter`）接管时停掉在途滚轮动画。提交 `9880325ff1`（分支 `cc/fb-lyrics-mode`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_mode_feedback_batch_test.dart`（`BUG-3282` 组：will-change 只在动画窗口一处；滚轮处理器累加目标 + rAF、直接落位只在减弱动效分支、scrollToCenter 停滚轮动画）；`fushi/test/media/audiobook/lyrics_mode_html_test.dart`（`wheel easing step converges…`：node 真跑 `__lyricsWheelStep`，两个方向单调逼近、不越过、30 帧内精确落位）。
- **备注**：帧率改善没有实测数字；「连续跟随播放进度滚动（karaoke 式匀速滚动）」若是反馈人的本意，属于新交互，本批未做。
