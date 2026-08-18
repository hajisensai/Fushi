## BUG-1716 · 删除漫画扩展仓库没有确认提示，一点即删
- **报告**：2026-08-18（用户：删除扩展前没有确认提示）
- **真实性**：✅ 真 bug（就删除仓库而言）。核查三条删除路径：卸载扩展
  （`mihon_extensions_page.dart` `_uninstall`）与 Aidoku 仓库/扩展删除
  （`manga_sources_page.dart` `_removeAidokuRepository` / `_removeAidoku`）在 develop
  已各有确认框；唯独 Mihon 扩展仓库行的删除按钮（改前
  `fushi/lib/src/media/manga/mihon/mihon_extensions_page.dart:603-609`）直接
  `manager.removeStore(store.indexUrl)`，一点即删，无任何确认。删掉仓库会让它提供的
  整页可装扩展从列表消失，误触成本远高于一次确认。
- **[x] ① 已修复**（99977dbf5e）— `mihon_extensions_page.dart` 新增 `_removeStore`：与卸载扩展、
  Aidoku 仓库删除同一套 `AlertDialog.adaptive` 确认语义（标题
  `t.mihon_store_remove`，正文仓库名 + 索引地址，取消/删除），确认后才调
  `MihonManager.removeStore`。新 i18n key `mihon_store_remove`（经 i18n_sync 添加）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/mihon_extensions_page_test.dart`
  「删除扩展仓库先确认：取消保留、确认才真删」：点删除出确认框且仓库未删；取消后仓库
  仍在；确认后 `manager.stores` 清空、行消失。
- **备注**：用户报告口径是「删除扩展」，但扩展卸载在 develop 已有确认框（用户所用发布
  版本较旧）；本条修的是同一页面上仍缺确认的仓库删除。
