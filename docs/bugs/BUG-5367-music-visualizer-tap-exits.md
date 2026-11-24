## BUG-5367 · 全屏歌词动画单击任意位置就退出
- **报告**：2026-11-24（应用内反馈 0i-FWiMxFO，开发者本人要求改掉）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/music/music_lyric_visualizer_view.dart:313-316` 把整个动画画面（含 MV 背景）包在 `GestureDetector(key: music_visualizer_tap_exit, behavior: opaque, onTap: widget.onExit)` 里，在 MV 背景上随手一点就退回原布局。退出本来已有 Esc（`_onKey`）、返回键（`music_lyrics_page.dart` 的 `PopScope`）和悬停条退出按钮（`music_visualizer_exit`）三条途径，单击退出是多余且易误触的那一条；同时触屏没有悬停，悬停控制条在触屏上根本唤不出来。
- **[x] ① 已修复** — 画面单击改调 `_pokeHover()`：唤出悬停控制条（2 秒后照常收起），不再退出；key 改为 `music_visualizer_tap_reveal`。退出只留 Esc、返回键和控制条退出按钮。样式内部手势（如点歌词跳转）在手势竞技场里照旧优先于外层单击。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/visualizer/lyric_visualizer_tap_reveal_test.dart`：单击不调 `onExit`、控制条显现并自动收起；唤出后点退出按钮才退出；Esc 退出。
- **备注**：触屏设备上「点一下唤出控制条 → 点退出」的真机复测待补。
