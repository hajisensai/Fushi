## BUG-3341 · 漫画卡菜单显示「导入有声书」而没有 OCR，多选也没有批量 OCR
- **报告**：2026-10-14（应用内反馈 3C7L0E7blH「这里应该是ocr吧，为什么是导入有声书」、Hen1JFOb-P「多选几本漫画，右下角只有下载、新增合辑、标签、删除，应该补上 OCR」）
- **真实性**：✅ 真 bug。书架与漫画库是同一个页面类，长按菜单 `_epubExtraActions`（`fushi/lib/src/pages/implementations/reader_fushi_history_page.dart`，原 2858–2869 行）的两个快捷格无条件是「导入有声书 / 有声书工作室」，漫画卡也一样——漫画阅读器不播有声书，这两格在漫画上没有意义；OCR 只能在阅读器或在线作品页里起，库页卡片和多选底栏（`reader_history/books.part.dart` `_buildBatchActionBar`）都没有入口。
- **[x] ① 已修复** — 新增共享路径 `fushi/lib/src/media/manga/library/manga_book_ocr.dart`（`pendingMangaOcrTargets`：在线作品 = 已下载且未识别的章，本地卷 = 未识别的卷；`enqueueMangaOcrTargets`：解析引擎一次、Lens 同意闸门、经 `MangaOcrJobRegistry.enqueue` 排队）。作品页「识别本章 / 识别全部已下载」改走它（行为不变）；漫画卡快捷格换成「识别文字（OCR）」（受漫画模块门控），有声书两格改为只在非漫画卡出现；漫画库多选底栏新增「识别文字」，选中合集时识别合集里的每一本。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_book_ocr_test.dart`（结果三态、本地卷目标、已识别不再排、卡菜单 / 多选接线源码守卫）。
- **备注**：已识别过的卷 / 章不会被库页入口重跑（重识别仍走阅读器「重新识别本卷」/ 作品页「识别本章」）。在线作品的章级判据与作品页同源。
