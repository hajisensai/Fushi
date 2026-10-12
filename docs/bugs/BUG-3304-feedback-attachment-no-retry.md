## BUG-3304 · 反馈附件上传失败后无法重试
- **报告**：2026-10-13（用户反馈 #AcHo3yVAca：上传日志时附件没传上去，没有重试也没有重试按钮；#uyoDqalpZe 追加说明时想再加截图）
- **真实性**：✅ 真 bug。`fushi/lib/src/feedback/feedback_service.dart` 旧 `submit()` 附件失败只 `failed++` 并写日志，字节随即丢弃，之后无任何入口可补传；服务端 `putAttachment`（`services/leaderboard/src/feedback.js`）其实允许 24 小时内对原工单补传空闲槽位（s0..s2 / log，同槽位只收一次，重传 409 `slot_taken` 客户端已视为成功），所以不需要服务端改动。
- **[x] ① 已修复** — `bf1e268c6c`：失败的附件字节落盘到 `<数据根>/feedback/pending/<id>/<slot>`（`FeedbackPendingStore`），`FeedbackService.retryPending` 重传（网络类失败留着，400/403/404/413 丢弃并报告，成功清除），`addScreenshots` 往空闲截图槽位追加截图；反馈人详情页出现「还有 N 个附件没上传成功 + 重试上传」提示，以及 24 小时内、槽位未满时的「追加截图」按钮。「从本机移除」一并清掉待传文件。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_attachment_retry_test.dart`（落盘 / 重启恢复 / 重试 / 409 / 403 丢弃 / 追加槽位选择 / 窗口 / 移除）；`fushi/test/feedback/feedback_pages_test.dart`「反馈人详情：有没传上去的附件时给提示与重试按钮」。
- **备注**：视频附件、完成推送、跨设备工单列表不在本次范围。
