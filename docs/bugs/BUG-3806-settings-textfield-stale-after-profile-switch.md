## BUG-3806 · 切换 Profile 后设置输入框仍显示上一个 Profile 的值
- **报告**：2026-10-25（用户：反馈 XyTPrbdKSZ，Android，制卡设置切换 Profile 后标签框显示上一个 Profile 的值，退出再进才对）
- **真实性**：✅ 真 bug。`AdaptiveSettingsTextField` 把 `initialValue` 直接交给 `FushiTextField`，值只在控制器创建时灌一次（`fushi/lib/src/utils/components/settings_shared.dart:3257`），外部值变化（切 Profile / 异步加载）不反映；制卡设置的两个标签框（`anki_settings_page.dart:2366`、`:2382`）因此显示旧值。
- **[x] ① 已修复** — 组件层修：`initialValue` 形态下组件自持控制器，外部值变化且输入框无焦点时同步；正在输入不冲掉，父级未改值的普通重建不回退用户输入。所有 initialValue 形态的设置输入框一并受益。提交见分支 `claude/feedback-system-fix-d0ccae`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/adaptive_settings_textfield_external_value_test.dart`（外部值跟随 / 输入中不冲掉 / 值未变不回退）。
- **备注**：
