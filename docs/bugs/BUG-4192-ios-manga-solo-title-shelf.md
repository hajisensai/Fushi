## BUG-4192 · ios-manga-solo-title-shelf
- **报告**：2026-11-06（用户：iOS 截图，漫画页左上角标题胶囊写「书架」，应为「漫画」）
- **真实性**：✅ 真 bug。iOS 合规门下漫画库只剩「我的」一组（书架 + 导入），`MediaLibraryShell._buildNavigation`（`fushi/lib/src/pages/implementations/media_library_shell.dart` 「一级只剩一组」分支）把该组名当标题胶囊；组名取库视图 label，漫画库与书籍库都是 `t.library_view_shelf`（书架），于是漫画页左上角也显示「书架」。
- **[x] ① 已修复** — 只剩一组时标题胶囊改用外壳给本 tab 的页面名（`FushiShellTitleScope`，漫画 / 书架），没有外壳页面名时才回落组名。
- **[x] ② 已加自动化测试** — `fushi/test/pages/media_library_shell_test.dart`「iOS 形态的漫画库：左上角标题用外壳页面名「漫画」」。
- **备注**：非 iOS 的多组形态仍以「书架 | 在线」做一级页签，不在本修复范围。
