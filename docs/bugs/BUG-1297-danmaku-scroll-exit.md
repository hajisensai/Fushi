## BUG-1297 · 滚动弹幕退场突兀：没滑出屏幕就被整条抹掉
- **报告**：2026-07-31（用户：弹幕消失的时候怪怪的，能不能让他自然到屏幕外面）
- **真实性**：✅ 真 bug。两个独立根因叠加，都在退场阶段：
  - **A｜宽度是估算，退场时刻算错**：`hibiki/lib/src/media/video/video_danmaku_layout.dart:174`（旧 `_estimatedWidth`）按「每字 `18 * fontScale`」估宽并 `clamp(36, 720)` 硬封顶，而实际渲染字号是 `20 * fontScale`（`video_danmaku_overlay.dart:211`）。滚动弹幕的行程是 `x = 视口宽 - (视口宽 + 文本宽) * progress`，`progress` 走到 1 的同一刻它离开活动集，于是宽度算少多少、文本右半截就有多少还留在画面里被整条抹掉。widget 层实测：22 字弹幕在停止渲染的那一帧右边缘仍在视口内 **44px**（22 × 少算的 2px）；超过 36 字的弹幕被 720 封顶后残留更多。
  - **B｜滚动弹幕在画面内渐隐**：`_opacityFor` 对所有模式统一套末段淡出（`progress ≥ 0.88` 线性到 0）。但 `progress = 0.88` 时短弹幕往往还在画面中间（400px 视口、6 字弹幕此时 `x ≈ 40`），于是它是「走到一半淡没了」，而不是滑出去。淡出只对不移动的 top/bottom 固定弹幕有意义。
  - 附带同源缺陷：`Text` 默认 `inherit: true` 会合并宿主 `DefaultTextStyle`，Material 的 `letterSpacing: 0.25` 让一条 22 字弹幕比纯函数测量侧宽 5.5px——测量与渲染两份真相，几何必然漂移。
- **[x] ① 已修复** — 新增 `video_danmaku_text_metrics.dart`：`kVideoDanmakuBaseFontSize` + `videoDanmakuTextStyle()`（`inherit: false`，渲染与测量共用的唯一样式真相源）+ `VideoDanmakuTextMetrics`（`TextPainter` 实测宽度，按 `(fontScale, text)` 缓存，超 512 条整体清空）。`VideoDanmakuLayout` 改用实测宽度并把它随 `VideoDanmakuLayoutEntry.width` 带出；`_opacityFor` 收窄为只对固定弹幕生效，滚动弹幕恒不透明、纯靠位移滑出视口由 `Stack(clipBehavior: Clip.hardEdge)` 裁掉。退场时刻与过期时刻自此严丝合缝。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_danmaku_layout_test.dart`（几何层：过期帧文本右边缘 ≤ 视口左边界、过期前一帧仍与视口有交集、滚动弹幕全程 opacity 恒 1、固定弹幕保留淡出、宽度不被 720 封顶且随字号缩放）+ `hibiki/test/media/video/video_danmaku_overlay_test.dart`（真实渲染层：`tester.getRect` 断言最后一帧文本框已整体越过视口左边界、滚动弹幕 `Opacity` 全程为 1）。
- **备注**：两组守卫均已**变异实测**：退回旧淡出曲线 → layout 层 `positionMs=7100` 处 opacity 0.9375、widget 层 7600ms 处 0.4167，双双转红；退回旧估算宽度 → widget 层残留 44px、layout 层宽度被封在 720，双双转红。几何断言刻意用**独立测得**的宽度而非 `entry.width` 做基准，否则几何一退化断言基准会跟着偏，守卫会自洽成废话（第一版就踩了这个坑）。
