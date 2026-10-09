## BUG-3099 · 扩展页「有更新」状态没有卸载按钮
- **报告**：2026-10-09（用户：应用内反馈「已安装的视频扩展如果有更新，在不更新的情况下没有卸载按钮」）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/mihon/mihon_extensions_page.dart:1399-1412`（修复前）：`_AvailableExtensionTile` 只有一个主按钮，三态互斥——未安装 = 安装、有更新 = 更新、否则 = 卸载；次要按钮只给未安装的「预览」。于是已安装且仓库有新版时，「更新」顶掉了唯一的「卸载」入口，用户不更新就卸不掉。漫画 / 视频（Aniyomi）扩展页与浏览模块扩展页签是同一组件，三处同病。
- **[x] ① 已修复** — 有更新时次要按钮给 outlined「卸载」（主按钮仍是 tonal「更新」）；卸载确认与来源页「卸载扩展」共用 `confirmAndUninstallMihonExtension`（`mihon_extension_uninstall.dart`），确认框列出会一起移除的源与包名，失败 toast 而不是未处理异常。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/mihon_source_extension_manage_test.dart`「BUG-3099：扩展页「有更新」状态同时给「更新」与「卸载」，卸载真生效」（manga / anime 两种 kind 各一遍）。
- **备注**：同一 PR 还给来源页条目菜单加了「卸载扩展」、副标题改显示扩展名（用户需求，非 bug）。
