## BUG-5498 · 崩溃报告正文里会话标记的内存采样挤掉平台证据
- **报告**：2026-11-26（反馈 rfmUsTI66G，Windows 3.3.0 nativeCrash；同类 aGhR5_ns4w、uirUDjQJvX 的 Android ExitInfo 也被截断）
- **真实性**：✅ 真 bug（诊断缺口）。`fushi/lib/src/diagnostics/previous_exit_log.dart` `describeUncleanPreviousSession` 把全部 `memorySamples` 拼进条目且不限长（单条可超 6000 字），`collect` 又把它排在 Android / Windows / macOS 平台证据之前；`classifyPreviousExit` 按收集顺序拼接后整体 `_cap` 到 `kExitVerdictSummaryMaxChars`（6000），决定种类的平台证据（Windows 崩溃摘要、WER、ExitInfo、.ips）被挤出正文。
- **[x] ① 已修复** — `classifyPreviousExit` 摘要改为：决定种类的证据排最前，其余有种类的按优先级，再是旁证；每条先按 `kExitSummaryMaxChars` 单独限长再整体限长。会话标记条目的 `memory=[…]` 移到条目最末，判定标签（退出意图、前后台结论）留在截断点之前。
- **[x] ② 已加自动化测试** — `fushi/test/diagnostics/previous_exit_evidence_test.dart`「BUG-5498」组。
- **备注**：rfmUsTI66G 这次崩溃本身缺证据，定位不了；修好后下次报告会带上异常码 / 模块。
