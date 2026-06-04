# 视频制卡及查词 — 设计文档

- 日期：2026-06-04
- 分支/worktree：`worktree-video-mining`（基于 develop `6c8a3b515`）
- 状态：设计已与用户对齐，待用户最终审阅 → writing-plans

## 1. 背景与目标

为 Hibiki 增加「看视频学语言」能力：在带字幕的本地视频上**逐字点击查词**，并参照 [mpvacious](https://github.com/Ajatt-Tools/mpvacious) 的工作流**一键制作 Anki 卡**（例句 + 字幕音频片段 + 视频截图帧 + 词典字段）。

> 注：本仓库网络受限，无法在线核对 mpvacious README。本文中对 mpvacious 行为的描述以作者既有理解为准；落地时若与实际有出入，以 mpvacious 实际行为为准并在计划中修正。

### 用户已确认的需求边界

- **视频来源**：本地视频文件（mp4/mkv 等）+ **外挂字幕（srt/ass/vtt）** 与 **内嵌字幕轨** 两种都要。
- **平台**：全平台 5 端（Android / iOS / macOS / Windows / Linux）。
- **查词**：逐字点击精确切词（与 EPUB 阅读器同等精度）。
- **制卡**：参照 mpvacious（例句 + 字幕音频片段 + 视频截图帧 + 词典字段；多句合并；音频边界微调）。**只做"新建卡"**——用户确认删除 mpvacious 的"更新最近卡"模式。

### 非目标（YAGNI）

- 在线/流媒体视频（YouTube/Netflix）——范围与版权代价过大，不做。
- 把有声书音频栈从 just_audio 迁移到 media_kit——独立重构项目，与本功能解耦，仅记入 backlog。
- 视频转码/剪辑/字幕编辑器等通用媒体工具。

## 2. 关键决策

### 2.1 视频渲染层：全平台统一 media_kit（方案 A）

| 方案 | 做法 | 结论 |
|---|---|---|
| **A. 全平台 media_kit**（采纳） | `media_kit` + `media_kit_video` + 各端 video 库变体；视频走 libmpv | 一套代码覆盖 5 端；内嵌字幕轨抽取 / 精确帧 seek / 当前帧截图全部 libmpv 原生支持；桌面已在用 `just_audio_media_kit`（同底层）；media_kit 跨平台截图 API 直接解决「Android 抽视频帧」难题 |
| B. `video_player` + ffmpeg | 官方插件 | 否决：不支持内嵌字幕轨抽取（与需求冲突）、精确抓帧/seek 弱、桌面端支持差 |
| C. 桌面 media_kit + 移动 video_player | 两套 | 否决：两份代码、截图/字幕能力不一致、维护重 |

### 2.2 音视频双栈（用户确认采纳）

**视频用 media_kit，有声书音频继续用 just_audio，互不耦合。**

理由（含「为何不全栈统一 libmpv」的论证）：

1. **桌面端音频底层本来就是 libmpv**：现状 `just_audio` + `just_audio_media_kit`，桌面 just_audio 后端即 media_kit。引入 `media_kit_video` 后桌面音视频底层天然统一，没有两套。「换不换」只在移动端成立。
2. **移动端原生播放器在长时间后台音频上全面优于 libmpv**：有声书是熄屏后台连播数小时的场景，ExoPlayer/AVPlayer 是系统级硬件解码、低功耗、来电打断、蓝牙/锁屏媒体会话集成；libmpv 移动端为视频设计，跑纯音频后台功耗与系统集成更差。
3. **有声书层深度依赖 just_audio 专有能力**：`ConcatenatingAudioSource`（多文件无缝拼接）、`ClippingAudioSource`（`playRange` 单句试听）、跨章 gapless、锁屏 per-file seek。换 media_kit 需重写一个已打磨好的核心子系统，违反「不从零重写现有功能」「Never break userspace」。
4. **对视频功能零收益**：视频要的是画面渲染、内嵌字幕轨、精确抓帧，与有声书音频如何播放完全解耦。
5. **双栈不是坏味道**：这是两个独立子系统各用最优后端（视频页 → `VideoPlayerController`/media_kit；有声书页 → `AudiobookPlayerController`/just_audio），边界清晰、互不调用，而非「同一功能两套实现」。

## 3. 数据结构与存储

- **复用 `AudioCue{startMs,endMs,text,...}`**（`packages/hibiki_audio/.../audiobook_model.dart`），不新建字幕模型。
- 外挂字幕：复用现有 SRT/VTT/ASS 解析器（`packages/hibiki_audio/lib/src/parsers/`，含编码检测 `text_file_io.dart`）。
- 内嵌字幕轨：用 media_kit 列出 subtitle track → 导出文本 → 喂同一批解析器。
- 新增 Drift 表 `VideoBooks`（schema v15）：视频文件路径、字幕来源（外挂路径 / 内嵌轨 index）、封面、last position。
- cue 列表继续存 `audioCues` 表（复用 `replaceCuesForBook`，以 `bookUid` 区分视频书）。

## 4. 分阶段范围

### Phase 0 — 视频播放基座（最大、最独立）
- 引入 media_kit 全平台依赖（含各端 video 库变体）。
- 新建 `VideoPlayerController`：参照 `AudiobookPlayerController` 的 125ms 轮询 + `findCueIndex` 同步当前 cue，播放器换成 media_kit `Player`/`VideoController`。
- 新建视频页 `VideoHibikiPage`：画面 + 字幕 overlay（当前句高亮）+ 播放控制条（句级导航 `skipToNextCue` / `playCueOnce` 思路）。
- 导入入口：仿 `audiobook_import_dialog.dart`，选视频文件 + 外挂字幕 / 或选内嵌字幕轨。
- **Phase 0 重点验证**：media_kit 移动端与 just_audio 共存的初始化/释放时序；media_kit 截图 API 各端可用性与输出格式。

### Phase 1 — 字幕逐字查词
- 字幕 overlay 文本逐字符可点击：新写「字幕切词手势层」——对点击 offset 向后用 `HoshiDicts.lookup` 做最长匹配，得到选中词 + 整句上下文。（唯一无法复用 EPUB JS 选区脚本、必须新写的部分。）
- 查词弹窗复用 `DictionaryPopupNative`（纯 Flutter，不引第二个 WebView）+ `DictionaryPageMixin`，照搬 `FloatingDictPage` 模式。
- 点词自动暂停视频。

### Phase 2 — mpvacious 式制卡
- `AnkiMiningContext` 扩展 `screenshotPath` 字段 + handlebar `{video-screenshot}`（参照现有 `{book-cover}` / `{sasayaki-audio}`，在 `anki_models.dart` 的 `coreOptions` 与 `_handlebarToValue` 加 case）。
- **截图**：media_kit 当前帧 → PNG/WebP（全平台统一，无平台差异）。
- **音频片段**：按当前 cue 时间裁——桌面复用 `desktop_audio_clipper.dart` ffmpeg；Android 扩展现有原生裁剪走视频 audio track。
- **三件套制卡**：例句（当前字幕）+ 字幕音频片段 + 当前帧截图，一次制成一张卡，并叠加查词得到的词典字段。
- **多句合并**：标记起点句 → 当前句，合并文本、音频取首句起到当前句末、截图取当前帧。
- **音频边界微调**：`audioPaddingMs` 前后留白（mpvacious 同款）。
- **制卡模式（只此一种）**：一体化「新建卡」——视频里查词后直接带媒体制一张新卡（词典字段 + 例句 + 字幕音频 + 当前帧截图）。比 mpvacious 的两步流更顺，且 AnkiDroid / AnkiConnect 都支持，**无平台差异**。
- **已删除**：mpvacious 的「更新最近卡」模式（`guiBrowse added:1` + `updateNoteFields`）——用户确认不需要，连带省去 Android 不支持更新卡的降级处理。

## 5. 平台差异

- **制卡**：只做「新建卡」，AnkiDroid / AnkiConnect 均支持，**无平台差异**。
- **截图**：media_kit 全平台统一，无差异。
- **音频片段**：桌面 ffmpeg（需 `HIBIKI_FFMPEG`/PATH）、Android 原生 MediaExtractor 扩展。

## 6. 测试策略

- 字幕解析 / cue 同步：纯函数单测（复用 `findCueIndex` 测试范式）。
- 切词最长匹配：单测（字幕串 + 点击 offset → 断言切出的词 + 句）。
- 制卡字段组装：契约测试（`AnkiMiningContext` → handlebar 渲染断言）。
- 焦点驱动集成测试：视频页焦点遍历 + 制卡写穿（`FocusDriver`，三端可跑）。
- 真机/真模拟器复测原始路径（播放 + 截图 + 制卡），留证据。

## 7. 主要风险

1. media_kit 移动端包体增大（libmpv +10~20MB/端）、与 just_audio 共存的初始化/释放时序——**Phase 0 重点验证**。
2. media_kit 截图 API 各端实际可用性与格式——需早期打通验证。
3. Android 视频文件 audio track 裁剪的原生实现工作量。

## 8. Backlog（不在本功能范围）

- 移动端有声书音频迁移 media_kit（全栈统一 libmpv）——独立重构项目，需单独收益/回归论证。
- **在线/流媒体视频支持**——用户期望「能做最好」，但与本地视频是两套完全不同的工程（取流 / DRM / 各站字幕来源各异），不是在现有 Phase 上加一点能覆盖的。**本期不含**；定位为「本地三阶段落地后优先评估的后续独立功能」，届时单独立项设计。
