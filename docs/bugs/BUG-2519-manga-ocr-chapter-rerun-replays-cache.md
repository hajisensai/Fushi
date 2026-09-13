## BUG-2519 · 作品页「识别本章」对已识别的章只回放旧结果，不重新识别
- **报告**：2026-09-13（用户：「我点击识别本章，好像没自动重新识别」）
- **真实性**：✅ 真 bug（设计缺口）。`fushi/lib/src/media/manga/library/manga_series_page.dart` `_ocrChapter` 只查「章已下载」就排任务；`manga_ocr_job_stream.dart` `mangaOcrLocalEvents` 先按引擎签名读 `manga_ocr_out/_pages/<签名>/` 逐页缓存，整卷命中直接回放 + finished，一次 OCR 都不跑。签名只由模型文件内容决定（BUG-1173），模型没换恒命中，用户点按钮什么都不变。`MangaOcrJobSpec.onlyMissing` 声明了但本地 / Lens 路径没人消费。
- **[x] ① 已修复** — `9dea0c11e4`：有结果的章 `onlyMissing=false`（`_chapterNeedsOcr` 判），本地 / Lens 路径先 `discardMangaOcrPageCache` 丢掉本签名缓存目录再跑；没结果（含中断）的章保持续跑；「识别全部已下载」只挑没结果的章，语义不变。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_ocr_job_stream_rerun_test.dart`（只删指定签名目录、兄弟签名保留、不存在无事）。
- **备注**：真机点按钮走注册表排队 → 事件流 → 缓存删除这条整链未在 app 上肉眼复测，待补。审查指出「已配对主机」引擎路径（`mangaOcrRemoteEvents`）不看 `onlyMissing`——缓存在 host 侧按卷名哈希复用，互联协议没有 force 标志，本轮不扩；选 pairedHost 的用户点「识别本章」仍是回放，要重跑得在 host 上清 `manga_ocr_out/_pages/`。manga.json 读不出的章按三态处理：不丢缓存、不排「识别全部」。
