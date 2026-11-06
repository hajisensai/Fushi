## BUG-3925 · ai-panel-tight-mode-hides-context-chip
- **报告**：2026-10-31（用户：合并第三方 PR #2667 前的审查）
- **真实性**：✅ 真 bug（PR #2667 引入）。`fushi/lib/src/pages/implementations/ai_agent_page.dart` `_composer` 在紧凑排版（对话区高 < `kAiAgentTightHeight`）下 `if (contextTitle != null && !tight)` 把「关于：…」上下文 chip 整个藏掉，屏幕附件 chip 同样藏掉；而这颗 chip 是查看 / 移除本条消息所带上下文（`onDeleted` 置 `_contextDropped`）的唯一入口——横屏弹出键盘时用户看不到、也去不掉附带的上下文。
- **[x] ① 已修复** — 紧凑排版把上下文 chip（单行省略号、紧凑密度）与屏幕附件 chip 收进输入行左侧一条，最多占行宽 `kAiAgentTightAttachmentWidthFactor`（0.4），删除键始终可点；输入行固定用同一个 `LayoutBuilder → Row` 结构，切进紧凑排版时输入框不被重建、不丢焦点；输入框提示语 `hintMaxLines: 1`（默认随 maxLines=4，输入框一变窄提示语折行把输入栏撑到 100dp、对话区只剩 16dp）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/ai_agent_keyboard_layout_test.dart`（紧凑排版 chip 在输入行内、点删除后下一条 `send` 的上下文为 null；宽松排版 chip 在输入行上方；键盘切换后同一 `EditableTextState` 仍持焦点）。
- **备注**：
