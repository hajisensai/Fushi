## BUG-4059 · 浏览预览与复习实际卡面不一致
- **报告**：2026-11-04（用户：应用内反馈 satv-DI70B「预览和实际显示不一样」，截图是浏览页的卡片预览「1 / 1 • Default • Card 1 / 显示问题」）
- **真实性**：✅ 真 bug。复习页对内置 Fushi 卡片（`SrsRenderedCard.fushiCardDefinitions != null`）用原生卡面 `SrsFushiCardView` + 释义 WebView（`fushi/lib/src/pages/implementations/srs/srs_review_page.dart:2342`），浏览预览 `SrsBrowsePreview.build`（修前 `fushi/lib/src/pages/implementations/srs/srs_browse_preview.dart:159`）却一律走 `srsCardFaceBuilderProvider` 整面 WebView 渲染模板，两条渲染路径不同，版式 / 高亮 / 字体都对不上。
- **[x] ① 已修复** — 预览与复习同一判据：有 `fushiCardDefinitions` 时用 `SrsFushiCardView(face, fields, definitionsHtml)`，否则才用整面 WebView。提交 `9cb33a6c37`。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_browse_preview_native_test.dart`（真实 store：Fushi 卡片正 / 背面都是原生卡面且释义 HTML 一致；Lapis 仍走 WebView）。
- **备注**：未做真机 / 桌面肉眼复测。
