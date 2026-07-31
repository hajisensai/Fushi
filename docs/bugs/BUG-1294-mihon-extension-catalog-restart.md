## BUG-1294 · 漫画扩展重启后可下载目录消失且无法安装新扩展
- **报告**：2026-07-29（用户：）
- **真实性**：✅ 真 bug。`MihonManager.available` 是仅驻内存的可下载扩展目录；添加仓库时会填充它，但冷启动 `_initialise()` 原本只在 `hibiki/lib/src/media/manga/mihon/mihon_manager.dart:68` 调 `reload()` 恢复仓库/已安装扩展/来源三张表，从不恢复 `available`。即使随后手动刷新，内嵌目录仓库也会携带数据库保存的 ETag/Last-Modified；304 响应没有目录正文，而进程重启后的内存缓存为空，旧逻辑便把空缓存当成完整目录，故截图中语言筛选下方所有可下载项消失，无法继续安装新扩展。
- **[x] ① 已修复** — `ce01ea50e`：初始化在数据库恢复后自动刷新仓库；内嵌目录只有在内存中确有可复用目录时才发送条件请求，冷启动改为取完整正文；刷新失败保留当前已显示目录，不再因一次网络错误清空列表。`mihon_extensions_page.dart` 同时新增与语言筛选并排（窄屏纵排）的即时搜索，按扩展名、包名、仓库、语言及来源名称/网址走共享日文/全角归一化匹配，并覆盖仅本地安装项。
- **[x] ② 已加自动化测试** — `ce01ea50e`：`hibiki/test/media/manga/mihon_manager_install_test.dart` 模拟数据库已有旧 ETag 的进程冷启动，若发送条件头服务端即回 304，断言修复后不发陈旧验证器且目录恢复；`hibiki/test/media/manga/mihon_extensions_page_test.dart` 真操作搜索框，断言片假名/平假名归一化名称搜索与包名搜索均正确过滤。
- **备注**：定向 `flutter test` 5 条通过；全量 `dart analyze` 通过。`flutter analyze` 连续两次在 Flutter 3.44 分析服务器读取 LSP 初始化消息时自身崩溃（`FormatException: Unexpected end of input`），未产出代码诊断，故以同 SDK 的全量 `dart analyze` 补验。
