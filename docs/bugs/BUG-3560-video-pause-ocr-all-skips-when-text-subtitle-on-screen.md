## BUG-3560 · video-pause-ocr-all-skips-when-text-subtitle-on-screen
- **报告**：2026-10-19（用户：「视频暂停的时候有时候 OCR 不会启动。我明明开启了全部视频 OCR」）
- **真实性**：✅ 真 bug。暂停 OCR 选「所有视频」时，`VideoPauseOcrScope.shouldRecognize`（`fushi/lib/src/media/video/video_pause_ocr_scope.dart:57` 旧版）在 Fushi 自绘文字字幕（主或副）在屏、或内封文字字幕还在后台抽取时返回 false，覆盖层 `_currentKey`（`video_graphic_subtitle_ocr_overlay.dart:170` 旧版）据此整帧不识别、也不给任何提示。暂停多半落在台词显示期间（想看这句 / 点字幕查词 / 句尾自动暂停），所以表现为「有时候不启动」。本机 `error_log.txt` 无任何暂停 OCR 报错，排除异常路径。用户拍板：「字幕和 OCR 有什么关系，我要看的是视频里的文字」——Fushi 自绘的文字字幕本就不在 libmpv 截帧里，让位只会挡掉画面识别。
- **[x] ① 已修复** — `all` 档每次暂停（首帧已出）一律识别，删掉 `textCueOnScreen` / `textCuesLoading` 两个让位入参；「仅图片字幕」「关闭」两档行为不变；设置项说明文案去掉「文字字幕优先」。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/graphic_subtitle_pause_ocr_test.dart`（`all` 档恒识别）、`fushi/test/media/video/video_graphic_subtitle_ocr_overlay_test.dart`（主字幕在屏 / 只开副字幕在屏 / 内封字幕抽取中照样截帧识别；识别后副字幕出现结果保留、不重识别）。
- **备注**：已知取舍——画面硬字幕与 Fushi 文字字幕恰好叠在同一位置时，OCR 可点框（挂在字幕层之上）会接住那块的点击，查到的是画面里的字。
