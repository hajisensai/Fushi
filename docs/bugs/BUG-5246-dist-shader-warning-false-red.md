## BUG-5246 · Flutter 3.50 的着色器警告让 dist 把绿批次判红（「no done event」）
- **报告**：2026-11-22（做 HBK-AUDIT-225 验证时撞见：本机 dist 跑 `test/srs/srs_card_autoplay_gate_test.dart` 等 3 个套件，JSON 日志里 17 个用例全过、`done` 为 `success:true`，批次却判 FAILED）
- **真实性**：✅ 真 bug。Flutter 3.50.0 编 `liquid_glass_widgets` 的 `.frag` 时往 stdout 打「Shader Warning」框，位置在 json reporter 的 `start` 之前。`fushi/tool/test_flow/dist_results.dart` `splitEventRuns` 遇到 `start` 时只看「当前块非空」就切一刀，于是这段警告单独成了一个「run」：没有 `done`、0 个用例，`resolveFlutterTestVerdictFailure` 判它「harness 没报结果」，整批红。凡是会编这些着色器的批次在 3.50 上都会这样伪红。
- **[x] ① 已修复** — `splitEventRuns` 只在当前块里已有事件行（JSON 对象）时才在 `start` 处切分；不是事件的行跟着它后面那次运行走，不单独成块。
- **[x] ② 已增加自动化测试** — `fushi/test/tools/dist_results_test.dart` 「tool output before a run's start is no run of its own」：两次运行前各夹一段着色器警告，仍切成 2 次运行、批次绿、用例数 2。
- **备注**：
