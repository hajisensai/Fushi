## BUG-3388 · 悬浮字幕多句时上下文行描边被降亮字色覆盖
- **报告**：2026-10-14（用户：反馈悬浮字幕默认样式很丑，改造时沿渲染路径发现）
- **真实性**：✅ 真 bug。`fushi/windows/runner/floating_lyric_window.cpp` `Render()` 的多行上下文分支在描边 / 投影遍**之前**就用 `SetDrawingEffect` 给非当前行挂降亮画刷；D2D 的 drawing effect 会盖掉 `DrawTextLayout` 传入的画刷，于是 16 遍描边对上下文行画的是降亮的字色而不是描边色，字形边缘糊成一团。且 `text_layout_` 跨帧复用，效果一直残留。（hook 模式注释原称「hook 恒传 current_line_start=-1」，但有声书悬浮字幕自 hook 化后同样走 hook 模式且会传当前行区间，前提不成立。）
- **[x] ① 已修复** — 描边遍前先 `SetDrawingEffect(nullptr, 全段)` 清空，降亮 / 当前句画刷收进 `apply_line_effects`，只在最后一遍填充 `DrawTextLayout` 前挂上（悬浮字幕 M3E 改造同一提交）。
- **[x] ② 已加自动化测试** — `fushi/test/build/floating_lyric_context_effect_order_guard_test.dart`（钉清空先于描边、挂效果紧接填充遍）。
- **备注**：native 渲染无单测装置，只能钉源码顺序；真机像素需 Windows 原生窗目视。
