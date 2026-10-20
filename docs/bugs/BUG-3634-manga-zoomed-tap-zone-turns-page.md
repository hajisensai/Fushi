## BUG-3634 · manga-zoomed-tap-zone-turns-page
- **报告**：2026-10-20（用户：漫画放大以后点左右还会翻页，正常阅读器放大后点左右不翻页）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/manga_overlay_html.dart` 的 `_onTap` 命中翻页热区（`_tapZoneTurn`）就直接 `onMangaTurn`，完全不看 `ZOOM`；放大后画面只露出页面一块，热区按视口划，点哪都可能落进翻页区。
- **[x] ① 已修复** — 引入「静止倍率」`ZOOM_REST`：阅读器自己放到的倍率（设置里的默认缩放 `restZoomPercent` / 宽页切半适配 / 宽页自动放大 / 分镜聚焦）；超出它（`_userZoomedIn`）时 spread 模式点热区不翻页，退回空白点语义（双击缩回 / 切悬浮栏），翻页靠贴边后继续拖。默认值由 Dart 从偏好 `zoomStart` 传入，不取会话倍率（跨窗口重建文档时 ZOOM 带的是会话倍率）。webtoon 热区是纵向滚一屏，照常生效。顺带修宽页自动放大翻离宽页不复原、一直裁后面普通页的问题（`AUTO_ZOOM` 记账，用户改过倍率则保留）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_zoomed_tap_zone_js_test.dart`（node 跑生成文档里的真实 `_onTap` / `_applyWidePolicy`，8 条）。
- **备注**：同批用户反馈「拖动不跟手」另行处理（见同分支后续提交）。
