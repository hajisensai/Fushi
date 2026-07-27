## BUG-1147 · 漫画 OCR 查词坐标偏移且重启重复识别
- **报告**：2026-07-27（用户：）
- **真实性**：✅ 真 bug。`hibiki/lib/src/ocr/manga_ocr_folder_job.dart` 的本地页解码
  未烘焙 EXIF 方向，OCR 框使用编码像素矩阵坐标，而 Chromium 按 EXIF 方向显示图片，
  导致透明查词层与可见文字错位。后台入口也总会启动 OCR 服务，即使当前引擎的全部
  逐页缓存已经有效，造成重开后看起来又识别一次。
- **[x] ① 已修复** — 本地 OCR 在检测前统一 `bakeOrientation`，缓存签名升级为
  `local-onnx-v2-oriented`；本地 ONNX 与 Google Lens 后台任务先校验各自独立的
  逐页缓存，全部命中时直接重建产物和查词层，不启动模型或发起 Lens 网络请求。
  部分命中仍沿现有逐页断点续跑，只补源图指纹不匹配或尚未完成的页面。
- **[x] ② 已加自动化测试** —
  `hibiki/test/ocr/manga_ocr_folder_job_test.dart` 覆盖 EXIF 方向烘焙、取消后缓存保留、
  重跑只补缺页和源图变化只失效对应页；Lens 缓存隔离/恢复由既有 Google Lens
  OCR 专项测试覆盖。修复提交见后续记录。
- **备注**：旧 `local-onnx-v1` 缓存的坐标本身不可靠，因此升级后会做一次必要的
  重识别；从 v2 起，未修改的页面重开不会重复推理。
