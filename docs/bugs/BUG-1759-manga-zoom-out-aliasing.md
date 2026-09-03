## BUG-1759 · 漫画缩放低于100%锯齿严重需放大到150%才恢复清晰
- **报告**：2026-08-21（用户：Discord moonbeam）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/manga_overlay_html.dart` 旧样式表把
  `will-change:transform` **常驻**在 `#manga-canvas` 与 `#manga-root` 上；Chromium 对带
  该提示的合成层采取「栅格化尺度只升不降」策略（为了 transform 动画不触发重栅格）。
  于是缩到 90% 时不重栅格，GPU 拿 scale=1 的旧纹理做**无 mipmap 双线性缩小**——漫画
  网点/线稿是最坏输入，直接锯齿/摩尔纹；放大到 ≥150% 才跨过旧尺度触发重栅格恢复清晰，
  且此后 raster scale 被抬高、再缩回更糊——与用户「90% 糊、150% 才恢复」完全吻合。
  页面布局尺寸全由视口单位决定（缩放不改位图重采样尺寸，纯 transform: scale）。
- **[x] ① 已修复** — 撤掉两处常驻 `will-change:transform`，改为 JS `_hintWillChange`
  在手势/动画期间临时挂（`_applyCanvas` 每次提交挂 200ms、`__mangaApplyTranslate`
  按翻页动画时长挂）、静止后摘除 → 层降级并按当前 ZOOM 重栅格，任何倍率下静止画面
  都是按目标尺寸重采样的；手势期间合成器快路径不变，流畅度不受影响。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_reanchor_raster_guard_test.dart`
  「BUG-1759 栅格化尺度」组：样式表不得出现 `will-change:transform;}` 规则形态 +
  `_hintWillChange` 临时挂/摘除接线。
- **备注**：更彻底的「布局缩放」（槽尺寸乘 zoom 变量、图像管线原生重采样）评估过，
  代价是缩放触发 relayout + 锚点数学重写，当前方案已消除用户可感的质量问题，不值得。
