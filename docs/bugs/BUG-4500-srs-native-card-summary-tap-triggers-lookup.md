## BUG-4500 · 复习原生卡面点「语法详情」折叠标题会同时弹出查词
- **报告**：2026-11-15（应用内反馈 QqGzcpZ_gu，Android，3.3.0-debug.26444）
- **真实性**：✅ 真 bug（代码路径确认，未上真机）。分诊指的 `reader_selection_scripts.dart` `selectText` 不是这条路径：复习卡的 WebView 卡面在 `srs_card_lookup.dart` 的 `blocked()` 里已把 `SUMMARY` 等交互元素排除在取词之外。出问题的是**原生绘制卡面**：`<details>` 的标题由 `_DetailsView`（`fushi/lib/src/pages/implementations/srs/srs_html_card_view.dart:1159`，`onTap` 在 `:1176` 切换展开）承载，标题文字经 `_column` → `_FlowView` 同样打上 `SrsLookupTextData` 取词标记；`SrsNativeLookupRegion` 用原始 `Listener` 旁观指针，`srsNativeLookupHitAt`（`fushi/lib/src/pages/implementations/srs/srs_card_lookup.dart:1132`）只找最近的取词标记、不认交互控件，`_onUp`（`:1378`）照常发起取词。结果一次点按既展开折叠又弹查词，与 WebView 卡面「交互元素不取词」的设计不一致。
- **[x] ① 已修复** — `srs_card_lookup.dart` 新增 `srsNoLookup` 标记圈出「点按归控件、不取词」的交互子树，`srsNativeLookupHitAt` 在整条命中路径上遇到它即返回 null（标记可能在取词标记外层，所以不再找到取词标记就停）；`srs_html_card_view.dart` `_DetailsView` 的折叠标题包进去。口径与 WebView 卡面 `blocked()` 排除 SUMMARY 一致。链接 / 图片按钮未一并纳入（链接是文字段里的识别器，取词与跳转的取舍另议）。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_html_card_view_test.dart`「BUG-4500：<details> 折叠标题是控件…」：Kaishi 背面原生卡面上对「语法详情」中心做取词命中判定（取词区抬起时的同一判据）断言不取词，正文的「違」仍可取词；原有用例仍断言点标题能展开。
- **备注**：
