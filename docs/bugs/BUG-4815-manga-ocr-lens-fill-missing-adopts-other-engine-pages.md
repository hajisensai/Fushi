## BUG-4815 · Lens 只补缺页时把别的引擎写的整卷产物收作自己的结果，系统 OCR 取消还会写出半卷占位产物
- **报告**：2026-11-17（用户：代码审查，漫画优化清单第 2 条）
- **真实性**：✅ 真 bug。两处根因叠在同一个文件 `manga_ocr_out/manga.json` 上（下列行号以
  develop `8d58da51da9` 为准）：
  1. `fushi/lib/src/media/manga/ocr/google_lens_ocr_service.dart:244` —— `onlyMissing` 时
     `_readExistingPages(output)` 读的是三个引擎**共用**的整卷中间产物；`:263` 只看
     `blocks.isNotEmpty` 就收下，不看 `payload.ocr.engine`（`_readExistingPages`（`:717`）把
     `ocr` 元数据整个丢了），最后一律署名 `engine: 'google_lens'`。于是系统 OCR / 本地模型
     写在那里的页被冒名成 Lens 的结果。Lens 自己取消时不写这份文件（`throwIfCancelled`
     直接抛），所以这条路对 Lens 自己的中断结果没有任何增益，是第二套持久化。
  2. `fushi/lib/src/media/manga/ocr/system_ocr_manga_service.dart:207` —— 取消是 `break`，
     随后 `:229` 照常 `_writePayload`，写出一份「已识别页 + 空 blocks 占位页」、署名
     `system_ocr` 的假整卷。它正是上面第 1 条最常见的原料：先系统 OCR 取消、再换 Lens 补缺。
     续跑靠的是逐页缓存，不靠这份文件。
- **[x] ① 已修复** — 提交 `5b02bd5c4f6`。
  - Lens：删 `_readExistingPages`；已识别的页只认 Lens 自己的逐页缓存（目录名即带语言的
    引擎签名）。`onlyMissing` 在执行器里不再有分支——「重新识别」由 `mangaOcrLensEvents`
    先清掉该缓存目录，与修复前一致。
  - 系统 OCR：取消改抛 `OcrCancelledException`（与 Lens 同一语义），不落整卷产物；整卷产物
    只在全部页识别完后写，不再有空占位页。
- **[x] ② 已加自动化测试** —
  `fushi/test/media/manga/ocr/google_lens_ocr_service_test.dart`（「只补缺页不收别的引擎写的
  整卷产物」「只补缺页仍然复用 Lens 自己的逐页缓存」）；
  `fushi/test/media/manga/ocr/system_ocr_manga_service_test.dart`（「中途取消」用例补断言：
  取消后 `manga_ocr_out/manga.json` 不存在，重跑完成的产物没有空占位页）。
- **备注**：真机待验——先系统 OCR 跑到一半取消，再换 Lens 补缺，确认每页文字来自 Lens、
  已识别页不重复识别。「同一卷不同页来自不同引擎、顶层元数据只写一个引擎」这类后继问题
  （原 BUG-1851 担心的后果）不在本条范围：本条只堵「冒名」这一条入口。
