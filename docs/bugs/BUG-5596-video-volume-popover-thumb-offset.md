## BUG-5596 · video-volume-popover-thumb-offset
- **报告**：2026-11-27（用户：截图，Windows 播放器 Apple 设计系统，底栏音量浮层把手偏上、「静音切换」气泡压在浮层上）
- **真实性**：✅ 真 bug。① `fushi/lib/src/utils/components/glass/fushi_glass_toggles.dart` `FushiAppleSlider.build` 圆钮 `top` 按声明高度 `m.height`（桌面 28）算，但音量浮层（`video_volume_overlays.dart` `VideoVolumePopoverCard`）把滑条放进 40 高的紧约束行，外层 `SizedBox(height: m.height)` 被撑成 40，轨道 CustomPaint 按实际高度居中 → 把手比轨道高 6px（×界面缩放）；区间滑条 `_GlassRangeSliderState` 同一写法。② `video_fushi/controls_popover.part.dart` `_buildVolumeButton` 给入口按钮挂了 `FushiTooltip(静音切换)`：桌面悬停即弹浮层，气泡叠在浮层上，且点入口是开浮层不是静音（倍速入口 tooltip 本就为空）。
- **[x] ① 已修复** — 两种 Apple 滑条在 LayoutBuilder 里按实际 `constraints.maxHeight` 居中圆钮；音量入口去掉 tooltip，改用 `Semantics(label: video_control_volume)`，「静音切换」只留在浮层内静音键。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/glass/fushi_glass_toggles_test.dart`「Apple slider thumbs stay centred in a taller tight parent」：80 高紧约束下单值 / 区间滑条圆钮中心与滑条中心对齐（旧实现偏 18px，两条均红）。
- **备注**：
