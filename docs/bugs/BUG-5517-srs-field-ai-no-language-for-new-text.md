## BUG-5517 · Card field AI: prompt never says which language new example text is written in
- **报告**：2026-11-24（用户：查看字段 AI 内置预设时发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/ai/ai_srs_field_assistant.dart:120`（修前 `kAiSrsFieldSystemPrompt`）与 `_taskLine` 只在「写释义」「翻译」两个任务里提到输出语言（界面语言），从不说新写的例句该用哪种语言；改写 / 自定义任务连输出语言都不带。内置预设「Learner-level example」（`ai_saved_prompts.dart`，「写一个适合中级学习者的自然例句」）或用户自己敲「写个例句」时，模型手里唯一的语言线索就是界面语言，常把例句写成英文 / 中文，而不是在学的语言。
- **[x] ① 已修复** — 根因在提示词缺规则，不在某一条预设：系统提示加「语言」一段——释义、翻译、说明用请求里给的输出语言；新例句及其它属于所学语言的文字用笔记例句 / 词头的语言，除非用户另有说明。用户侧提示每个任务都带 `Output language: <语言>` 一行。不改预设文案（改了要动 17 份翻译，且用户自己敲的指令照样会错）。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_note_editing_markup_test.dart`「每个任务都带输出语言」（四个任务逐一断言）与「系统提示写明加粗 = 目标词、新例句用笔记的语言」。
- **备注**：输出语言仍是界面语言的标签（如 `en`）；改成语言名、单独的「AI 输出语言」设置属于后续「可编辑字段 AI 动作」。
