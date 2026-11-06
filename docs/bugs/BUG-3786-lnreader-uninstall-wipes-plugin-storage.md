## BUG-3786 · lnreader-uninstall-wipes-plugin-storage
- **报告**：2026-10-26（AI 助手「卸载扩展可撤销」实现时发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/novel/online/lnreader_manager.dart` 的 `uninstall` 每次都删插件存储文件（登录态 / token），而卸载确认框（`lnreader_extensions_section.dart`）只问「卸载」，没提会清数据；Mihon / Aniyomi 的卸载（`mihon_extension_uninstall.dart`）不清数据。两边语义不一致，用户卸载再装回会丢登录。
- **[x] ① 已修复** — `LnReaderManager.uninstall({bool clearData = false})` 默认保留存储，只在显式清数据时删（`DELETE /api/admin/extensions/:id` 的 `clearData` 对 LNReader 也生效）；清数据仍走独立的「清除数据」入口。
- **[x] ② 已加自动化测试** — `fushi/test/media/novel/lnreader_manager_test.dart`（卸载后存储仍在、重装接回；`clearData: true` 才删）；`fushi/test/ops/op_undo_online_test.dart`（AI 卸载 → 撤销重装、数据仍在）。
- **备注**：
