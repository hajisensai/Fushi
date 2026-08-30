## BUG-1958 · 在线漫画点击查词无视已下载本地模型并强制 Google Lens
- **报告**：2026-08-30（用户：已下载本地模型，在线漫画点击查词仍提示只能使用 Google Lens）
- **真实性**：✅ 真 bug。修复前 `fushi/lib/src/media/manga/reader/manga_fushi_page.dart:2847` 的在线点击分支无条件调用 `_buildOnlineOcrJob`，后者在原 `:2944` 附近把引擎钉死为 `MangaOcrEngineId.googleLens`；而 `fushi/lib/src/media/manga/mihon/mihon_online_ocr.dart:110` 已能通过 `MangaReaderSession.localFile` 将网络页物化成本地文件，离线 OCR 并不存在图片不可达的边界。
- **[x] ① 已修复** — 在线章节先按统一能力探测解析用户偏好；Google Lens 保留当前页优先的逐页路径，其他引擎将在线页安全物化到章节受管 `images/` 目录后复用本地书 OCR 编排。提交：待本轮提交。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/online_manga_local_ocr_test.dart` 覆盖“本地 ONNX 模型就绪 + 在线章节”路径，断言实际引擎为本地 ONNX、不会触发 Lens 上传告知，并验证全部页图在本地 OCR 启动前完成物化。
- **备注**：代码与自动化测试完成后，仍需 Android 真机按用户原始在线章节点击查词路径肉眼复测。
