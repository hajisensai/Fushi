## BUG-3895 · 日志上传截断只截日志原文，请求体仍超接收端上限 →「日志过大，无法上传」
- **报告**：2026-10-28（用户：反馈 4k7x0-1MHe 的后半条，Windows）
- **真实性**：✅ 真 bug（但不在「反馈」提交路径）。「日志过大，无法上传」（`log_upload_too_large`）全仓只在 `fushi/lib/src/utils/misc/log_uploader.dart:245`（错误日志 / 调试日志页的「上传」）收到 413 时出现，App「反馈」提交没有这条文案。根因 `log_uploader.dart:41-53,70-77`（基线 896d45a9b2）：`_capLogBytes` 把日志**原文**截到 512 KiB 后再 `jsonEncode`，而接收端限的是**整个请求体**（`services/log-backend/cf-worker/src/worker.js:7` `MAX_BODY_BYTES = 512 * 1024`）；换行、Windows 路径反斜杠、Rust Debug 里的引号转义后各多一字节，加上元信息，日志只要超过上限请求体必然超限 → 413。
- **[x] ① 已修复** — `encodeLogUploadBody`：按编码后整个 JSON 的实际字节数逐步收紧日志预算，保证请求体 <= `kMaxLogUploadBytes`，仍保留最近尾部并带截断标记。提交 d633c28275（PR pr/fb-mining）。
- **[x] ② 已加自动化测试** — `fushi/test/utils/log_uploader_test.dart`（「整个请求体（JSON 转义 + 元信息）都在上限内」：2 MiB 含反斜杠 / 引号 / 换行 / 制表符的日志，断言 `bodyBytes <= 512 KiB`、保留尾部）。
- **备注**：用户原话是在「反馈」里勾附带日志，但该文案只出自日志页上传，推断用户实际点的是错误日志页的「上传」；Go 版接收端默认 1 MiB 时不触发，CF Worker 版必触发。
