## BUG-4906 · masthead-title-ellipsis-phone
- **报告**：2026-11-19（用户：手机上新外观的设置页页名太大放不下，阅读设置页只显示「Read…」）
- **真实性**：✅ 真 bug。二级页页头大字 `FushiMastheadHeader` 的页名盒（`fushi/lib/src/utils/components/fushi_masthead_scaffold.dart:153`）在窄窗恒按 46 排、放不下直接省略号截断；返回键 + 徽标 + 动作占掉后，「Reading」只剩「Read…」。同族的一级切换早已 `FittedBox(scaleDown)` 缩到放得下，页名没有。
- **[x] ① 已修复** — 页名盒按 `fushiMastheadTitleFit`（`fushi_page_masthead.dart`）依次取：满字号一行 → 一行缩到放得下（下限收起态字号：窄窗 28 / 宽窗 36）→ 两行、词不拆开、二分取最大字号（窄窗 22～34 / 宽窗 28～56，「Reading controls」与长译名）→ 仍放不下才两行末省略。静止态定下的字号与折行宽不随滚动变，收缩只在绘制层缩放，两行不重排；放得下的页名与滚动收缩不变。所有走 `FushiMastheadHeader` 的二级页（设置各分类、音乐 / 媒体服务器二级页等）一并受益。
- **[x] ② 已加自动化测试** — `fushi/test/utils/components/fushi_masthead_scaffold_test.dart`「手机窄窗：长页名先缩小到放得下，不省略成「Read…」」：380 宽 + 动作，断言页名一行未截断且按比例缩小（去掉修复即红）；另一条「缩到收起态字号仍放不下的页名折成两行，不省略」断言「Reading controls」两行完整排下。
- **备注**：主 tab 页头（`fushi_floating_chrome.dart` 里的 `FushiMastheadTitle`）仍是放不下即省略，现有页名都短，未改。
