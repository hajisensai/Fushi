## BUG-1229 · 自定义 CSS 遮罩退出丢失草稿且关闭即保存
- **报告**：2026-07-29（用户反馈）
- **真实性**：✅ 真 bug。`hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart:568`
  的范围切换会调用持久化 setter，旧 footer 的“关闭”也会直接保存；对话框被遮罩关闭时
  state/controller 随路由销毁，没有任何跨实例草稿。
- **[x] ① 已修复** — `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart:498`
  增加与当前 `AppModel + profileDraftScope` 绑定的会话草稿，范围切换和非按钮退出只暂存；
  footer 改为“取消 / 保存”，取消清空草稿，保存一次性提交所有已编辑范围并清空草稿。
  审查补强还在保存前复核 Profile 草稿作用域：真正应用 Profile 时旧草稿精确失效，
  不会把 A Profile 的 CSS 写进 B Profile；首次异步加载从 `-1` 取得真实 Profile id
  不轮换作用域，避免误杀首开草稿并导致 Save 静默丢弃。
- **[x] ② 已加自动化测试** —
  `hibiki/test/pages/dictionary_css_editor_dialog_test.dart:178` 覆盖遮罩退出不持久化、
  重开恢复、取消丢弃；`:214` 覆盖切换范围不写入以及保存统一提交；Profile 回归覆盖
  “首次懒加载后 Save”、“关闭后切换再打开”和“编辑器打开期间切换后点击保存”三条路径。
- **备注**：定向 widget 测试 8/8 通过；仓库未写入任何 native-asset 测试绕过配置。
