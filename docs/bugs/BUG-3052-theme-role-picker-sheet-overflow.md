## BUG-3052 · 自定义主题角色选色 sheet 在矮窗口底部溢出、推荐色点不到
- **报告**：2026-10-06（PR #1984 wave 1 CI：`custom_theme_page_roles_test`「界面背景选纯白」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/custom_theme_page.dart` `_showRolePickerDialog`（窄屏分支，4f886a5e37a 按需弹出选色器）用 `FushiModalSheetFrame` 承载约 300 高的 `_ThemeColorPicker`，但没开 `scrollable`；600 高窗口（横屏手机 / 小桌面窗）里 sheet 正文只有约 221，`RenderFlex overflowed by 86 pixels on the bottom`，折线以下的推荐色格点不到——选纯白界面背景静默无效。
- **[x] ① 已实现修复**（f4f4af3b556）— 选色 sheet 传 `scrollable: true`；内容放得下时 Scrollable 不认领拖拽，HSV 面板手势不受影响。
- **[x] ② 已加自动化测试** — `fushi/test/pages/custom_theme_page_roles_test.dart`「界面背景选纯白 → 应用写 surfaceColor」（默认 800×600 测试窗口，溢出即失败；先把色格滚进视口再点）。
- **备注**：未做真机验收。
