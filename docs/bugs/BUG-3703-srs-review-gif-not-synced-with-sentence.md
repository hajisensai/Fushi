## BUG-3703 · 复习卡动图不与例句音频联动
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：复习卡上的动图（GIF/动画图）与例句音频不联动，音频播放时动图不重播/不同步。
- **真实性**：✅ 真 bug。根因：卡面图片组件 `_MediaImage`（`fushi/lib/src/pages/implementations/srs/srs_fushi_card_view.dart`）与播放序列无连接；新增陪播接口 `srs_card_video_channel.dart`。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_feedback_test.dart`
- **备注**：无。
