## BUG-3095 · 弹窗缩放后词典条目横向溢出
- **报告**：2026-10-09（用户 PDF 第 2 页：查词弹窗按 A−/A+ 缩放后，多列词典卡右列被裁出弹窗）
- **真实性**：✅ 真 bug。根因两处：① `dictionary_popup_webview.dart` 的 `__fushiPopupZoomStep` → `__fushiApplyPopupViewport` 只改 `documentElement.style.zoom` 与 `#entries-container` 宽度，**不重铺 masonry**；masonry 卡片的 inline 宽是按旧宽度写死的 px，收起的卡片高度在 CSS px 下不随 zoom 变，ResizeObserver 不报，旧列宽一直留着（headless Chrome 实测缩放后 250ms 卡片总宽 528px > 容器 372px）。② `popup.js` `effectiveDictColumns` 拿视口物理宽比 CSS px 门槛，放大字号后仍按原列数排。
- **[x] ① 已修复** — `effectiveDictColumns` 用 `视口宽 / zoom`；新增 `__fushiRelayoutPopupColumns`（重算有效列数 + 全量重铺），`__fushiApplyPopupViewport` 收尾调用。提交见 PR `pr/dict-popup-style`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_dict_style_1009_guard_test.dart`「zoom step relayouts dictionary columns against the layout width」。
- **备注**：Android 真机未复测（本机未连设备）；headless Chrome 前后截图见 PR。
