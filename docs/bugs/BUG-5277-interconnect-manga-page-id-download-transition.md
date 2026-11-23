## BUG-5277 · 互联漫画读到一半 host 下完这章：页身份由源端身份变成文件身份，取页 409、对端整章重下
- **报告**：2026-11-23（代码审查 PR #4177 遗留项，拍板台 `review-interconnect-page-id-on-download`，用户拍板「做」）
- **真实性**：✅ 真 bug（保守失败，不认错页、不丢数据）。BUG-5237 修复后取图带页身份核对，但 host 对同一章报两套身份：
  - 没下载的章：`packages/fushi_engine/lib/sync/local_library_host_service/manga.part.dart` `mangaChapterManifest` 报 `source\0<OnlineMangaPageRef.pageKey>`；
  - 已下载的章：同文件 `_volumeManifest` / `_downloadedPageKey` 报 `file\0<文件名>\0<宽>x<高>`，取页核对也只认它。
  - 下载服务（`fushi/lib/src/media/manga/download/manga_download_service.dart` 写章 `manga.json` 处）落盘时把每页的源端身份丢了，host 下完后无从对应。
  - 结果：对端按下载前的页表取页 → 409，阅读器这一页失败；对端的下载重解析页表发现身份全变 → 判源端换页、整章重下。
- **[x] ① 已修复** — 下载服务在写 `manga.json` 前落一份章目录旁注 `.fushi-source-pages.json`（引擎 `manga_chapter_storage.dart`：`MangaChapterSourcePage` / `mangaChapterSourcePagesOf` / `encode…` / `readMangaChapterSourcePages` / `mangaChapterSourcePageKey`），每条按 url + 尺寸绑定到 `manga.json` 那一页。host 对已下载的章：页表里旁注认得的页报源端身份（与下载前同一个值），认不得的报文件身份；取页核对两种身份都认，都不对才 409。旧下载没有旁注 → 退回原行为。不放进 `manga.json` 字段：OCR / 大模型识别 / PDF 文字层回填等多个写者按各自 payload 整份重写 `manga.json`，额外字段会被冲掉，而「下完立刻自动 OCR」正落在这个窗口。
- **[x] ② 已加自动化测试** — `fushi/test/sync/local_library_host_service_manga_test.dart`（下载前后页表身份不变、按下载前页表取到已下载文件且不打运行时、文件身份照认、错页身份 409、`manga.json` 换内容后旧源端身份 409）；`fushi/test/media/manga/manga_download_service_test.dart`（下完一章旁注逐页记源端身份）；`fushi/test/media/manga/manga_chapter_storage_test.dart`（旁注配对 / 读回 / 内容变更不认 / 坏文件按没有）。
- **备注**：与 BUG-5237、BUG-5238 同属 audit-035 页身份链。
