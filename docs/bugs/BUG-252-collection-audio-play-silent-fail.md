## BUG-252 · 收藏夹播放按钮抽音失败时静默无反馈（「点了没用」）+ 视频收藏句缺播放按钮

- **报告**：2026-06-14（TODO-310：① 书籍收藏播放按钮点了没用；② 视频收藏句缺播放按钮）。
- **真实性**：✅ 真 bug（①）+ 真功能缺口（②）。
  - **①** 用户机器 `error_log.txt` 在 Jun14 01:06 连续 8 次记录 `extractAudioSegmentViaFfmpeg` `ffmpeg exit -1073741701`（`0xC0000139` STATUS_ENTRYPOINT_NOT_FOUND，本机 `ffmpeg.exe` 损坏，与 BUG-233 同根）。按钮**确实触发了** `_CollectionsPageState._playItemAudio`，是 ffmpeg 抽音崩溃返回 null。
  - **②** 视频来源收藏句（`source == kFavoriteSentenceSourceVideo`，bookKey 是视频 bookUid）永远不显示播放按钮。

### 根因（file:line）

- **①** `hibiki/lib/src/pages/implementations/collections_page.dart` 的 `_playItemAudio`（旧 :397-405）在 `TtsChannel.extractAudioSegment` 返回 `result != null` 时才 `playFile`，**`result == null`（ffmpeg 抽音失败）的 else 分支什么都不做、不弹任何 toast** → 用户看到「点了没用」，无法分辨是按钮坏了还是音频抽取失败。这是「安静降级」陷阱：失败路径完全无可见反馈。
  - ffmpeg PATH 回退本身**无问题**：collections 路径 `_playItemAudio → TtsChannel.extractAudioSegment`（`tts_channel.dart:262`，桌面分支）`→ extractAudioSegmentViaFfmpeg → _runFfmpeg → resolveFfmpegBackend().run`（`ffmpeg_backend.dart`），可执行文件「覆盖 > 捆绑 > PATH」解析与捆绑 ffmpeg 损坏自动回退 PATH（BUG-233）由 `ffmpeg_backend.dart` 统一保证，collections 自动经过，无需补回退代码。本机症状是 PATH 上的 ffmpeg 本身也损坏（用户需修本机 ffmpeg.exe），代码侧已尽责。
- **②** 同文件 `_load`（旧 :184-222）只从 `SrtBookRepository` / `AudiobookRepository` 填 `_cueMap` / `_audioFileMap`，**从不查 `VideoBookRepository`** → 视频句 bookKey（视频 bookUid）既不在 SrtBooks 也不在 Audiobooks → `_hasAudio` 恒 false → 视频收藏句永远没播放按钮（跳转定位路径 `_openVideoSentence` 此前已存在，仅缺播放）。

### [x] ① 已修复

`_playItemAudio` 的抽音+播放收敛到单一 `_extractAndPlay`，其 `result == null` 的 else 分支 `HibikiToast.show(msg: t.audio_clip_failed)`，明确告知是音频截取失败而非按钮坏。新增 i18n key `audio_clip_failed`（en `Couldn't extract the audio clip — the audio source may be missing or unreadable` / zh-CN `无法截取音频片段 — 音频源可能缺失或无法读取`，经 `tool/i18n_sync.dart` 同步 17 语言 + `dart run slang`）。

### [x] ② 已修复（完整抽音播放，非仅跳转）

视频收藏句**自带** cue 时间窗（保存时 `normCharOffset = cue.startMs`、`normCharLength = cue 时长`、`sectionIndex = 集索引`，见 `video_hibiki_page.dart` `_toggleFavoriteSentenceForVideo` / `_toggleFavoriteCueForVideo`），故**无需** `CollectionAudioMatcher`：

- 新增纯函数 `resolveVideoFavoriteAudioClip(row, favoriteSectionIndex, favoriteStartMs, favoriteDurationMs)` → `({String filePath, int startMs, int endMs})?`：单视频用 `VideoBookRow.videoPath`；多集播放列表按集索引从 `playlistJson` 取那一集绝对路径（越界 clamp）；缺起点 / 时长非正 / 解析失败返 null。
- `_load` 增查 `VideoBookRepository.getByBookUid` 填 `_videoRowMap`（按 bookUid）。
- `_hasAudio` 对视频来源句据 `_videoRowMap` + `resolveVideoFavoriteAudioClip` 判定（解析得出 clip 即显示播放按钮）。
- `_playItemAudio` 对视频来源句走 `_playVideoFavoriteAudio` → `resolveVideoFavoriteAudioClip` → `_extractAndPlay`。视频音频在容器内交错，但 ffmpeg `-ss`/`-t` 置于 `-i` 前做快速输入定位，只解码这几秒（不读穿整个文件），代价可控；`_playingAudio` 标志驱动播放按钮显示 loading（hourglass）作为抽音进行中的反馈。

### [x] ② 已加自动化测试

- `hibiki/test/pages/video_favorite_open_target_test.dart`：新增 `resolveVideoFavoriteAudioClip` 组 8 例——单视频抽 videoPath、多集按 sectionIndex 抽对应集文件、stale 集索引 clamp、无 startMs / 无时长 / 时长 0 返 null、坏 playlistJson 回退单视频。
- `hibiki/test/pages/sentence_favorites_todo047_guard_test.dart`：新增 `TODO-310` 组源码守卫——① 失败弹 `t.audio_clip_failed`（在 result==null 的 else 分支）；② `_load` 查 `VideoBookRepository` 填 `_videoRowMap`、`_hasAudio`/`_playItemAudio` 走 `resolveVideoFavoriteAudioClip`、视频来源分支独立；复用 cue 时间窗（normCharOffset=startMs / normCharLength=时长）。

### 不回归

- 书内 / 有声书 / SRT 来源句的播放路径不变（`_cueMap` / `_audioFileMap` + `CollectionAudioMatcher.findPlaybackRange`），仅把抽音+播放下沉到共用 `_extractAndPlay`，失败时新增 toast。
- 视频收藏句的跳转定位（`_openVideoSentence` / 对话框 video 按钮 / onTap 路由）此前已实现，本次只补播放按钮，不改跳转。
- `flutter analyze` collections_page.dart 0 issue；`test/pages/video_favorite_open_target_test.dart` + `sentence_favorites_todo047_guard_test.dart` + `collections_page_test.dart` 全绿。

### 残留风险

- **① 真机**：用户需修复本机损坏的 `ffmpeg.exe`（或 PATH 上提供可运行 ffmpeg）；代码侧已尽责（回退 + 失败可见）。
- **② 真机抽音待验**：host 无真 ffmpeg，视频抽音播放未在本轮跑通真实裁剪（纯逻辑层 `resolveVideoFavoriteAudioClip` + 源码守卫覆盖）。需真机 / 桌面用一条已收藏的视频句点播放按钮，验抽音播放成功；多 GB 容器抽音虽用快速输入定位，极端慢盘 / 大文件仍可能有延迟（`_playingAudio` loading 提示已覆盖此期间）。
