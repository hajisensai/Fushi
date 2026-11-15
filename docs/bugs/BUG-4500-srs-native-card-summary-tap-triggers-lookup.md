## BUG-4500 · 复习原生卡面点「语法详情」折叠标题会同时弹出查词
- **报告**：2026-11-15（应用内反馈 QqGzcpZ_gu，Android，3.3.0-debug.26444）
- **真实性**：✅ 真 bug（代码路径确认，未上真机）。分诊指的 `reader_selection_scripts.dart` `selectText` 不是这条路径：复习卡的 WebView 卡面在 `srs_card_lookup.dart` 的 `blocked()` 里已把 `SUMMARY` 等交互元素排除在取词之外。出问题的是**原生绘制卡面**：`<details>` 的标题由 `_DetailsView`（`fushi/lib/src/pages/implementations/srs/srs_html_card_view.dart:1159`，`onTap` 在 `:1176` 切换展开）承载，标题文字经 `_column` → `_FlowView` 同样打上 `SrsLookupTextData` 取词标记；`SrsNativeLookupRegion` 用原始 `Listener` 旁观指针，`srsNativeLookupHitAt`（`fushi/lib/src/pages/implementations/srs/srs_card_lookup.dart:1132`）只找最近的取词标记、不认交互控件，`_onUp`（`:1378`）照常发起取词。结果一次点按既展开折叠又弹查词，与 WebView 卡面「交互元素不取词」的设计不一致。
- **[ ] ① 未修复** — 待处理：本轮任务约束禁止改 SRS 页面（`fushi/lib/src/pages/implementations/srs/`，另一会话在改）。建议修法：给 `_DetailsView` 标题区包一个「不取词」`MetaData` 标记，`srsNativeLookupHitAt` 在命中路径上遇到该标记即返回 null（与 WebView 卡面 `blocked()` 同口径，也可把链接 / 按钮一并纳入）。
- **[ ] ② 未加自动化测试** — 建议在 `fushi/test/srs/srs_html_card_view_test.dart` 的 Kaishi 背面用例里挂 `SrsCardLookupScope`，点「语法详情」断言展开且未发起查词。
- **备注**：
