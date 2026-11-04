## BUG-4016 · 歌词模式新版底栏自动收起，阅读速度/进度/时间读数随之消失
- **报告**：2026-11-03（用户：应用内反馈 njN2KIQS_j；另当面要求「底部控制栏做成常驻不要收起」）
- **真实性**：✅ 真 bug——读数行 `LyricsModernStatsLine` 包在新版宽屏底栏的自动隐藏层里，`fushi/lib/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart` 播放中闲置 3 s（`kLyricsChromeIdleHideDelay`）就把底栏连同读数淡出。
- **[x] ① 已修复** — 删掉底栏空闲自动隐藏整套机制（overlay 的计时器 / 唤出带子 / 手柄与 Tab 唤出，外观的 `wideChromeHidden` / `wideLyricsExpanded`，几何 `immersiveLyrics`、细进度线）；底栏与歌词矩形恒定。鼠标光标空闲隐藏保留（`kLyricsCursorIdleHideDelay`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_modern_layout_test.dart`、`lyrics_apple_modern_layout_test.dart`（播放中闲置 30 s 底栏与读数仍在、歌词矩形不变；窄屏读数可见）。
- **备注**：同批还补了歌词模式的进度跳转 / 跳转记录入口与进度条跳转刻度、换句滚动改合成器动画。
