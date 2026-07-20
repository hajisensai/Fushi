## BUG-920 · 管理来源打开文件夹按钮路径不对
- **报告**：2026-07-19（用户：）
- **真实性**：✅ 真 bug。根因 `packages/hibiki_core/lib/src/database/media_source_util.dart:23` + `hibiki/lib/src/pages/implementations/media_sources_dialog.dart:516`。
  - `normalizeSourceRootPath` 对本地来源把所有反斜杠 `\` 归一化成正斜杠 `/`（跨平台一致 + dedup/label 依赖），故 `MediaSources.rootPath` 存的是 `C:/Users/.../foo`。
  - `_openFolder` 把这个正斜杠路径直接 `Process.run('explorer', [row.rootPath])`。Windows `explorer.exe` 只认反斜杠路径参数，收到正斜杠会忽略该参数、打开默认「文档」目录 → 现象即「打开的路径不对」。
- **[x] ① 已修复** — 在 `_openFolder` 这个平台边界把 `rootPath` 的 `/` 转回 `\` 再传给 explorer（不动存储归一化）。`hibiki/lib/src/pages/implementations/media_sources_dialog.dart:513`。提交：e67a51652
- **[x] ② 已加自动化测试** — 源码守卫测试：断言 `_openFolder` 传给 `Process.run('explorer', ...)` 的实参经过 `replaceAll('/', r'\')` 转换，防回归到裸 `row.rootPath`。`hibiki/test/pages/media_source_open_folder_backslash_guard_test.dart`。提交：e67a51652
- **备注**：存储层继续用正斜杠归一化是对的（dedup/label/网络来源都依赖它），只在 Windows explorer 边界做方向转换。号从工具初分的 918 改到 920，避开 draft PR#253/#255 对 918 的既有占用（撞号纪律）。
