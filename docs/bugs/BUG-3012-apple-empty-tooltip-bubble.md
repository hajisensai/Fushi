## BUG-3012 · 共享Tooltip在Apple分支把空消息变成可显示的空玻璃气泡
- **报告**：2026-10-06（Codex 共享控件迁移交叉审查）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/glass/fushi_glass_feedback.dart:732` 的 Apple 分支把任何消息包成玻璃气泡 `WidgetSpan`；即使原消息为空，其 `toPlainText()` 也变成 U+FFFC，绕过 SDK Tooltip 的空消息短路。本轮悬浮标题由原生 Tooltip 迁入共享组件后，未设置 titleTooltip 的调用方会触达该缺陷。
- **[x] ① 已修复** — 创建气泡前按原消息的纯文本判空，空消息直接保留 child；MD3 原转发逻辑不变。修复提交号收口后补录。
- **[x] ② 已增加自动化测试** — `fushi/test/widgets/glass/fushi_glass_feedback_test.dart` 新增 Apple/MD3 × plain/rich 四个空消息案例，主动请求显示仍不显示、子控件可点击、无玻璃气泡、无 tooltip 语义。
- **备注**：当前为根因定位与自动化回归，设备端 Apple 视觉复测未执行；本任务未构建或运行非 Windows galgame 实现。实际执行结果见外部 `outputs/verify-1006-last.md`。
