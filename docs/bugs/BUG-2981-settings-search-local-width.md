## BUG-2981 · 设置搜索回车使用全窗宽度导致窄内容区无法打开结果
- **报告**：2026-10-06（样式改版审查）
- **真实性**：真实代码路径缺陷。`fushi/lib/src/settings/settings_home_page.dart:463` 原回车路径用 MediaQuery 全窗宽度判断宽布局，实际布局却使用 LayoutBuilder 可用宽度。全窗 900px、内容区 680px 时回车只更新不可见的详情选择并清空查询，不 push 详情页。
- **[x] ① 已实现修复** — 回车与点击共用实际布局的 wide 判据。提交见本文件所在修复提交。
- **[x] ② 已增加自动化测试** — `fushi/test/settings/settings_home_search_breakpoint_test.dart`：Material / Glass 两套主题下 Enter / 点击四种路径。
- **备注**：运行结果见 `docs/reviews/2026-10-06-project-review.md`；未完成真实设备验收，不宣称实机修复验证通过。
