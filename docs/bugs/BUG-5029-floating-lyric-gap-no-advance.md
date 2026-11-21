## BUG-5029 · 句间静音里悬浮字幕不会提前切到下一句（BUG-509 修复不完整）
- **报告**：2026-11-20（路线图 #3722 c48 novel-15，关联 BUG-509）
- **真实性**：✅ 真 bug。
  - 根因：`fushi/lib/src/media/audiobook/audiobook_controller.dart` `_updateCurrentCue` 在句间静音（`findCueIndex` 返回 -1）时按 reader 高亮的 hold 契约裸 `return`、不 `notifyListeners`。BUG-509 给显示面加了 `displayCueForFloatingLyric`（gap 里返回下一句），但悬浮字幕 / 媒体通知副标题 / 迷你条只在 `AudiobookSession._onControllerChanged`（控制器 notify）里重读它——gap 里没有任何 notify，于是显示面照样停在上一句，要等下一句开口（当前句真的变了）才切。BUG-509 的单测只测了 getter 的纯决策，没测「播放中 gap 里有没有人去读它」。
- **[x] ① 已修复** — 控制器每个 tick 记下显示句身份（`_lastDisplayCue`），gap 里显示句变了才发一条只给显示面的信号 `displayCueChanged`（不走 `notifyListeners`，正文高亮 / 歌词跟随不受打扰）；`AudiobookSession` 订阅它，只刷悬浮字幕、媒体通知副标题和迷你条（session 监听者）。命中句区间时显示句就是当前句，当前句换了仍随原来的 notify 走、不重复发；当前句没变而显示句变了（gap 里显示句已切到下一句，随后回退 / 单句循环落回 hold 的那一句）只发显示面信号——审查补：初版漏了这条分支，悬浮字幕会停在下一句而耳朵里放的是上一句。
- **[x] ② 已增加自动化测试** — `fushi/test/media/audiobook/display_cue_for_floating_lyric_test.dart`「句间静音里显示句提前切换要发信号」：逐 tick 驱动控制器，断言进 gap 发一次 `displayCueChanged`、同一 gap 不重复、正文监听者在 gap 里不被 notify、`currentCue` 仍 hold 上一句；「回退进 hold 的那一句也要发信号」钉住从 gap 落回原句时显示面收到信号、正文监听者不被 notify。
- **备注**：真机未复测（本轮所有者定不做设备验证）。
