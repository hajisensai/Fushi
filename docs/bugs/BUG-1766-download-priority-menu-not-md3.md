## BUG-1766 · 排队优先级菜单未走MD3共享原语
- **报告**：2026-08-21（用户截图：任务卡「排队」优先级弹出菜单是裸 Material 默认样式，未走 MD3）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/video_download_jobs_panel.dart:750`（旧行号）——优先级菜单裸用 `PopupMenuButton<int>`，没吃 `FushiDesignTokens` 的 menuRadius/overlay 色/动画，也进不了手柄焦点体系；本仓业务页面菜单的约定原语是 `FushiOverflowMenu`（`fushi_material_components.dart:2500`）。
- **[x] ① 已修复** — 换 `FushiOverflowMenu<int>` + `FushiPopupMenuItem`（当前档位 selected 高亮），busy 态单独渲染禁用按钮脸；同批新增的任务排序菜单同走该原语。随 worktree-downloads-page-batch-a 批次提交。
- **[x] ② 已加自动化测试** — 源码扫描守卫 `fushi/test/pages/video_download_jobs_panel_md3_guard_test.dart`（正则禁裸 `PopupMenuButton(`/`PopupMenuButton<T>(` 构造 + 必须出现 `FushiOverflowMenu<`）。已变异实测：先发现 `contains('PopupMenuButton(')` 会被泛型形态逃过、改正则后变异双向验证通过；行为层由 `video_download_jobs_panel_test.dart` 既有优先级点击测试兜住。
- **备注**：全仓 md3 静态守卫（`md3_design_system_static_test.dart`）此前未覆盖本文件，故补文件级守卫。
