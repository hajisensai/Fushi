## BUG-5511 · hero-backdrop-band-collapses-on-rotate
- **报告**：2026-11-19（来源：应用内反馈 hmsIkQ9zIv，开发者自提）
- **真实性**：✅ 真 bug。详情页背景带高度按背景图比例算（`fushi/lib/src/media/detail/media_poster_detail.dart` `_artBandHeight`，比例未知时退回 `topInset + fallback`），比例来自 `_HeroImageAspect`（`CoverAspectProbe`）。合集详情页每 10 秒轮播换背景图，`fushi/lib/src/media/video/cover_ui/cover_aspect_probe.dart` `didUpdateWidget` 一换图就把 `_aspect` 置 null，背景带先塌回兜底高度、下方内容被抬上来，等新图首帧解码完才撑回去。
- **[x] ① 已修复** — `CoverAspectProbe` 新增 `holdsAspectAcrossImageChange`（默认 false，网格卡行为不变）：开了的槽位换图时，新图的比例在 `CoverProbeMemo` 里就直接用新的，否则沿用上一张的比例直到新图解码；加载失败照旧清空。`_HeroImageAspectState` 打开它。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/cover_aspect_probe_hold_test.dart`（开 hold：换图到解码前每一帧都是旧比例、解码后换新比例；默认：换图即 null）。
- **备注**：
