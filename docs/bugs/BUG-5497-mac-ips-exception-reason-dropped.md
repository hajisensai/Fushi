## BUG-5497 · macOS .ips 摘要丢掉 ObjC 异常原因与抛出处的栈
- **报告**：2026-11-26（反馈 3LRSlAOkXu，Mac17,3 / 3.4.0，漫画阅读页 EXC_CRASH SIGABRT）
- **真实性**：✅ 真 bug（诊断缺口）。`fushi/lib/src/diagnostics/previous_exit_log.dart` `summarizeMacIpsReport` 只读 `exception` / `termination` / `asi` 与崩溃线程前 12 帧，不读 `.ips` 正文里的 `exceptionReason`（「-[X sel]: unrecognized selector sent to instance」原文）和 `lastExceptionBacktrace`；未捕获 ObjC 异常的崩溃线程前 8 帧全是 abort / terminate 机制，12 帧上限恰好把调用方截掉，这类崩溃永远定位不了。
- **[x] ① 已修复** — 摘要补 `exceptionReason`（type / name / composed_message）与 `last exception backtrace`；崩溃线程跳过开头的 abort 机制帧（`kMacAbortMechanismSymbols`，注明跳过帧数）后再取 12 帧。
- **[x] ② 已加自动化测试** — `fushi/test/diagnostics/previous_exit_evidence_test.dart`「BUG-5497」组。
- **备注**：崩溃本身（向谁发了不认识的 selector）要等用户下次崩溃带上新摘要才能查；同类已修的 BUG-3856 签名不同。
