## BUG-1643 · 设置页宽屏被 960px 强制限宽
- **报告**：2026-08-14（用户：设置页有莫名奇妙的宽度限制，要求删掉）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/misc/platform_utils.dart:230`（修前）——
  `desktopContentMaxWidth()` 对 `DesktopContentKind.settings` 在 medium/expanded 返回 `960`，
  `DesktopContentLayout` 据此把正文塞进 `Center` + `ConstrainedBox`，宽屏下居中锁窄。
  受影响的实际页面是走该布局的设置正文：各库页内嵌的设置标签页
  `ModuleSettingsView`（`fushi/lib/src/pages/implementations/module_settings_view.dart:51`，
  小说 / 视频 / 漫画 / 游戏库页都用它）与设置主页窄屏单列分支
  （`fushi/lib/src/settings/settings_home_page.dart:98`）。
  这是同一族「莫名宽度上限」的最后一处残留：书架 1280 与查词 1040 早已按用户实报改成 `null`，
  设置主页的宽屏主从分支也早已按用户拍板不限宽（`settings_home_page._buildWideLayout` 注释：
  4K 窗口右侧空 2400px），唯独这条 960 还在，导致同一 app 内设置详情两种宽度自相矛盾。
- **[x] ① 已修复** — `DesktopContentKind.settings => null`，走 full-bleed 分支；
  `desktopContentPadding` 保持 16/24px 侧向留白（正文是文字流，不贴边）。
- **[x] ② 已加自动化测试** — `fushi/test/utils/platform_utils_settings_width_test.dart`
  （medium/expanded 均须为 `null` + 留白仍为 24）；同步更新既有契约
  `fushi/test/utils/misc/platform_layout_test.dart`、
  `fushi/test/pages/popup_layout_width_columns_test.dart`、
  `fushi/test/pages/settings_wide_left_aligned_test.dart`。
  变异实测：把 `null` 改回 `960` → 守卫红（exit 1，2 个失败）；还原 → 绿（5 tests passed）。
- **备注**：阅读器内的设置**弹窗**（`FushiSettingsDialogPage` 的 `kFushiSettingsDialogMaxWidth` = 900）
  是弹窗尺寸、且是 BUG-1546 按用户要求从 560 放宽来的，不在本次范围内，未动。
