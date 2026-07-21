## BUG-966 · 字幕列表点词查词制卡音频截错句(锚到播放位置而非被点cue)
- **报告**：2026-07-21（用户：本地 hibiki 视频，从字幕跳转列表点词查词后制卡，卡片音频是别的句子的声音）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/video_hibiki/lookup_favorite.part.dart:62-67`。
  - 字幕列表查词回调 `_handleSubtitleListLookup(cue, ...)`（`subtitle.part.dart:97`）手里有被点的那条字幕 `cue`，但调 `_lookupAt` 时只传 `sentence/graphemeIndex/charRect`（`subtitle.part.dart:105`），丢掉了 `cue`。
  - `_lookupAt` 内部只能回落到 `controller.currentCue ?? resolveMiningCueForPosition(播放位置)` 设 `_lastLookupCue`。点列表里的词只 `pause()` 不 seek，播放头仍停在原处。
  - 制卡区间解析 `_resolveVideoMiningRange` 回退分支（`lookup_mining.part.dart:147`）用 `_lastLookupCue` 界定音频截取时间窗 → 卡片**句子文本**是被点条目、**句子音频**却截自播放位置那句 → 声音对不上。
  - 多选勾选制卡走 `_selectedMiningCueForCard` 独立分支，来源正确，不受影响。
- **[x] ① 已修复** — 抽顶层纯函数 `resolveVideoLookupAnchorCue({overrideCue, currentCue, cues, positionMs, delayMs})` = `overrideCue ?? currentCue ?? resolveMiningCueForPosition(...)`；`_lookupAt` 加可选 `AudioCue? overrideCue` 改调该函数；`_handleSubtitleListLookup` 传 `overrideCue: cue` 把被点条目透传。主画面字幕 overlay 查词（`_handleSubtitleLookupTap`）不传 → 保持原「播放位置」逻辑不变。提交：58b9afdf6（PR#306）
- **[x] ② 已加自动化测试** — 新增纯函数守卫 `hibiki/test/pages/video_lookup_anchor_cue_test.dart`（断言 override 优先、无 override 回落 currentCue、currentCue 为 null 按位置解析、空 cue 返回 null）；并同步更新既有接线守卫 `video_subtitle_list_wiring_guard_test.dart` / `video_mining_context_guard_test.dart` / `video_controls_customization_guard_test.dart` 适配 overrideCue 透传与纯函数收口。提交：58b9afdf6（PR#306）
- **备注**：与主画面 overlay 查词共用 `_lookupAt`，两条路径由 `overrideCue` 是否传入区分，无特殊情况分支。
