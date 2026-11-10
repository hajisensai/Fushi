## BUG-4372 · 互联看不到对端导入的 PDF 书（PDF 没有互联内容通道）
- **报告**：2026-11-09（应用内反馈 Jq1_ujHa4t，安卓经 Fushi 互联连 Windows：Windows 上导入的 PDF 在安卓看不到，同步显示「无新增」）
- **真实性**：✅ 真 bug。PDF 在互联里整条没有内容通道，四段各自把它挡掉：
  - host 清单 `packages/fushi_engine/lib/sync/local_library_host_service/books.part.dart:99`：`hasContent` 只判 EPUB 内容树（`format == epub`），PDF 恒 false，也没有别的内容位；
  - client 书架 `fushi/lib/src/pages/implementations/reader_history/remote.part.dart:117`：远端占位卡只收 `hasContent`，PDF 整本被滤掉（首页「继续」`dashboard_remote_merge.dart:97` 同判据）；
  - host 导出 `books.part.dart:254`：PDF 直接 `StateError` → 端点 404，就算出卡也下不了；
  - client 推送 `fushi/lib/src/sync/sync_orchestrator/books.part.dart:103`：PDF 静默跳过，反方向同样不通。
  同步「无新增」是正常的——互联同步本来就不自动拉远端独有的书，入口是书架占位卡，而 PDF 的占位卡从未出现。
- **[x] ① 已修复** — c186cd0298 / 0f2e0731b2（PR 分支 `claude/interconnect-pdf-books`）。PDF 包 = 书目录里的原件，走同一个 books 端点、按内容嗅探（`%PDF-` 头）分流，零新端点：
  - 引擎 `pdf_sync_package.dart`：`hasExportablePdfContent` / `isPdfFile` / `pdfBookFilePath` / 能力位解析；
  - host 清单加 additive 字段 `hasPdfContent`（旧 client 只认 `hasContent`，PDF 对它保持不可见）；`exportBook` 交出原件副本；`importBook` 嗅探到 PDF 交新回调 `importPdfBookFromFile`（app 接 `PdfImporter`，无头服务端不接）；
  - 能力位 `liveLibrary.pdfBooks`（`PdfBookImportHost.acceptsPdfBooks`）：client 只往能收的 host 推 PDF，老 host / 无头服务端上 PDF 留在本机；推送 diff 把 `hasPdfContent` 算作「远端已有」；
  - client 书架 / 首页「继续」/ 同步对比弹窗统一用 `RemoteBookInfo.hasBookShelfContent`；两处下载落库合成 `importSyncedBookFile`（PDF / 漫画包 / EPUB 内容嗅探）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_pdf_book_channel_test.dart`（判据、wire 兼容、host 清单 / 导出 / 导入分流、能力位端点）、`fushi/test/sync/interconnect_pdf_push_test.dart`（真 HTTP 端到端推送：能收 / 已有不重推 / 收不了不报错）、`fushi/test/sync/interconnect_dashboard_feed_test.dart`（PDF 进首页「继续」）。
- **备注**：测试未在本分支运行，统一在合并后验证。未做真机复测（安卓 ↔ Windows 实际下载 / 打开 PDF）。云盘同步（WebDAV / Google Drive 等）对 PDF 仍不上传（`sync_manager.dart` 的 `exportable` 判据），本反馈只涉及互联，未扩到云盘通道。
