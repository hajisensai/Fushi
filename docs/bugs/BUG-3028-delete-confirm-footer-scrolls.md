## BUG-3028 · 删除确认框的「删除」按钮在矮窗口里被滚出可视区
- **报告**：2026-10-06（PR #1984 M3E wave 1 CI：`home_video_page_menu_test.dart` 四条批量 / 单删用例红）
- **真实性**：✅ 真 bug（M3E 改造引入的布局回归）。`fushi/lib/src/sync/deletion_prompt.dart:159`（`_DeleteScopeConfirmDialog.build`）把 `FushiModalSheetFrame` 放进默认 `scrollable: true` 的 `FushiDialogFrame`：整块面板（正文 + 底部动作区）一起进外框的 `SingleChildScrollView`，`FushiModalSheetFrame` 自身的「正文 Flexible、动作区钉底」不起作用。1c1020e7645（M3E 分组勾选卡）把正文撑高后，800x600 窗口里面板高 444（0.74 上限）、「删除」落在 y≈576，已在面板 Material 之外；点上去命中的是遮罩，确认框被直接关掉、什么都没删。`test/sync/delete_local_files_dialog_test.dart` 早先已用 `useTallView` 绕开并在注释里承认「外框整体滚动会把『删除』挤到屏外」。
- **[x] ① 已修复** — 外框 `scrollable: false`、`FushiModalSheetFrame(scrollable: true)`：只让正文滚，动作区钉在面板内（与同文件传播确认框、导入对话框同一组合）。影响面：所有经 `showDeleteScopeConfirm` 的单删 / 批量删除（视频 / 书架 / 漫画等各库页），不改文案与决定语义。
- **[x] ② 已加自动化测试** — `fushi/test/sync/delete_local_files_dialog_test.dart`「BUG-3028 800x600 勾选项全开时『删除』仍钉在面板内」：断言「删除」可命中、中心在面板 Material 内、点击后真返回决定；去掉修复即红（hitTestable 0 个）。`test/pages/home_video_page_menu_test.dart` 四条批量 / 单删用例随之转绿。
- **备注**：仅 widget 层验证，未在真机矮窗口复测。
