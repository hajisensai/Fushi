## BUG-758 · 本地视频卡不支持右键弹菜单

- **报告**：2026-07-12（用户：qqbotxiaoxiao）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/home_video_page.dart:2168` 本地视频卡 `HibikiCard` 只挂了 `onLongPress: _showVideoMenu`、漏挂 `onSecondaryTap`。`HibikiCard` 本身支持 `onSecondaryTap`（桌面鼠标右键），书架书卡（`reader_history/card_widgets.part.dart` 的 `_bookCardShell` 同绑 onLongPress+onSecondaryTap）与远端视频卡（`home_video_page.dart` `_buildRemoteVideoCard` 同绑两者）都支持右键，唯本地视频卡漏配，故桌面右键本地视频无反应。用户对照书架「右键打开对应书籍菜单」报此缺失。
- **[x] ① 已修复** — `home_video_page.dart` 本地视频卡补 `onSecondaryTap: _selectionMode ? null : () => _showVideoMenu(book)`，与 onLongPress 同链路、同选择态门控，与书卡/远端视频卡一致。提交见分支 `worktree-video-card-right-click`。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/home_video_page_menu_test.dart` 新增用例「桌面右键（次按钮）本地视频卡弹出同一动作面板（BUG-758）」：用 `tester.tap(card, buttons: kSecondaryButton)` 模拟右键，断言弹出与长按相同的 `HibikiDialogFrame` 动作面板。
- **备注**：根因是遗漏配置而非平台限制；移动端无次按钮，`onSecondaryTap` 自然永不触发，行为与历史一致。
