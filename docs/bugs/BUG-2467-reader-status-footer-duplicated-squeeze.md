## BUG-2467 · 挤压态底栏与状态行重复画同一串读数
- **报告**：2026-09-11（用户：截图，Windows 竖排 + 有声书，「点空白处隐藏控制栏」关闭）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart:1481`（`_wrapBottomChromeBar` 把底栏钉在 `bottom: 0`，读数经 `_playbackStatusInline` 并进底栏右端）+ `:2487`（`_buildStatusFooter` 在 `bottom: _stableBottomInset + _bottomChromeReserve` 照画一条状态行）。
  - 机制：读数并入底栏只在**悬浮**底栏形态下成立——悬浮底栏不占位、`Positioned(bottom:0)` 盖住状态行，视觉上只有一条。`tap_empty_hide_chrome=false`（挤压态）时底栏占位（`_bottomChromeReserve > 0`），状态行按设计坐到底栏之上，而底栏右端仍画 `_buildBarStatusText()`：同一串「计时 / 已读 / 百分比」上下叠两行，`_readerBottomReserve` 也把两条的高度（56 + 28）一起喂给 WebView，白扣 28px 正文高。
  - 悬浮态打开即「正常」，与用户描述一致。
- **[x] ① 已修复** — `e4dc88bc46`：`reader_status_footer.dart` 新增纯判据 `readerStatusFooterAbsorbedByBar(inlineStatus, bottomChromeReserve)`；页面 `_statusFooterAbsorbedByBar` 同时门控 `_statusFooterReserve`（预留归 0）与 `_buildStatusFooter`（不画）。悬浮态（预留 0）、窄屏读数独立成行（不并入）两种形态不变。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_status_footer_test.dart`：纯函数三态（挤压占位 + 并入 → 吸收；悬浮 / 窄屏 → 不吸收）、`absorbedByBar` 下预留为 0，以及源码守卫（预留与绘制两处都走同一判据、底栏右端仍是读数唯一落点）。
- **备注**：与 BUG-2468 同一批截图；真机像素复测见提交说明。
