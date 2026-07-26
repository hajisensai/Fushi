## BUG-1083 · 漫画编辑对话框缺作者字段(未覆盖supportsAuthorEdit)
- **报告**：2026-07-25（统一各媒体页服务 P4 调查中发现的书族缺口）
- **真实性**：✅ 真 bug。漫画是 `EpubBooks`（`format=='manga'`）的行，与 EPUB 共用可编辑的 `author` 列，但长按编辑对话框里漫画**没有作者字段**（EPUB 有）。
- **根因**：作者字段由 `media_item_edit_dialog_page.dart:_supportsAuthorEdit` = `mediaSource.supportsAuthorEdit` 门控。`ReaderHibikiSource`（EPUB）覆盖为 true 并实现 `setAuthorFromMediaItem` 写 `epubBooks.author`；但漫画 item 解析到的是 `MangaHibikiSource`，它 `extends ReaderMediaSource`（非 ReaderHibikiSource），**未覆盖** `supportsAuthorEdit`（基类默认 false）也没有作者写入逻辑 → 漫画编辑无作者字段。此外编辑对话框保存后的 provider 失效条件写死 `mediaSource is ReaderHibikiSource`，漫画（MangaHibikiSource）落在条件外，改完书架不刷新。
- **[x] ① 已修复** — commit（见末）。
  - `manga_hibiki_source.dart`：覆盖 `supportsAuthorEdit => true`；`setAuthorFromMediaItem` **委托** `ReaderHibikiSource.instance`（写库逻辑走 sharedDatabase + item.mediaIdentifier 的 bookKey，与源实例无关，漫画行 bookKey 解析一致，复用同一写入路径不重复实现）。
  - `media_item_edit_dialog_page.dart`：保存后失效条件 `mediaSource is ReaderHibikiSource` → `is ReaderMediaSource`（覆盖 EPUB/漫画/PDF 全书族），漫画改完书架刷新。
- **[x] ② 已加自动化测试** — `test/media/sources/reader_hibiki_source_test.dart` 新增「MangaHibikiSource 也支持作者编辑并委托写入 epubBooks.author」：断言 `supportsAuthorEdit==true` 且对 format=='manga' 行 setAuthor 后 `epubBooks.author` 真被写入。
- **备注**：属「统一各媒体页服务」P4 域（改名/作者门面）。作者读路径漫画本就通过 `_bookToMediaItem` 读进 MediaItem.author，无需改。
