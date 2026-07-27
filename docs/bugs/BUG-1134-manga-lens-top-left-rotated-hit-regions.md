## BUG-1134 · 漫画 Lens OCR 坐标上下镜像且旋转文字点词错位
- **报告**：2026-07-27（用户：）
- **真实性**：✅ 真 bug。`hibiki/lib/src/media/manga/ocr/google_lens_protocol.dart:329`
  照搬 Niratan 的原生画布换算时把 Lens Y 轴再次翻转，但 Hibiki WebView 与 Lens
  都是左上原点，导致上方说明映射到下方文字；旋转行又先变成大 AABB 再等分，每个
  字符会覆盖斜线的大半区域。
- **[x] ① 已修复** — WebView 路径直接使用 Lens 左上原点坐标；字符框沿原始旋转
  基线细分后再取各自 AABB。缓存记录 `geometry_version: 2`；旧 v1 页缓存读取时在
  本地反转回正确 Y 轴并按视觉行/列重排句子与 UTF-16 偏移，无需重新上传。
- **[x] ② 已加自动化测试** —
  `hibiki/test/media/manga/ocr/google_lens_protocol_test.dart` 覆盖上到下行序与旋转
  小字符框；`google_lens_ocr_service_test.dart` 覆盖旧缓存迁移且零网络恢复。
- **备注**：Sieger 真图原缓存中「フィッシャー…」曾落在页面上方；迁移后点实际
  下方段落，在 110% 精确命中「フ」且句子/词典一致。
