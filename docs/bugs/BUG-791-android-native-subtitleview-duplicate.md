## BUG-791 · 安卓视频原生SubtitleView与可点浮层字幕重复(控制条显示时上下两条)
- **报告**：2026-07-14（用户：安卓视频，字幕；截图 OP staffroll 场景 00:06，外挂 .ass，所有视频都复现）
- **真实性**：✅ 真 bug。**确切根因已定位**：libmpv `sub-auto=exact` 在 `open()` 自动加载同名 sidecar 字幕，经 media_kit 原生 `SubtitleView` 渲染，与 Hibiki 可点 overlay 叠成双字幕。根因 `hibiki/lib/src/media/video/video_player_controller.dart`（抑制在 open **之后**才下发，太迟）。
- **[x] ① 已修复** — 在 `player.open()` **之前**下发 `sub-auto=no`（`video_player_controller.dart` load()，commit 见下），libmpv 从一开始就不自动加载 sidecar。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_sidecar_autoload_guard_test.dart`（源码扫描守卫：抑制必须在 `player.open(` 之前）。
- **备注**：本条与草稿 PR#94 的 BUG-790 撞号，已手动改 791。**待真机复测原始失败路径**（安卓 + 视频旁有同名 sidecar .ass + 显示控制条，确认只剩一条字幕；并验证 PGS 图形字幕不回归）。

---

### 症状
安卓视频播放：**控制条隐藏时字幕正常（1 条）；控制条显示时字幕变成上下两条**（同一句文本）。
- 上面一条：**较大**、干净、随控制条出现被抬到画面中部（躲进度条）。
- 下面一条：**较小**、钉在最底部、被进度条/控制按钮盖住，不随控制条移动。

截图证据：两条字幕**字号明显不同** = 两个不同渲染器。桌面端不复现（安卓特有）。

### 验真过程（沿真实代码路径）
1. **浮层只有一个实例、只有它渲染 cue**：全仓 `VideoSubtitleOverlay(` 仅 `layout.part.dart:324` 一处，且已 wired `controlsVisible: _videoControlsVisible`（会随控制条上抬）。唯一消费 `activeCues` 渲染的组件就是它（`video_subtitle_overlay.dart:478`）。
2. **数据层无重复**：用 app 的 `AssParser.parseString` 解析用户真实文件（`Shunkashuutou…S01E08…ToonsHub.ass`），6000ms 处**只有 1 条 cue**（`ああ　四季庁よりも2人の意思を\N優先するよう動いてくれ`，`Text_JP` 样式 Alignment=2 底部、MarginV=30、无 `\pos`），全片仅出现 1 次。单 cue → 单渲染（widget 测试证实一条底部 cue 正确避让、只出一个盒子）。
3. **下面那条是 media_kit 原生 `SubtitleView`**：
   - `libass = false`（media_kit 默认 `platform_player.dart:526`，Hibiki 构造 `Player()` 从不设 libass，`video_player_controller.dart:1257-1263`）→ libmpv **不**把字幕烤进纹理。
   - fork `third_party/media_kit_video/lib/src/video/video_texture.dart:450-460`：`SubtitleView` 仅在 `subtitleViewConfiguration.visible && !libass` 时渲染，且**位于 controls（Hibiki 浮层）之下**（`:461-463`）。z 序、字号差、"随控制条上抬的是上面那条浮层、下面那条不动" 全部吻合。
   - `MaterialVideoControls` 不自渲染字幕（只 `shiftSubtitle` 改 padding，且 `shiftSubtitlesOnControlsVisibilityChange` 默认 false，`material.dart:759`）——排除控制条自带字幕。
4. **`SubtitleView` 出字的必要条件**：① `subtitleViewConfiguration.visible == true`（运行时）**且** ② `player.state.subtitle` 非空（= libmpv 里有被选中的字幕轨在吐 `sub-text`）。Hibiki 本应把 ① 压成 `visible:false`（`layout.part.dart:79`、`fullscreen.part.dart:140`）、把 ② 压成空（`setSubtitleTrack(SubtitleTrack.no())` + `sub-auto=no` + `sub-visibility=no`，`video_player_controller.dart:1413-1425`）。**安卓上没压住**。
   - `ffprobe` 该视频（`…ToonsHub.mkv`）：只有 h264 视频 + eac3 音频，**无任何内嵌字幕轨**。故原生那条不是内嵌轨。
   - **关键**：`.ass` 与 `.mkv` **同目录、同基础名**（`…ToonsHub.ass` / `…ToonsHub.mkv`）= 一个 **sidecar 外挂字幕**。libmpv 默认 `sub-auto=exact` 会在 `open()` 加载文件时**自动加载同名 sidecar** 并选成字幕轨 → `player.state.subtitle` 非空 → 原生 `SubtitleView` 渲染。Hibiki 又自己把同一 `.ass` 解析成 cue 走可点 overlay → 同句双份、异字号、异位置（原生小字号钉底 dy≈基线、overlay 大字号随控制条避让）。widget 测试量到两条正好落在「基线 531 / 避让 431」= 一条避让一条不避让，坐实两个渲染器。
   - "所有视频都复现" 亦吻合：用户视频旁常年放同名 sidecar 字幕。

### 根因（已确认）
字幕抑制 `buildSubtitleSuppressionProperties()`（`sub-auto=no` + `sub-visibility=no`）在 `load()` 里**只在 `player.open()` 之后下发一次**（旧 `video_player_controller.dart:1422`）。但 **sidecar 的自动加载发生在 `open()` 那一刻**（libmpv `sub-auto=exact`），open 之后再设 `sub-auto=no` 已**太迟**——sidecar 早已被加载并选中，随后经原生 `SubtitleView` 渲染。桌面端亦有同源二层历史（BUG-190），但安卓 `SubtitleView`（libass=false 走 Flutter 层字幕）表现最直观。

### 修复（已落地）
在 `player.open()` **之前**先下发一次 `buildSubtitleSuppressionProperties()`（`sub-auto=no`），让 libmpv 从一开始就不自动加载 sidecar；open 之后仍保留原有那次做兜底（内嵌轨 open 后异步就绪的重选竞态）。不影响：内嵌轨仍被 demux 枚举（供 `_loadEmbeddedSubtitleIfNeeded` ffmpeg 抽取）、图形 PGS 轨仍由 `selectEmbeddedGraphicTrack` 显式选轨渲染（`sub-auto` 只管**自动**加载/选择，不管**显式** `setSubtitleTrack`）。
- 代码：`video_player_controller.dart` load() `await player.open(` 之前插入 `applySubtitleMpvPropertiesToPlayer(player, buildSubtitleSuppressionProperties())`。
- 守卫：`test/media/video/video_subtitle_sidecar_autoload_guard_test.dart`（源码扫描：抑制必须在 `player.open(` 之前）。

### 待办
- [ ] 真机复测原始失败路径（安卓 CPH2747 + 视频旁同名 sidecar .ass + 显示控制条）：确认只剩一条可点 overlay 字幕、底部原生小字幕消失。
- [ ] 验证 PGS 图形字幕（显式选图形轨）不回归。
