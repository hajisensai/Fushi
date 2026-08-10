## BUG-1484 · 字幕列表打开时未定位到最近字幕

- **报告**：2026-08-10（用户：「字幕列表应该打开的时候跳转到最近的那一块（开启跟随的话。不然中间没有字幕的时候，会一直在开头）」）
- **真实性**：✅ 真 bug。

### 复现

视频页开着「跟随播放」，把播放头停在**没有字幕的静默段**（OP 之后、章节间隙、长间白），然后打开字幕列表：列表停在**最开头**，而不是刚播过的那一行附近。播放中途进入静默段时同样不跟随。

### 根因

面板把 `VideoPlayerController.currentCueIndex` 的 **-1** 当成「没有可定位的行」，而那个 -1 是**「命中」语义**的产物，不是「没有最近行」：

- `packages/fushi_audio/lib/src/parsers/json_alignment_parser.dart:102` `findCueIndex` 只回落在 `[startMs, endMs]` 闭区间内的 cue，落进 gap / 早于首句返回 -1；
- `fushi/lib/src/media/video/video_player_controller.dart:1642` 据此把 `_currentCueIndex` 清成 -1（这是对的：真实字幕过了时间窗就该从画面消失，BUG-074）；
- 面板的两条定位路径直接消费这个 -1 就放弃定位：
  - `fushi/lib/src/media/video/video_subtitle_jump_panel.dart:1129`（修复前行号；`_initialScrollOffsetForCurrentCue`，打开面板时的初始 offset）→ `currentIndex < 0` 直接 `return 0` ⇒ **停在开头**；
  - `fushi/lib/src/media/video/video_subtitle_jump_panel.dart:868`（修复前行号；`_scrollToCurrentCueIfNeeded`，跟随滚动）→ `rawIndex < 0` 直接 `return` ⇒ 静默段不跟随。

即：画面字幕要「命中」语义，列表跟随要「最近」语义，两者被同一个 -1 混同了。

### 修复

`fushi/lib/src/media/video/video_subtitle_jump_panel.dart` 新增两个带类型签名的顶层纯函数（与列表其余纯逻辑同源、可单测）：

- `int nearestCueIndexAtOrBefore(List<AudioCue> cues, int positionMs)`：取 `startMs <= positionMs` 中 `startMs` 最大者，并列取最先出现的那条（与「首条为代表行」同源）；播放头早于全部时取 `startMs` 最小者；空列表 -1。未排序 / 时间轴重叠也有唯一确定结果。
- `int resolveFollowCueIndex({cues, currentCueIndex, positionMs, follow})`：**唯一求法**——命中时原样用 controller 下标（保留音画延迟修正与 `skipToCue` 的 preRoll snap），未命中且 `follow` 开启才回落最近行；`follow` 关闭时仍返回 -1，历史行为逐像素不变。

面板侧 `_followCueIndex()` 作为单一入口（喂 `controller.effectivePositionMs`，与 controller 求命中同一根时间轴），initState / didUpdateWidget / `_onControllerChanged` / `_scrollToCurrentCueIfNeeded` / `_initialScrollOffsetForCurrentCue` 五处共用，调用点不再各自加 if。附带两处修正：

- `_lastControllerCueIndex` 改记**跟随目标行**而非裸 `currentCueIndex`——gap 里裸下标恒为 -1，会把「从一段静默 seek 到另一段静默」判成没变、列表不跟随；
- 粗滚估算行高的 `bold:` 改与真实渲染同源判定（静默段回落到的最近行不加粗）。

**高亮不受影响**：仍读裸 `currentCueIndex`，静默段依然没有高亮行（与画面一致）。

- **[x] ① 已修复** — 提交 `090d61c1a`，分支 `worktree-agent-ad28939c9b011f65c`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_list_follow_nearest_cue_test.dart`（19 条）：纯函数的空列表 / 首条之前 / 落 gap / 末条之后 / startMs 并列 / 未排序 / 重叠 + 逐字卡拉OK 合并后 raw→代表行映射 + 4 条真面板 widget 行为（跟随开启定位最近行、跟随关闭保持停在开头、gap→gap seek 跟随、早于首条定位首条）。变异实测：去掉最近行回落 ⇒ 5 红；去掉「早于首条 → 首条」回落 ⇒ 2 红。
- **备注**：`resolveFollowCueIndex` 的 `follow` 参数就是面板头部的「自动滚动 / 跟随播放」开关，关掉时零行为变化。
