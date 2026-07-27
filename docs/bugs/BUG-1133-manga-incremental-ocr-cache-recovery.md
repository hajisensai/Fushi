## BUG-1133 · 漫画增量 OCR 缓存重开后未恢复
- **报告**：2026-07-27（用户：）
- **真实性**：✅ 真 bug。`hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:464`
  重开书时只解析正式 `manga.json`；按设计只有整卷成功才替换该文件，因此取消或仍在
  后台运行的本地/Lens 已完成页虽然有原子缓存，重开后透明查词层仍为空。
- **[x] ① 已修复** — 新增
  `hibiki/lib/src/media/manga/ocr/manga_ocr_cache_recovery.dart:28`，首帧后无网络地
  合并两种引擎的有效逐页缓存：正式非空页优先，空白页选最近完成的引擎缓存；
  源图指纹不符只丢弃对应页，并热替换当前窗口文字层。
- **[x] ② 已加自动化测试** —
  `hibiki/test/media/manga/manga_ocr_cache_recovery_test.dart` 覆盖本地/Lens 混合恢复、
  正式结果优先、最近引擎优先及源图失效。
- **备注**：重启真应用后未启动 OCR，Sieger 第 1 页直接使用本地缓存查词，第 16 页
  直接使用 Lens 缓存查词；正式 `manga.json` 仍保持原子整卷语义。
