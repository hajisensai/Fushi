## BUG-279 · 移动端 Jimaku 自动获取字幕对话框候选列表太矮且吞滚动

- **报告**：2026-06-15（用户：「手机的搜搜字幕，没办法滚动还是什么，高度太低了？滚动没反应。apikey配置完以后是不是可以缩小显示」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/jimaku_subtitle_dialog.dart:164`（修复前的 `build()`）。
  - 旧布局：`AlertDialog.content` 用 `SizedBox(width:380)` 包 `Column(mainAxisSize: min)`，候选列表是
    `Flexible` 包 `ListView(shrinkWrap:true)`。`AlertDialog` 不给 content 固定高度，
    `Column(min)` 在小屏（手机竖屏可视高度被键盘压低 / 横屏）下，标题 + 两个输入框 + 筛选框 +
    操作按钮 + dialog inset 吃光高度后，`Flexible` 分到的剩余空间≈0 → 列表被压成 0 高，
    既看不见又吞掉滚动手势（`shrinkWrap` 还会让 `maxScrollExtent=0`，即使有空间也滚不动）。
  - widget 测试实证：旧布局在 360×320 真实 AlertDialog 下候选列表高度 = 0.0 且伴随 RenderFlex 溢出。
- **[x] ① 已修复** — commit `<本轮>`，文件 `hibiki/lib/src/pages/implementations/jimaku_subtitle_dialog.dart`。
  - 改用 `Dialog`（而非 `AlertDialog`）：Dialog 把 child 约束到屏幕减 inset 的有界高度，于是
    `Column(min)` 拿到有界高度天花板，候选列表用 `Flexible` 正确分到剩余空间。
  - 候选列表抽出为公开 `JimakuCandidateList`，内部用普通（**去掉 `shrinkWrap`**）可滚动 `ListView`，
    在有界高度下填满并正常滚动；矮屏剩余空间小但仍可滚，高屏自然变高。
  - 操作按钮 `Row` 改 `Wrap`（窄屏 360dp 下 Cancel + 带图标的 Search 放不下时自动换行，避免
    水平 RenderFlex 溢出）。
  - 附带特性（用户「apikey 配完缩小显示」）：配好 key 且搜出结果后，API key 输入区默认折叠为一行
    「API key 已配置 + 修改」摘要，腾出列表空间；点「修改」可展开。新增 i18n key
    `video_jimaku_api_key_set`（17 语言，经 `i18n_sync.dart` + `slang`）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/jimaku_dialog_scroll_test.dart`（5 例，全绿）：
  - regression：复刻旧 `AlertDialog+Column.min+Flexible` 布局，在 360×320 锁定列表被压成 0 高（根因）；
  - fixed：真实 `JimakuSubtitleDialog`（`debugInitialCandidates` 免联网预置候选）在矮屏可见、有界、无溢出；
  - fixed：候选超出可视区时 `maxScrollExtent>0` 且拖动后真滚动；
  - fixed：可用高度更大时列表更高（Flexible 分到更多剩余空间）；
  - feature：配好 key + 有结果时 API key 折叠为摘要 + 「修改」可展开。
- **备注**：真机手感（小屏手机实际滚动 / 折叠交互）需用户在设备上复测原始失败路径（CLAUDE.md 验证纪律）。
  网络拉取逻辑与数据流未改动，只改对话框布局与 key 折叠。
