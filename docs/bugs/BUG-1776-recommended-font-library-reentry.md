## BUG-1776 · 推荐字体重进字体库显示未持久化
- **报告**：2026-08-23（用户：）
- **真实性**：✅ 真 bug。现场 `font_catalog`、兼容列表和字体文件均已持久化，但错误日志明确记录 `_CustomFontsPageState._readCatalogState` 在 `initState` 内调用 `BasePageState.appModel`；该 getter 使用 `ref.watch`，触发 Flutter 的 `dependOnInheritedWidget... before initState completed` 异常。页面捕获异常后以空列表结束加载，下一次下载再用空列表覆盖旧 catalog。另有所有添加路径硬编码到 `FontTarget.body`、连续多键保存可乱序的次级问题。
- **[x] ① 已修复** — 初始化和 catalog 读取改用 `super.initState()` 已缓存的 `appModelNoUpdate`，不再在生命周期非法阶段 watch ProviderScope；字体库恢复期间禁用添加入口，推荐页等待恢复完成。新字体按页面目标初始化，连续保存串行落库。
- **[x] ② 已加自动化测试** — `fushi/test/reader/font_targets_wiring_guard_test.dart` 固定初始化区间只能使用 `appModelNoUpdate.database`；`fushi/test/pages/custom_fonts_dialog_page_test.dart` 固定词典与游戏查词入口的新字体目标映射。
- **备注**：本次按用户要求跳过测试，使用 Windows Debug 构建作为编译验证。
