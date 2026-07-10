## BUG-702 · 最小窗高(TODO-1377 480px)下弹窗底部 RenderFlex 溢出
- **报告**：2026-07-10（用户日志多条：`overflowed by 58/62/108/384/1024px`）· TODO-1389（TODO-1377 副作用，独立修，不改回 1377 的最小尺寸下限）
- **真实性**：✅ 真 bug。沿 origin/develop `9c45e23cb` 真实渲染路径核实。
  - **根因**：TODO-1377（`hibiki/lib/src/startup/desktop_window_placement.dart:28`，`2026-07-10 08:16` 落地）把桌面主窗最小**高度**从 640 砍到 480（客户区逻辑高≈440px），只离屏验了书架/视频/查词/设置/词典管理 5 个主表面，**未覆盖弹窗/sheet**。溢出日志集中在其后 `10:20-11:56`。release 无 widget 堆栈，沿 `HibikiDialogFrame`(`hibiki/lib/src/utils/components/hibiki_material_components.dart:1071`) + `HibikiModalSheetFrame`(`:931`) 的调用点静态审计 + widget 复现定位。
  - **溢出机制**：框被 `maxHeight = screenHeight * maxHeightFactor` 卡住（最小窗高下界很小），而 `body`/`child` 是**非滚动**固定内容（普通 Column，没有自带滚动视口）→ 内容超过可用高度就 RenderFlex 底部溢出。绝大多数调用点用的是安全范式（`HibikiDialogFrame(scrollable:false) > HibikiModalSheetFrame(scrollable:true)`，或 body 自带 ListView），只有下面 3 个漏了滚动兜底：
    1. **`hibiki/lib/src/pages/implementations/media_sources_dialog.dart:133`**（「管理来源库」）：body 是 `ConstrainedBox(maxHeight=clamp(0.55h,160,480)≈242px) > HibikiReorderableColumn`（内部 Stack+Column.min，**不带滚动**），**独漏** `SingleChildScrollView`——兄弟对话框 `local_audio_sources_dialog.dart:97-103` 早在 BUG-445 就补了这层，此处照抄骨架时漏了。≥4 条来源即溢出（对应大额 384/1024px）。
    2. **`hibiki/lib/src/media/audiobook/sasayaki_rematch.dart:135`**（sasayaki 重匹配，桌面路径）：外层 `HibikiDialogFrame(maxHeightFactor:0.62, scrollable:false)`，内层 `HibikiModalSheetFrame` 默认 `scrollable:false` + 双滑条非滚动 Column（~270-300px）→ 0.62 界底下容不下（对应 108px）。
    3. **`hibiki/lib/src/pages/implementations/series_detail_page.dart:335`**（系列重命名 `_SeriesRenameDialog`）：外层 `maxHeightFactor:0.74, scrollable:false`，内层默认 `scrollable:false` + `Center(92x120 封面大图)+输入框` 非滚动 Column→矮窗顶破（对应 58/62px，大字号/紧凑更甚）。
- **[x] ① 已修复** — `git commit 6e34627ba`（分支 `todo1389-minwindow-overflow`）。三处补滚动兜底，**不改回 TODO-1377 的最小尺寸下限**：
  1. `media_sources_dialog.dart`：body 外层套 `SingleChildScrollView(child: _buildBody(tokens))`——内容超高整体滚动而非溢出，行少仍按内容收缩，与兄弟 `local_audio_sources_dialog` 一致（拖拽重排与滚动的手势竞技场分离由 `HibikiReorderableColumn` 处理，兄弟已验）。
  2. `sasayaki_rematch.dart`：内层 `HibikiModalSheetFrame(scrollable: true)`——body 在 `Flexible` 内滚动，矮窗可滚不溢出（桌面 + 移动路径共用同一 body，一处修覆盖两端）。
  3. `series_detail_page.dart`：内层 `HibikiModalSheetFrame(scrollable: true)`——封面+输入框在滚动视口内，矮窗可滚不溢出。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/min_window_dialog_overflow_test.dart`（5 例，全绿）：
  - sasayaki(0.62 界)/series(0.74 界) 各一对——用真实 `HibikiDialogFrame` + `HibikiModalSheetFrame`：`scrollable:false` 在矮窗（360x400 / 360x320）下 `takeException()` 命中 `overflow`（锁根因），`scrollable:true` 无溢出且 body 落在滚动视口（证修法）。
  - `MediaSourcesDialog`（真实组件 + 内存库播种 24 条来源，360x440≈最小窗客户区）：无 RenderFlex 溢出、`HibikiReorderableColumn` 被外层 `Scrollable` 包住、`maxScrollExtent>0`（修前会溢出且无此滚动层）。
  - 端到端补充：`hibiki/integration_test/min_window_size_surfaces_itest.dart` 追加 `media-sources` 表面——在真 app 里播种 24 条来源、最小窗高下打开对话框、扫掠断言无溢出（经 `tool/run_windows_itest.ps1` 离屏跑）。
  - 全量 `flutter analyze`（含 test）No issues；全量 `flutter test` 全绿。
- **备注**：
  - **未改回下限**：TODO-1377 的 `Size(360, 480)` 最小尺寸是用户明确诉求，未动；本 bug 只补弹窗的滚动兜底。
  - **审计覆盖 / 剩余候选**：沿全部 `HibikiModalSheetFrame`/`HibikiDialogFrame`（47 文件 60+ 处 `scrollable:false`）核查——设置子页（`switch_settings`/`master_detail_settings_sheet` 等）、同步/备份对话框、更新提示、词典设置等**均为安全范式**（内层 `scrollable:true` 或 body 自带 ListView），不溢出。仅上述 3 处漏兜底。
  - **验证门（诚实标注）**：widget 层已用真实组件确定性复现 media_sources 溢出+修复；sasayaki/series 用真实框 + 忠实 body 复现机制（其对话框由私有/静态入口触发，不便在 widget 测试直接 pump）。真机对这 3 个对话框在 480px 窗下的端到端复测（media-sources 已进离屏 itest；sasayaki 需有声书、series 需系列文件夹态）为残留验证门。
