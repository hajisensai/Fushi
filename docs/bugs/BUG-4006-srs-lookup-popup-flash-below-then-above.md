## BUG-4006 · 复习卡查词弹窗先在下方出现再跳到上方
- **报告**：2026-11-04（开发者反馈 #hbre3AQKXS 后半句「查词的时候弹窗会闪一下，先在下面生成才到上面」，Android OnePlus CPH2747 363x792@3.5，3.3.0-debug.23261；正文空，截图未随导出，日志只有 `SrsReviewPage.focus`）。同一反馈的「没高亮」见 BUG-4004。
- **真实性**：❌ 未复现。沿代码路径核对了「搜索占位卡 → 真弹窗」这一跳：
  - 复习页查词走 `SrsCardLookupHost._present` → `pushNestedPopup`（`fushi/lib/src/pages/implementations/srs/srs_card_lookup.dart:441`），占位卡 `buildPopupLoadingPlaceholder` 用 `_calcMixinPopupPosition(rect, screen)` 按**最大高度**摆（`dictionary_page_mixin.dart:1421`），真弹窗按自适应高度 `fitHeight ≤ 最大高度` 摆（`:1108`），二者锚点同为 `controller.beginSearchUi(rect, …)` / `entry.selectionRect` 的同一个 `rect`。
  - `calcPopupPosition` 的上下判据（`dictionary_popup_layer.dart:101-105`）：同一锚点下，若高度 H 选了「下」，则任何 h ≤ H 也选「下」（H ≤ roomBelow 时 h ≤ roomBelow；H 两边都放不下而 roomBelow ≥ roomAbove 时，h 若放不进下方则 h > roomBelow ≥ roomAbove，也放不进上方，仍按 roomBelow ≥ roomAbove 选下），**不存在「占位在下、真弹窗在上」的翻转**；反方向（占位在上、真弹窗在下）才可能，与报告方向相反。
  - 复习页的锚点在请求时一次算好（原生区 `srsNativeLookupHitAt` / WebView 卡面 `_onTextSelected` 都经整矩阵变换），之后不重锚。
  因此报告描述的方向在当前几何里推不出来；没有录屏 / 截图也无法确认是不是热槽 WebView 在旧位置先露一帧（那是平台视图层面，单测环境无法观察）。不硬改。
- **[ ] ①** —
- **[ ] ②** —
- **备注**：需要录屏（含开发者选项「指针位置」）复现后再定位；若确认是热槽旧位置露帧，应查 `parkedPopupLayer` 停靠 / 翻可见时序，而不是改上下判据。
