## BUG-392 · 视频制卡未应用字幕调轴(delay)到音频/封面裁剪时间
- **报告**：2026-06-21（用户：「没吃字幕调轴，这个制卡」 / TODO-680）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:2705-2711` 与 `:2737-2741`（修复前）。
  - 选句正确吃了 delay：`resolveMiningCueForPosition(... delayMs: controller.delayMs)` 经 `effectiveSubtitlePositionMs`（`hibiki/lib/src/media/video/video_player_controller.dart:28`，`effective = playerPos - delayMs`）把播放位置换算到字幕坐标后匹配，选中的就是用户当下看到那句。
  - 但裁剪偏移缺失：选中 cue 的 `startMs/endMs` 是**字幕文件原始坐标**，被直接当**播放器时间轴**送进 `extractAudioSegmentViaFfmpeg`（`:2896`）/`extractClipGifViaFfmpeg`（`:2865`）。文本字幕的 delay 仅在 Dart 侧扣播放位置（libmpv 音画不动，见 controller `:588`），故必须做逆变换 `playerPos = subtitleTime + delayMs`（与 seek 用的 `cueSeekTargetMs` `video_player_controller.dart:1795` 同方向）才裁到用户实际听到/看到的窗。漏了 `+ delayMs` → delay≠0 时句子音频与 GIF 封面整体偏移 `delayMs`（裁早/晚一截，串邻句）。
  - 截图兜底（`controller.screenshot()` `:2879`）截当前解码帧、不按 cue 时间，本就与时间轴无关，不在本修复内。
  - 历史/收藏定位器（`normCharOffset: cue.startMs`）刻意保留字幕坐标（与 `cue.startMs` 做高亮相等判定、经 cue 解析往返），不动；其 jump-back 的 delay 处理属 TODO-632/633 范畴。
- **[x] ① 已修复** — 新增纯函数 `miningClipTimeMs(subtitleTimeMs, delayMs) => (subtitleTimeMs + delayMs).clamp(0, 1<<30)`（`video_hibiki_page.dart`，`effectiveSubtitlePositionMs` 的逆变换），在 `_resolveVideoMiningRange` 两个分支（字幕列表多选 + 查词多句合一/单 cue 兜底）finalize `clipStartMs/clipEndMs` 时套用 `controller.delayMs`。提交：见 claim/commit。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_mine_cue_resolution_test.dart` 新增 group `miningClipTimeMs`：delay=0 不动 / 正负 delay 偏移 / 下界 clamp / 与 `effectiveSubtitlePositionMs` 往返互逆。撤掉 `+ delayMs` 即转红。
- **备注**：仅文本字幕（可点 overlay）路径；图形内封字幕（PGS）无文本 cue，制卡取不到区间，不受影响。
