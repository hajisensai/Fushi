## BUG-5351 · 漫画双击放大 / 缩回落定后黑屏闪一帧，缩回最后一帧位置跳动
- **报告**：2026-11-23（应用内反馈 5VHASFiDKy，Android 31707，OnePlus PLK110，附录屏）
- **真实性**：✅ 真 bug（逐帧量录屏：2.36s / 7.15s 两处整页黑一帧，分别在放大落定约 0.6s、缩回落定约 0.2s 后；第二次缩回动画停在页顶 385px，落定那一帧跳到 369px）。两个根因都在 `fushi/lib/src/media/manga/manga_overlay_html.dart`：
  1. 黑闪：缩放档变了（`_zoomTier` 1↔2）200ms 后 `_scheduleRefit` → `_refitPage` 直接改在屏 `<img decoding="async">` 的 `src`；新图到货那一帧 async 图未解码不阻塞光栅，整页露出黑底色。缩回时 1 档图走缓存，200ms 正好是合并定时器；放大要现取 2 档，所以晚到 0.6s。
  2. 偏移：`_animateZoomTo` 每帧以**第二击**为锚 `_zoomAbout`，落定后才回中（`ZOOM<=1` → `_recenterPan`）/ 快速缩回才在 `after` 里摆正——两次双击不在同一处或放大后拖动过时，动画停在偏位、最后一帧跳回中间。另有末帧与目标差 <0.0005 时 `_zoomAbout` 直接返回、settle 只钉 ZOOM 不改 PAN，放大落点差零点几像素。分诊说的「webtoon 纵向不回中」是有意设计（纵向归 scrollY、以手指为锚），不是偏移来源。
- **[x] ① 已修复** — 换图：新增 `_swapPageSrc`，在屏已有画面的页先离屏 `new Image()` + `decode()`，解码好再换 src 并把该图改为同步解码；挂起期间只认最后一档（`__pendingSrc`），预取失败照换交给 error 监听。超分换图 `__mangaSrReady` 同走它。缩放：`_animateZoomTo` 先算终态（`_zoomEndPan`：<=1 回中、>1 钳进合法区间；快速缩回用 `_quickFitPan`），每帧沿「起点→终态」的同一不动点缩放（`_zoomFixedPoint`），落定帧就是终态，不再落定后补摆；气泡聚焦退出也去掉了落定后补回中。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_zoom_reset_js_test.dart`（双击点不同处缩回 / 拖动后缩回 / 条漫缩回：每帧在同一缩放路径上、终态回中、条漫纵向锚点不动）；`fushi/test/media/manga/manga_page_fit_test.dart`「BUG-5351: a shown page swaps tiers only after the new image decoded」。旧代码上 4 条全红、新代码绿。
- **备注**：黑闪的「新图到货那一帧露底」是 Chromium async 解码行为，单测只能锁住「解码好才换 src、换上去同步解码」这条契约；真机复测未做（无对应设备在手），需 Android 真机双击放大 / 缩回各一次确认不再闪。
