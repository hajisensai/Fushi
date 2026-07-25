## BUG-1075 · 每日目标弹窗无单位无口径说明

- **报告**：2026-07-25（用户：「每日目标没有加权，也没有单位，我怎么知道要写什么？」）
- **真实性**：✅ 真 bug（信息缺失类）

### 根因

`hibiki/lib/src/pages/implementations/home_dashboard_page.dart:137`（`_DailyGoalDialog.build`）
只有一个裸 `TextField`，`decoration: InputDecoration(labelText: t.stat_goal_daily)`
——没有单位、没有口径说明、没有任何参考值。目标值实际是**每日字符数**，口径为
**全来源合计**（阅读字数 + 视频字幕字数 + galgame hook 字数，见
`_readingCharsByDay` 的三路合并 `home_dashboard_page.dart:346-365` 与
`_buildDailyGoalRow`），且与阅读统计页共用同一持久化
`AppModel.readingGoalDailyChars`。阅读统计页的同款编辑
（`reading_statistics_page.dart:_editGoals`）也是两个裸输入框，同病。

### 关于「加权」的决策

**不引入加权系统**。用户真正的困惑是「不知道这个数字代表什么、该填多少」，不是
「看视频的字应该只算 0.5 个」。加权会引入一套新的口径参数、影响已落库的历史统计与
热力图分档、并让首页与统计页两处目标口径可能漂开——典型的过度设计。解药是把口径
说清楚 + 给参考值 + 给预设值。

### 修复

- **[x] ① 已修复** — 提交哈希：（待补）
  - 输入框加单位后缀 `suffixText: t.stat_goal_unit_chars`（字 / chars）与口径
    `helperText: t.stat_goal_scope_hint`（阅读 + 视频字幕 + 游戏文本的全部字符数合计）。
  - 弹窗内显示「近 7 日日均 X 字」（`_recentDailyAverageChars()`，与目标同口径取自
    页面已加载的 `_readingCharsByDay`，无数据日按 0 计入分母；<=0 不显示）。
  - 4 个快捷预设 chip（3000 / 5000 / 10000 / 20000），点一下填入输入框且光标置尾。
  - 首页「未设目标」行也就地显示口径说明（不再是孤零零一个按钮，见 BUG-1073）。
  - `reading_statistics_page.dart` 的 `_editGoals` 复用同一批 key 补单位 + 口径
    （每日框带 helperText，每周框带单位后缀），content 包 `SingleChildScrollView`
    防 helperText 变高后在小窗溢出；该页其余不动。

- **[x] ② 已加自动化测试** — 测试文件：
  `hibiki/test/pages/home_dashboard_page_test.dart`（新增
  「BUG-1075 目标对话框：单位 + 口径说明 + 近 7 日日均 + 预设 chip 填入」）：断言
  对话框内出现单位文案、口径 helperText、`近 7 日日均 114 字`（今天 800 字 ÷ 7），
  点 `5000` 预设 chip 后输入框内容变成 `5000`，保存后目标行显示 `800 / 5000 字`。

- **备注**：新增 4 个 i18n key（`hibiki/tool/i18n_sync.dart --add` 同步 17 语言，
  再 `dart run slang`）：`stat_goal_unit_chars` / `stat_goal_scope_hint` /
  `stat_goal_recent_average` / `stat_goal_presets`。
