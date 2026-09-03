## BUG-1758 · 漫画阅读器调整窗口大小后显示错误跨页直到翻页
- **报告**：2026-08-21（用户：Discord moonbeam）
- **真实性**：✅ 真 bug。布局全走视口单位（100vw/100vh），resize 后浏览器立即重排；
  但 spread 的 `translateX(-offsetLeft px)`（`fushi/lib/src/media/manga/manga_overlay_html.dart`
  旧 `__mangaApplyTranslate`）、缩放居中 `PAN_X/PAN_Y` 和 webtoon 的 `scrollY` 都是
  加载/手势那一刻由**旧视口**换算出的 px 投影：注入 JS 没有任何 resize 监听，Dart 侧
  `_applySpreadLayoutIfChanged`（`manga_fushi_page.dart`）只在单/双页布局真翻转时才重建，
  普通拖窗口边框全部 no-op。窗口宽 1200 看 spread 5 = translateX(-6000px)，拖到 800 宽后
  offsetLeft(5)=4000 而 transform 钉在 -6000 → 视口露出的是 spread 7.5 附近（「随机页」）；
  下次翻页 `__mangaApplyTranslate` 现场重测 offsetLeft 才恢复——与用户描述一字不差。
- **[x] ① 已修复** — 真值是语义状态（`CURRENT` 跨页 + `RESTORE_FRACTION` 页内偏移 +
  `ZOOM/PAN`），px 只是投影：把「纯投影」抽成 `_translateToSpread`（翻页动画与摆位共用，
  fade 的先淡出再位移只属于翻页），首次定位与 resize 统一走 `_reanchor` 无过渡重投影
  （spread 重放 translate、webtoon 重放 `__mangaScrollToSpread`、PAN 按新视口回中/钳制）；
  resize 监听 rAF 合并，`_resizePending` 挡住窗口期迟到的 webtoon 滚动上报（否则会把
  视觉错页记成真值、重投影反而钉死漂移）；语义真值由投影函数与滚动上报维护。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_reanchor_raster_guard_test.dart`
  「BUG-1758 resize 重投影」组：resize 监听 + rAF 合并、`_resizePending` 门、语义真值
  维护三条；`manga_pan_ownership_test.dart` 的摆位无过渡不变式改钉 `_reanchor`/
  `_translateToSpread`。
- **备注**：与 BUG-1153/1170（翻页竞态的旧文档回调错页）不同源：那是 generation 闸门
  问题，本条是 px 投影无人重算。
