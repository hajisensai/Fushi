## BUG-4739 · 漫画双页模式两页之间有一条细缝
- **报告**：2026-11-16（用户：应用内反馈 kvIT2zOsg0，附截图）
- **真实性**：✅ 真 bug。截图里跨页交界整幅高度有一条约 1px 的竖向细线（压在白处偏暗、压在深色处偏亮），不是扫描白边。根因 `fushi/lib/src/media/manga/manga_overlay_html.dart` 的 `_layoutSource`：双页时页宽 = 原图宽 × fit，是小数 CSS px；两页在 `.manga-spread`（`justify-content:center`）里居中贴在一起，交界落在物理像素中间，两张图的边缘各被抗锯齿掉半个像素，底色从缝里透出来。长条漫的同类横缝已由 967c7e47df 按「页高对齐物理像素 + 后一页压前一页 1 个物理像素」修过，但那段只对 `IS_WEBTOON` 生效，双页横向没有对应处理。
- **[x] ① 已修复** — aab37a0c95：`_layoutSource` 双页（slots==2）时页宽按 devicePixelRatio 取整，跨页里 DOM 靠后的页加 `margin-inline-start:-1/dpr px`（随 `.manga-spread` 的 direction 朝向对面页）；有折叠屏铰链缝（`SPREAD_GUTTER`）时不重叠。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_reader_transforms_js_test.dart`「two-page spread pages snap to device pixels and overlap one device pixel」：用 node 跑生成的 `_layoutSource`（2221 宽 / dpr 1.25 的反馈窗口），断言页宽落在整物理像素、图像横向缩放跟随页宽、靠后页压 1 物理像素、单页与铰链缝不压。修复前红（813.2242466713385px 不在整物理像素上）。同文件另 3 条旧测试因 656615ac8b 给 `_layoutSource` 加了 `_refitPage` 调用而 ReferenceError；并入 develop 时改用 develop 已有的 `fitSection` 抽真实取图段，不再补桩。
- **备注**：未在真机 / Windows 窗口里肉眼复测原截图场景；缩放倍率 ZOOM<1 时 1/dpr 的重叠会随画布缩小到不足 1 物理像素（长条漫的同类修复也如此）。
