## BUG-735 · 书架添加按钮尺寸位置与其它头部按钮不一致
- **报告**：2026-07-11（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/sources/reader_hibiki_source.dart:304`（修复前）——`buildBookImportButton` 唯一显式传了 `size: Theme.of(context).textTheme.titleLarge?.fontSize`（Material3 里约 22），而书架页头同排的其它按钮（管理来源/合集/统计）走 `_headerAction → HibikiIconButton`（`reader_hibiki_history_page.dart:410`）不传 size、用默认 24（见 `hibiki_icon_button.dart:36`）；视频 tab 的导入按钮（`home_video_page.dart:1425`）同样默认 24。于是「添加」按钮图标小 2px、外框（同 gap padding 内的更小图标）也短一截，看起来大小和位置都对不齐。
- **[x] ① 已修复** — 去掉 `buildBookImportButton` 的 `size` 覆盖，回落默认 24 与所有兄弟按钮对齐（`reader_hibiki_source.dart:303` 附近）。提交见下。
- **[x] ② 已加自动化测试** — `hibiki/test/tools/shelf_import_button_size_guard_test.dart`：源码扫描守卫，断言 `buildBookImportButton` 方法体内不得再出现显式 `size:`，防止回归。
- **备注**：纯尺寸对齐修复，无逻辑改动；`context` 参数仍被 `showAppDialog` 使用未变悬空。真机目视待用户确认。
