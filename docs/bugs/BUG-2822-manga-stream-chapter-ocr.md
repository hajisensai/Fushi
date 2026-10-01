## BUG-2822 · 在线直读章完全不做 OCR，手机上只能下载后等整章识别完
- **报告**：2026-10-01（用户：移动端还不能边 OCR 边看）
- **真实性**：✅ 真缺口。设计稿 2026-09-12 §1.2 规定在线直读章在阅读器内不触发任何 OCR（`fushi/lib/src/media/manga/reader/manga_fushi_page.dart:1909` `if (streaming) return;`，`_noChapterOcr` 在 `:3633` 把直读章排除在所有 OCR 入口外），只有下载完成的章才由阅读器外的整卷任务识别。在线源正是手机上的主要读法，于是手机上读在线漫画只能「先下载、再等整章识别完」，没有任何边看边识别的路径。本次按用户要求改掉 §1.2 这条。
- **[x] ① 已修复** — 新增 `fushi/lib/src/media/manga/reader/manga_reader_stream_ocr.dart`：`prepareMangaStreamOcr` 与整卷路径同一口径解析引擎（Lens 先过上传同意闸门，外部 CLI / 已配对主机只会整卷跑，直读章不识别），本地 ONNX 走常驻页会话 `MangaOcrPageService.openPageSession`（模型只加载一次），Lens / 系统 OCR 走单页识别 `recognizePageBytes`；`MangaStreamPageOcr` 串行识别读者当前页与后两页，识别完一页热替换一页，读者翻走后窗口跟着走。阅读器在直读章就绪、设置面板改触发方式时启动，换章 / 退出时关闭；手动触发模式不自动识别。结果只活在直读会话里（随会话目录删），想留住仍是下载本章。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_ocr_follow_reader_test.dart`「MangaStreamPageOcr（在线直读章）」组：从当前页起串行识别、逐页交出、翻走后窗口跟随、失败不原地重试、close 丢弃在跑结果并释放识别器。
- **备注**：阅读器里的直读接线（`_maybeStartStreamingOcr`）没有页面级自动化测试——直读章要真在线源会话，widget 测试装不起来；未在手机真机上复测（本机无 adb 设备）。同时跑整卷任务（另一章）与直读页会话时本地 ONNX 会有两份推理会话，低内存设备需要关注。
