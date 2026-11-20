## BUG-4827 · 重开书恢复增量 OCR 结果时漏掉系统 OCR 的逐页缓存
- **报告**：2026-11-17（用户：代码审查，漫画优化清单第 15 条）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/manga/ocr/manga_ocr_cache_recovery.dart:68`
  （develop `8d58da51da9`）—— 恢复候选只有本地模型签名目录和
  `kGoogleLensEngineSignaturePrefix` 前缀目录。系统 OCR 是 BUG-1151 之后才加的引擎，它与
  Lens 同格式、同根写逐页缓存（`system_ocr_manga_service.dart` 用的就是
  `GoogleLensPageCache`，目录名 `system_ocr_v2_<lang>`），但恢复没跟上：系统 OCR 跑到一半
  被杀进程 / 取消后重开书，已识别的页读不回来，查词要等整卷重跑。
- **[x] ① 已修复** — 提交 `5b02bd5c4f6`。`'system_ocr_v2_'` 提成常量
  `kSystemOcrEngineSignaturePrefix`（签名函数与恢复共用）；恢复改按
  `kMangaOcrPageJsonCachePrefixes`（引擎 → 前缀表）枚举目录，Lens 与系统 OCR 都从表里取。
  前缀带版本号：BUG-2767 换签名作废的 v1 目录不会被收回来。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_ocr_cache_recovery_test.dart`
  （「recovers pages cached by a system OCR run」「retired system OCR v1 cache is not
  recovered」「page-json cache prefix table covers every engine that writes one」）。
- **备注**：真机待验——系统 OCR 跑到一半杀进程后重开书，已识别页的文字层应立即可查词。
