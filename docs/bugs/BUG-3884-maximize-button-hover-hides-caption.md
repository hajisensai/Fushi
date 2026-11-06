## BUG-3884 · maximize-button-hover-hides-caption
- **报告**：2026-10-30（用户：用户：沉浸顶栏悬停到中间最大化按钮时整条被隐藏）
- **真实性**：✅ 真 bug（本 PR 引入后自测发现）。Windows 最大化按钮是 `HTMAXBUTTON` 原生命中区（Snap Layouts），鼠标进入后 Flutter 收不到 hover，`_ImmersiveCaptionReveal` 以为鼠标离开而淡出。
- **[x] ① 已修复** — 显示判据并入 `WindowCaptionChannel.captionMaxButtonHovered / Pressed`；淡出结束后撤掉原生最大化矩形，避免看不见的区域误触最大化。
- **[x] ② 已加自动化测试** — `fushi/test/desktop/fushi_title_bar_page_colors_test.dart`「指针进入顶栏才显示，离开淡出；原生最大化键悬停也算」（直接驱动 `WindowCaptionChannel.captionMaxButtonHovered`；runner 回传本身仍只人工确认过）。
- **备注**：Windows 调试实例上人工确认过。
