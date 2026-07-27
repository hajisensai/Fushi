## BUG-1130 · 漫画 OCR 横竖排字符在缩放后查词偏移
- **报告**：2026-07-27（用户：）
- **真实性**：✅ 真 bug。`hibiki/lib/src/media/manga/manga_overlay_html.dart`
  旧命中逻辑依赖浏览器 caret 猜测透明文本位置；缩放和竖排下，同一大框内的 caret
  几何与可见字符不一致，且命中容差会随 CSS 缩放一起放大。
- **[x] ① 已修复** — OCR 块统一生成带 UTF-16 偏移的透明字符命中层；
  Lens 使用服务端行几何，本地 ONNX/旧 mokuro 使用横排从左到右、竖排从上到下的
  近似字符区域。命中改为固定 4 屏幕像素容差并选择最小重叠字符框。
- **[x] ② 已加自动化测试** —
  `hibiki/test/media/manga/manga_overlay_html_test.dart` 覆盖横竖排、UTF-16、
  显式 Lens region、固定屏幕像素容差和 50%–200% 缩放契约。
- **备注**：Windows 真应用在 Sieger 第 16 页分别以 100% 和 110% 点词；
  110% 精确命中横排「フ」并由明鏡词典返回「ふ」词条。
