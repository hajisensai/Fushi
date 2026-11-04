## BUG-4005 · SRS 评分后没有任何结果提示
- **报告**：2026-11-02（应用内反馈 `Feedback: fiTLYrWbDW`，类型 suggestion：评分后没有反馈，看不出按到了哪个等级）
- **真实性**：✅ 真（交互缺口）。`fushi/lib/src/pages/implementations/srs/srs_review_page.dart:955` `_rate`（修复前）落库后直接 `_loadNext()`（同文件 :985），卡面换成下一张，没有任何评分结果提示。
- **[x] ① 已修复** — 卡面底部居中的「已评」胶囊 `SrsRatedFeedbackChip`（同文件）：评分成功后显示等级名（开了「显示间隔」时附上评分前算好的间隔，`_ratingInterval`），配色取 `srsRatingColors(apple:)` 与评分键一致（MD3 / Apple 两套），`AnimatedSwitcher` 淡入 + 0.9→1 缩放，时长只用 `FushiMotion.short/micro`；`IgnorePointer` 不挡手势，`Semantics(liveRegion)` 读屏播报；翻面 / 撤销时收起。i18n `srs_review_rated` / `srs_review_rated_interval`（i18n_sync 增加）。提交 `d693ba1bd2c55272363526ef3d3da48bb5f43ff7`。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_rated_feedback_test.dart`（真复习页 widget：apple false/true 各一遍，评 Good 出现对应配色胶囊、翻面收起、再评 Again 换成 Again、撤销收起）。
- **备注**：真实设备肉眼看动效未做（本轮无设备），待补。
