## BUG-5348 · 漫画播放条倍速 / 音量弹层撑满屏高
- **报告**：2026-11-23（用户：群反馈截图「难绷这是什么」——Windows 漫画有声播放条点 1.00x 后，倍速面板变成从按钮上方一直到屏顶的大黑柱，滑杆悬在中间）
- **真实性**：✅ 真 bug。`_PopoverButton` 的浮层（`fushi/lib/src/media/manga/reader/manga_read_aloud_bar.dart` `overlayChildBuilder`）经 `Align` 放松后高度上限是整屏，`SizedBox(width: 320)` 只钉宽；Material `Slider` 的 render object `sizedByParent`，高度有界就取 `maxHeight`（`flutter/lib/src/material/slider.dart:1735` `computeDryLayout`），于是面板高度 = 按钮上方整段屏高。音量弹层共用同一组件，同病。
- **[x] ① 已修复** — 弹层面板外包 `IntrinsicHeight`，高度回到内容固有高度（Slider 的固有高度是轨道 / 拇指的首选高度）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/reader/manga_read_aloud_bar_test.dart`「成品音频播放条…」用例：倍速、音量弹层打开后滑杆高度 ≤ `kMangaChromeToolbarHeight`（MD3 / Apple 两套）。
- **备注**：
