## BUG-3355 · 两栏详情页模糊背景只画成窗口中间一块竖条（像莫名的毛玻璃）
- **报告**：2026-10-14（应用内反馈 kVwc9NMu2x「漫画点开顶上有莫名的毛玻璃」，Windows 宽窗漫画作品页截图：章节列表顶部、窗口正中一块模糊竖条）
- **真实性**：✅ 真 bug。`MediaDetailBackdrop`（`fushi/lib/src/media/detail/media_detail_kit.dart`）把背景图包在 `AnimatedSwitcher` 里做交叉淡入，而 `AnimatedSwitcher` 的默认 layoutBuilder 是 `Stack(alignment: center)`——子项拿到**松**约束，`Image(fit: BoxFit.cover)` 于是按图片宽高比缩成「整高、居中」的竖图，不再铺满。两栏布局下背景是整页 `Positioned.fill`，竖版封面在宽窗里就只剩中间一条，叠上可读性 scrim 后只在顶部看得见，像一块孤立的毛玻璃。与 Apple 设计系统的组件材质无关（MD3 同样出现）。
- **[x] ① 已修复** — `AnimatedSwitcher` 改用铺满版 layoutBuilder（`StackFit.expand`，`media_detail_kit.dart:110` 的 `_expandedSwitcherLayout`），新旧两层都拿紧约束，模糊封面与原样 fanart 两种背景都铺满。所有 `MediaDetailLayout` 详情页（漫画 / 视频在线源 / 小说在线源等）一并修复。
- **[x] ② 已加自动化测试** — `fushi/test/media/detail/media_detail_title_and_backdrop_test.dart`「背景图铺满整块（blurSigma=28 / 0）」。
- **备注**：
