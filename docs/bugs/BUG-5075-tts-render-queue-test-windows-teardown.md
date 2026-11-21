## BUG-5075 · Windows 上 tts_text_rules_and_rate_limit_test 的 tearDown 删临时目录报 errno 145（目录非空）
- **报告**：2026-11-21（审查 PR #3755 时在 Windows 本机跑 packages/fushi_engine/test/tts/ 发现）
- **真实性**：⏳ 待查。`packages/fushi_engine/test/tts/tts_text_rules_and_rate_limit_test.dart` 的「render job rate-limit parameters enqueue persists concurrency, gap and action」在 Windows 上单独跑也红：tearDown 删临时目录报 FileSystemException errno 145（目录非空）。被测 render queue 代码与 #3755 无关；疑似测试结束时仍有文件句柄 / 后台写入未关，删目录前没等它收尾。
- **[ ] ① 未修复** — 查清是谁还占着目录里的文件（未 await 的写入 / 未关闭的 sink / isolate），在被测代码或测试里按生命周期收尾，不靠重试删除掩盖。
- **[ ] ② 未加自动化测试** — 修复后该用例在 Windows 上稳定通过即为回归覆盖。
- **备注**：
