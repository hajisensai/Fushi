## BUG-922 · 视频词典浮层无法用快捷键关闭·浮层开着时快捷键穿透控制视频
- **报告**：2026-07-19（用户：视频里按关闭词典没反应；d 之类没在快捷键设置显示的键按了却有反应）
- **真实性**：✅ 真 bug。根因：视频页词典浮层开着时，快捷键没有「先关浮层」的优先级。
  - `video_hibiki_page.dart:3575` `escape:` 回调把 控制条编辑/字幕列表/剧集列表/侧栏/沉浸锁(3596)/全屏(3600) 都排在 `_handleBackOrExit`(3416，唯一关浮层处) 之前——全屏或沉浸锁看视频时按 Esc 先退全屏/解锁，永远关不掉词典浮层。
  - 其它视频键（方向键/d/空格等）经 `_videoKeyboardShortcuts`(3436) / 手柄 `_handleVideoGamepadButton`(3617) / 裸空格 `_withPageSpaceOverride`(5431) 在浮层开着时直接穿透控制视频（后台 seek/播放），而非关浮层。
  - 对照阅读器 `reader_hibiki/caret.part.dart:522` `readerDismissDict` 与各导航键：第一件事都是 `if (isDictionaryShown) clearDictionaryResult()`，浮层优先关。视频页缺这套优先级。
  - 澄清 issue 2：`d` 是 `videoSeekForward` 的别名键（`shortcut_defaults.dart:252`），本就在设置「视频·快进」行显示，并非漏网硬编码键；用户"看不到 d"是别名键可发现性问题 + 浮层穿透造成的错觉。本 bug 通过「浮层开着时 d 改为关浮层」消除该错觉。
- **[x] ① 已修复** — 新增纯函数 `guardVideoShortcutsWithPopupDismiss`（`video_player_shortcuts.dart`）包裹键盘快捷键表：浮层可见时任一映射键先关顶层浮层并消费、不跑原动作；页面 `_videoKeyboardShortcuts` / `_handleVideoGamepadButton` / `_withPageSpaceOverride` 三条输入通道统一走 `_dismissTopVisiblePopup()` 守卫。与阅读器同模型。提交哈希：9b895bbf3
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_popup_dismiss_guard_test.dart`：浮层可见→任一键关浮层且不跑原动作；浮层不可见→原动作照跑。提交哈希：9b895bbf3
- **备注**：修法范围经用户确认「对齐阅读器」（浮层开着时导航键也先关浮层）。真机验证：Windows 离屏 / 模拟器 复测「全屏+词典浮层→Esc 关浮层」「浮层开着按 d 关浮层不快进」。
