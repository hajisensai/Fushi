## BUG-3139 · 安卓横屏视频查词设最多三列也只出一列
- **报告**：2026-10-09（应用内反馈 bx4MhJJvXO，vivo V2339FA 384×853@2.81，设置「词典最多列数」= 3）
- **真实性**：✅ 真 bug。列数算宽用的是查词弹窗自己的 Flutter 布局宽度（`dictionary_popup_webview.dart` 注入的 `__fushiPopupViewportWidth`），宽度本身没错（不是竖屏宽度）；错在门槛：`fushi/assets/popup/popup.js` 的 `effectiveDictColumns()` 对触屏（`pointer: coarse`）把每列最小宽度翻倍成 2×170 = 340 px，手机横屏的视频查词弹窗约 620 逻辑 px，`floor(620/340) = 1`，永远只有一列。
- **[x] ① 已修复** — 本 PR：触屏门槛改为 1.5×170 = 255 px（竖屏手机弹窗 ~380 px 仍单列，横屏 620 px → 2 列，平板 900 px → 3 列；桌面门槛不变）。三份 popup.js 镜像同步。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_dict_columns_coarse_test.js` + `.dart` driver：Node 真执行 popup.js 的 `effectiveDictColumns()`（修复前横屏用例红）。
- **备注**：安卓真机横屏未复测。
