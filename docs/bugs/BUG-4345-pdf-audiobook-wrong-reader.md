## BUG-4345 · PDF 书挂上有声书后打开一片空白（SRT 卡写死 EPUB 阅读器 + PDF 卡露出「导入有声书」）
- **报告**：2026-11-09（应用内反馈 Ndnxy3mNdG，Windows）
- **真实性**：✅ 真 bug（沿代码路径验证）。三处叠加：
  1. `fushi/lib/src/pages/implementations/reader_fushi_history_page.dart:3653-3663`（修前）书卡菜单「导入有声书 / 有声书工作室」按 `!isManga` 门控，PDF 卡也露出入口；而 ctl 契约 `fushi/lib/src/ops/ctl_audiobook_routes.dart:275-276` / `:572` 明确「有声书只支持 EPUB 书（PDF / 漫画不能挂音频）」——两份判据漂移。
  2. 挂上后 `reader_fushi_history_page.dart:2130-2133`（修前）按「有 srt_books 行就藏原书卡」（BUG-728）把 PDF 卡藏掉，书架只剩 SRT 卡。
  3. `fushi/lib/src/pages/implementations/reader_history/books.part.dart:227`（修前）`_srtBookMediaItem` 把 `mediaSourceIdentifier` 写死成 `ReaderFushiSource.instance.uniqueKey`，`_openSrtBook`（`:250`）也写死 `mediaSource: ReaderFushiSource.instance`，没走唯一派生点 `ReaderFushiSource.mediaSourceKeyFor(format)`（`reader_fushi_source.dart:309`）→ PDF 被 EPUB 阅读器打开，有声书工具栏在、正文全白。副屏书库 `companion_library_app_data.dart` 的 `_openBook(audiobook: true)` 同样写死 EPUB 源。
- **[x] ① 已修复** —
  - 新增唯一判据 `BookFormat.supportsAudiobook`（`packages/fushi_core/lib/src/database/book_format.dart`）；ctl 两处拒绝分支、书卡菜单（经 `ReaderFushiSource.mediaItemSupportsAudiobook`，由卡上 `mediaSourceIdentifier` 经 `formatForMediaSourceKey` 反查 format）共用。PDF / 漫画卡不再出现「导入有声书 / 有声书工作室」。
  - SRT 卡阅读器改由 `srtBookMediaSourceKey`（`books.part.dart`）按配对书 format 经 `mediaSourceKeyFor` 现算；`_openSrtBook` 与副屏 `_openBook` 改按 `item.getMediaSource` 取源。
  - BUG-728 顶替规则收敛为 `ReaderFushiSource.audiobookShadowedBookKeys`：只对能挂有声书的格式顶替原书卡。书架页、ctl `library ls`、合集成员可见性（`ctl_library_shelf.dart`）、副屏书库共用。存量「PDF + 有声书」的 PDF 原卡重新出现，SRT 卡也改开 PDF 阅读器。
  - 全仓其它 `ReaderFushiSource.instance.uniqueKey` 写死点（`ctl_book_metadata_routes.dart:200`、`ctl_library_manage_routes.dart:460`）只用于 bookKey 为空的 standalone 字幕书身份记账（无配对书、正文就是生成 EPUB），不受影响，未改。
- **[x] ② 已加自动化测试** — `fushi/test/media/pdf_audiobook_reader_routing_test.dart`（判据 / 逆映射 / SRT 卡派生 / 顶替规则单测 + 源码守卫）；`fushi/test/media/manga/manga_book_ocr_test.dart` 守卫随菜单门控改写。测试未在本分支运行，统一在合并后验证。
- **备注**：存量孤儿有声书数据（PDF bookKey 下的 srt_books 行 / audio_cues / 音频）不自动清理：SRT 卡仍在，用户可用卡菜单「删除」移除；自动删用户导入的音频属于破坏性操作，交用户决定。「PDF 阅读器支持有声书」是新功能方向，不在本修复范围（PR 待决策项）。
