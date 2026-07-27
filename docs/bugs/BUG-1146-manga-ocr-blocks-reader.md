## BUG-1146 · 漫画 OCR 模态阻塞阅读且完成页不能立即查词
- **报告**：2026-07-27（用户：）
- **真实性**：✅ 真 bug。根因是
  `hibiki/lib/src/media/manga/manga_ocr_wizard_dialog.dart:468` 之前由模态向导持有
  OCR 订阅并等待整卷完成才 `Navigator.pop`，逐页缓存没有送入阅读器；同时
  `hibiki/lib/src/media/manga/manga_overlay_html.dart:445` 的裸图单击仍打开独立大图。
- **[x] ① 已修复** — 选好引擎后返回阅读器持有的后台任务；本地 ONNX 与 Lens
  每完成一页就读取各自缓存并通过 `__mangaReplaceOcr` 热替换透明文字层。
  单击 OCR 区和 Shift 悬停均查词，裸图单击改为 no-op。修复提交见后续记录。
- **[x] ② 已加自动化测试** —
  `hibiki/test/media/manga/manga_overlay_html_test.dart` 覆盖后台逐页 DOM 替换、
  单击/Shift 悬停查词与禁止裸图大图入口；
  `hibiki/test/media/manga/manga_full_page_ocr_contract_test.dart` 守卫框选协议彻底移除。
- **备注**：Windows 真应用观察到向导关闭后 OCR 从 2/100 推进到 4/100，同时可
  从双页翻到第 1 页，阅读器未被阻塞；未由自动化接受 Lens 隐私告知或发起真实上传。
