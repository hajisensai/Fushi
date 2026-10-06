## BUG-2908 · 漫画缩小后无法回到正常比例
- **报告**：2026-10-03（用户：所有者真机反馈「缩小以后我怎么恢复正常比例；无级放大缩小，我不是机器人做不到正好」）
- **真实性**：✅ 真 bug。翻页模式默认允许捏合缩到 50%（`kMangaZoomMinPercent`），但回到 100% 只有两条路且都不好用：
  ① 双击判据 `var target=ZOOM>1.01 ? 1 : 2;`（`fushi/lib/src/media/manga/manga_overlay_html.dart` `_doubleTapZoom`）把**缩小态**（ZOOM<1）当作「贴合」直接放大到 2×，要再双击一次才回得到 100%；
  ② 捏合是无级的（`pointermove` → `_zoomAbout(pinch.zoom * ratio^ZOOM_SENS)`），松手没有任何吸附，人手凑不出正好 100%，残留 95%/104% 这类值。
- **[x] ① 已修复** — `_doubleTapZoom` 改为「不在 100% 就一击回 100%、正好 100% 才放大 2×」，抽出 `_animateZoomTo` 收尾把 ZOOM 钉到目标值本身（`_zoomAbout` 对 <0.0005 差值 no-op，不钉会停在 99.97%）；捏合结束时（触点不足两指，通常是两指中先抬起的那一指；剩下那一指由 `pinchGuard` 挡住、不会被判成翻页）`_snapPinchZoom`：落在 100% ±10%（`ZOOM_SNAP`）内以最后的捏合中心为锚动画吸附回正好 100% 并回中——**前提是这次捏合确实改变了缩放**（与捏合开始时的倍率 `pinch.zoom` 相差超过 2%，`PINCH_NOOP`），否则两指只是搭一下屏幕就会把设置里定好的 105% 之类拉回 100%。明显的缩放（如 60%、120%）不吸附，`disableZoomOut` / 缩放范围设置照旧。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_zoom_reset_js_test.dart`（node 真跑生成文档里的 `_zoomAbout` / `_animateZoomTo` / `_doubleTapZoom` / `_snapPinchZoom`，动画与无动画两档：缩小态双击回 100% 并回中、放大态回 100% 后再双击到 2×、±10% 内吸附、明显缩放不吸附、起点 105% 的两指触碰几乎没缩放时保持 105%、捏合结束时把起点倍率传给吸附）；`manga_overlay_background_tap_zone_test.dart` 的双击判据断言随之更新。
- **备注**：没改缩小能力本身（是否默认禁止缩到贴合以下属产品决定，已有「禁止缩小」设置项）。
