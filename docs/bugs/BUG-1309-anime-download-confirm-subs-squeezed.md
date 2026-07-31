## BUG-1309 · 下载弹窗确认阶段：Jimaku 选择器挤掉字幕列表，RenderFlex 溢出 10px 且只剩不到一条可见
- **报告**：2026-08-01（用户：develop 全量体检既有红，主行=2453 第③组）
- **真实性**：✅ 真 bug（800x600 起就复现，越窄越严重）。根因：
  `hibiki/lib/src/pages/implementations/anime_download_dialog.dart:1731` 的 `_buildConfirmStage` 把「返回行 + 手动搜索框 + Jimaku 条目选择器（`ConstrainedBox(maxHeight: 148)`）+ 语言选择器 + 开关 + 底部按钮组」全部按自然高度排掉，只给字幕列表留一个 `Expanded`（`:1785`）吃剩下的空间。`384ccc09f`（MD3 chrome 统一）把 `JimakuEntryPicker` 从紧凑 `ChoiceChip` 换成整宽 `HibikiCard`（单选圆点 + 两行标题 + 库存摘要，见 `jimaku_entry_picker.dart:59`）后，这块从几十像素涨到接近 148 上限，字幕列表的剩余高度被压到 **62px**。
  62px 里 `_buildChosenSubsList:2023` 的 `Column` 还要先放说明行：整季包时是两行（时序 + 「集号未核对」），文案在该宽度下各折两行 ≈ 36px×2 = 72px > 62px → **`RenderFlex overflowed by 10.0 pixels`**（用户看到黄黑溢出条纹），且 `Expanded(ListView)` 拿到 0 高度 → 字幕一条都不显示；单行说明时列表只剩 26px，第 2 条起不进 viewport 也就不构建。
  即：用户在「确认推送」这一步根本看不全要下哪些字幕，而这一步的全部意义就是让他确认字幕。
- **[x] ① 已修复** — 确认阶段中段（手动搜索 → 条目选择器 → 语言 → 开关 → 字幕列表）收进单一 `Expanded(SingleChildScrollView(...))`，底部按钮组仍贴底；字幕列表改 `shrinkWrap` + `NeverScrollableScrollPhysics` 交由外层滚动。两个互相抢高度的弹性块被消掉，任何窗口高度下都不再有「某一块被压成 0」的特例。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/anime_download_dialog_discovery_ux_test.dart` 新增「800x600 与 360x600 下确认阶段不溢出且字幕全部可见」用例（同时断言 `tester.takeException()` 为 null，直接钉住 RenderFlex 溢出）。
- **备注**：同组的「整季包字幕标为集号未核对」「BUG-1206 推送」「季号校验」三条既有红，症状都是 `Found 0 widgets with text "Test Anime - 0N.ja.srt"`，与本条同一根因，随修复一并转绿——它们的判据一直是对的。
