## BUG-763 · 制卡「选择句子上下文」模态显示不全（预览被按钮区遮挡）
- **报告**：2026-07-12（用户：qqbotxiaoxiao）
- **真实性**：✅ 真 bug。根因：模态画在查词弹窗 WebView 内、`.scm-boxes` 缺 `flex:1 1 auto; min-height:0` 且 `.scm-card` 无 `overflow:hidden`，flex column 里默认 `min-height:auto` 拒收缩 → 内部滚动不触发、卡撑破挤成半行、按钮压在预览上。
- **[x] ① 已修复（→ 由 [[BUG-776]] 根治取代）** — 最初打 CSS 补丁（`.scm-boxes` 加 `flex:1 1 auto;min-height:0`、`.scm-card` 加 `overflow:hidden`）治标。用户随后指出「这个是要顶层弹窗，不是查词弹窗内」——**根因是模态画在弹窗 WebView 内**（受其表面尺寸/半透明约束），CSS 补丁治标不治本。故整块模态改为 **app 原生顶层 Flutter 对话框**（见 BUG-776，`SentenceContextDialog`），旧 WebView HTML 模态 + `.scm-*` CSS 补丁**一并删除**。显示不全随之根治。提交：cc6484e87（CSS 补丁）→ 被 BUG-776 提交删除并取代。
- **[x] ② 已加自动化测试** — 原 `sentence_context_modal_guard_test.dart` 的 `.scm-*` 布局守卫已随模态删除；改为 BUG-776 的对话框 widget 测试 + 重写守卫（断言旧模态/`.scm-*` 已删除、原生对话框接线齐全）。
- **备注**：本条与 [[BUG-776]] 合并看待——BUG-763 是 WebView 内 CSS 症状，BUG-776 是「搬成顶层原生对话框」的根治。真机验证待用户。
