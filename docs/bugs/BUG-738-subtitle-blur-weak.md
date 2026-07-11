## BUG-738 · 视频听力沉浸字幕模糊度不够(固定8px不随字号缩放)
- **报告**：2026-07-11（用户：qqbotxiaoxiao）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/video_subtitle_overlay.dart:829`——听力沉浸「模糊态」的高斯模糊 sigma 硬编码为 `ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8)`，是个**与字幕字号无关的绝对像素值**。默认字号 36 时 8/36≈0.22×，本就偏浅；用户把字幕字号调大（外观设置或 respectAssStyle 放大）后，8px 相对更大的字形占比更小，字仍读得清，遮蔽失效——违背「听力沉浸=读不出、仅悬停/点击显形」的本意。
- **[x] ① 已修复** — commit 见下。把固定 8 换成随字号缩放的纯函数 `VideoSubtitleOverlay.obscureBlurSigma(fontSize) = max(12, fontSize×0.45)`（默认 36→16.2≈旧值两倍，60→27），调用点 `video_subtitle_overlay.dart` `_wrapInteractive` 模糊态用 `widget.fontSize` 求 sigma。消除「固定绝对像素」这一特殊情况，任何字号下遮蔽强度同构且足够。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_obscure_blur_sigma_test.dart`：钉死 sigma 随字号单调递增、默认 36 显著强于旧值 8、大字号更强、小字号有下限、比例正确。
- **备注**：未新增用户可调设置（避免过度设计）；根因是缩放缺失，不是缺开关。真机目视验证（大字号字幕开听力沉浸应真读不出）待用户在设备上确认。
