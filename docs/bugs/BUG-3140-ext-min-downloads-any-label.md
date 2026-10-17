## BUG-3140 · 扩展页最低下载量首档显示成「全部语言」
- **报告**：2026-10-09（用户：扩展页「最低下载量」那一排第一个选项显示「全部语言」）
- **真实性**：✅ 真 bug。三个域（漫画 / 视频的 Mihon 扩展、小说的 LNReader 插件）共用的 `ExtensionCatalogActions` 在 `fushi/lib/src/media/manga/extension_catalog_controls.dart:133` 给门槛 0（= 不筛）这一档借用了语言筛选的 key `mihon_extension_language_all`（en「All languages」/ zh-CN「全部语言」），于是下载量一排的首个 chip 读作「全部语言」。
- **[x] ① 已修复**（01a461c0fa）— 新增 key `mihon_extension_min_downloads_any`（en「Any」/ zh-CN·zh-HK「不限」/ ja「指定なし」等 17 种语言均给出译文，经 `i18n_sync --add` 加 key 后定点填值），首档改用它；`mihon_extension_language_all` 不动，语言筛选照旧用它、既有译文全部保留。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/extension_catalog_min_downloads_label_test.dart`（en / zh-CN 两个 locale 断言首档 chip 文本 = `mihon_extension_min_downloads_any` 且 ≠ `mihon_extension_language_all`；修复前两条均红）。
- **备注**：设 `FUSHI_PREVIEW_PNG=<目录>` 跑该测试会额外输出真实像素截图。
