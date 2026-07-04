## BUG-544 · 移动端导出片段右键菜单项垫底应前置
- **报告**：2026-07-04（用户：board 1134）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart`（移动端 `InAppWebView.contextMenu` 分支）。此前移动端 `ContextMenuSettings(hideDefaultSystemContextMenuItems: false)` 保留系统默认项（复制/全选/粘贴），Android ActionMode 契约把自定义 `menuItems`（id:1 查词 / id:2 导出片段）追加在系统项**之后**，故「导出片段」排在最末、淹没在系统项后。
- **[x] ① 已修复** — 根因修法：移动端改 `hideDefaultSystemContextMenuItems: true`，只保留自定义项，顺序 [查词(id:1)][导出片段(id:2)][复制(id:3)]，把导出提到第二位。因隐藏系统项会一并去掉系统「复制」，补一条自定义复制项（复用桌面右键菜单 `reader_hibiki/chrome.part.dart` 的 `t.copy` 标题 + `Clipboard.setData` + `t.copied_to_clipboard` toast，无新增 i18n key），复制功能不丢。提交见分支 `todo1134-clip-png-menu`。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_mobile_context_menu_order_guard_test.dart` 源码扫描守卫：断言 webview.part.dart 不再出现 `hideDefaultSystemContextMenuItems: false`、菜单含 `t.copy` + `Clipboard.setData` + `copied_to_clipboard`、且「导出片段」出现在「复制」之前、导出项后仍有 id:3（证明导出不在末位）。
- **备注**：菜单为原生 WebView 项，真机菜单顺序验收需 Android 设备（当前无设备接入），由 owner 排期。未新增 i18n key（复用现有 `copy` / `copied_to_clipboard`）。
