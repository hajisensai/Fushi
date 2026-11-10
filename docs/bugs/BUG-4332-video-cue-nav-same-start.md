## BUG-4332 · 视频 ASS 同起止多条 Dialogue：上/下一句要按两次
- **报告**：2026-11-08（用户：应用内反馈 rLCxUJ-2i4，Android 本地视频 + ASS 字幕）
- **真实性**：✅ 真 bug。ASS 常把一句台词拆成两条起止相同、`\pos` 不同的 Dialogue（反馈原文两条均为 `0:07:26.00-0:07:28.30`）。`native/fushi_compute/src/parse/subtitle/formats.rs` 的 `parse_ass` 每条 Dialogue 各成一条 cue、只按 start 排序，于是得到两条起点严格相等的 cue。`fushi/lib/src/media/video/video_player_controller.dart` 的 `nextCueIndexFor` / `prevCueIndexFor` 锚定分支按下标 `anchor ± 1` 取目标，按位置的 `prevCueIndexFor` 句中分支取 `hit - 1`（`JsonAlignmentParser.findCueIndex` 在同起点组内回组尾），都不跳过同起点的 cue：第一次跳转落到同组另一行（同一时刻，看着像回到本句开头），要按第二次才真正跳走。
- **[x] ① 已修复** — `nextCueIndexFor` / `prevCueIndexFor` 改为按「同一起点的一组 cue = 一句」前进 / 后退：下一句 = 起点严格大于当前锚点起点的第一条（下一组组首），上一句 = 起点严格小于当前句起点的最后一组的组首；锚定、按位置句中、gap 三条分支一并改，严格相等分组、无容差。新增 `_nextCueGroupStartIndex` / `_prevCueGroupStartIndex`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_player_controller_test.dart` 组 `BUG-4332 同起点多条 cue 视为同一句`（反馈原文两条 cue、句中 / 句首 / gap / 锚定 / 首末边界 / 起点差 1ms 不合并 / snapSubtitleDelayMs）。
- **备注**：复制 / 制卡只取单条 cue 文本（只拿到一行）属展示决策（同起点的行可能是不同说话人或标牌），本条不改，在 PR 中列为待决策。测试未在本分支运行，统一在合并后验证；未做真机复测。
