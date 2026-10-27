## BUG-3805 · 方向键改绑成相反翻页方向仍被阅读方向校正覆盖
- **报告**：2026-10-24（用户：反馈 aiRZmYl5zS，Android 键盘 / 手柄，把上 / 右键绑成「上一页」后书里右键仍翻下一页）
- **真实性**：✅ 真 bug。`resolveReaderArrowPageTurn` 只判「该键是否绑定到翻页动作」，不看前进还是后退，随后一律按阅读方向重定向，覆盖了用户把右键改绑成 `readerPageBackward` 的意图（`fushi/lib/src/shortcuts/reader_space_override.dart:73`）。
- **[x] ① 已修复** — 阅读方向校正只接管出厂物理方向绑定（左 = 后退、右 = 前进，见 `shortcut_defaults.dart`）；改成相反方向 / 别的动作 / 解绑都交回注册表解析真实绑定。提交见分支 `claude/feedback-system-fix-d0ccae`。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_space_pause_test.dart`（新增反向改绑让出用例；既有用例的 boundAction 改为真实默认绑定）。
- **备注**：反馈里的「反转范围」「底栏反转项」是设计建议，未在本条处理。
