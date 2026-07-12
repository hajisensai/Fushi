## BUG-763 · 制卡「选择句子上下文」模态显示不全（预览被按钮区遮挡）
- **报告**：2026-07-12（用户：qqbotxiaoxiao）
- **真实性**：✅ 真 bug。根因 `hibiki/assets/popup/popup.css` `.scm-boxes`（原 `overflow-y:auto` 但缺 `flex:1 1 auto; min-height:0`）+ `.scm-card`（有 `max-height:92%` 但无 `overflow:hidden`）。`.scm-card` 是 flex column，其 flex item 默认 `min-height:auto`（不小于内容 min-content 高度），故有 2+ 句多行预览时 `.scm-boxes` 拒绝收缩、内部 `overflow-y:auto` 永不触发，整卡被撑破 `max-height` 并居中溢出视口 → 预览区被挤成半行、`.scm-actions`/`.scm-foot` 压在预览上。
- **[x] ① 已修复** — `.scm-boxes` 加 `flex:1 1 auto; min-height:0`（放开收缩、激活内部滚动）；`.scm-card` 加 `overflow:hidden`（把内容夹在 max-height 内、圆角不漏）。三镜像同步（`assets/browser_extension/vendor/popup.css`、`tools/browser-extension/vendor/popup.css`）+ `generate-content-css.mjs` 重生成 content.css。提交：<待填>
- **[x] ② 已加自动化测试** — `hibiki/test/pages/sentence_context_modal_guard_test.dart` 补 `.scm-boxes` 含 `flex:1 1 auto`/`min-height:0`、`.scm-card` 含 `overflow:hidden` 的布局守卫（原 guard 只查选择器字符串、不检查 overflow/flex，故此 bug 溜过）。
- **备注**：真机验证待用户（多句上下文时模态可在卡内滚动、按钮不再遮挡预览）。
