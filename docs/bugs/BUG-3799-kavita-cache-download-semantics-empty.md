## BUG-3799 · Kavita 缓存 / 下载两态是空的：阅读即永久入库、移除下载只翻标记
- **报告**：2026-10-27（用户：PR #2565 合入后审查）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/kavita/kavita_book_service.dart`（合入时版本）`openOrImport` 每次「阅读」都经 `EpubImporter` 把整本 EPUB 导入书库，`cachedOnly` 只是绑定里的一个标记：`cachedBookKeys()` 没有任何调用方、没有上限也没有淘汰；`kavita_book_series_page.dart` 的 `_removeDownload` 只调 `unpin`（把标记翻回 true），本地文件与书架条目都留着。等于任何一次「阅读」都是永久下载。
- **[x] ① 已修复** — 真两态：缓存副本上限 `kKavitaCachedBookLimit`（8 本），「阅读」后 `trimCache(keep:)` 按最近使用（`lastOpenedAt` / 阅读位置更新 / 导入时刻）淘汰；设置 › Kavita 服务器加「清理缓存的书」（`clearCache`）；「移除下载」= `removeDownload` 经确认后走书架删书原语 `ReaderFushiSource.deleteBook` 真删。删前本地位置离开上次一致页时先推一次（`KavitaProgressSync`，含不覆盖更新服务器进度的校验），推不出去就保留（移除下载降回缓存副本）。iOS 下载 / 移除下载入口仍走 `StoreRestrictedCapability.downloads`。
- **[x] ② 已加自动化测试** — `fushi/test/media/kavita/kavita_book_cache_test.dart`
- **备注**：在线漫画 / LNReader 现行形态都是「点即入库」，仓库里没有可复用的 EPUB 缓存 LRU，故淘汰落在本服务内、删除复用书架删书原语。未做：判断某本缓存书此刻是否开在阅读器里（全仓无此登记；淘汰总保留刚打开的那本）。
