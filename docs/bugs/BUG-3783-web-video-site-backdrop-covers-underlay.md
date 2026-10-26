## BUG-3783 · web-video-site-backdrop-covers-underlay
- **报告**：2026-10-26（用户：Windows「视频站点」打开 Netflix，网页加载不出来，只剩底色和三块装饰形状（截图））
- **真实性**：✅ 真 bug。窗口宿主档的 WebView2 子窗口垫在 Flutter 下面、从透明像素处透出来（`fushi/lib/src/media/video/underlay_composition.dart`）；2026-10-25 起路由层给每页垫的 `FushiPageBackdrop`（`fushi/lib/src/utils/adaptive/fushi_page_backdrop.dart:18`，不透明底色 + `LibraryShapeBackdrop` 形状）把视频站点页也垫上了，网页被整个盖住。标题栏框架早已按 `underlayCompositionActive` 让开，新加的路由层页底没有。
- **[x] ① 已修复** — `FushiPageBackdrop` 按路由登记表 `setFushiPageRouteTransparent` 整个让开（不画底色、不画形状、脚手架底色透明）；视频页拿到底层合成时登记本路由，dispose 撤销（`fushi/lib/src/pages/implementations/video_fushi/web_source.part.dart` `_openWebSource` / `_disposeWebSource`）。只让开持有底层合成的那一页，盖在上面的页照旧不透明。（分支 `claude/webpage-loading-ui-issues-bd26d2`）
- **[x] ② 已加自动化测试** — `fushi/test/web_browser/web_page_underlay_and_menu_test.dart`「持有底层合成的路由：页底不画底色也不画形状」。
- **备注**：
