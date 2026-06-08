## BUG-122 · PGS图形内封字幕标错内嵌+点了转圈/打不开
- **报告**：2026-06-08（用户：`[VCB-Studio] 第00話「守護術師フィッツ」.mkv` 内封字幕显示成内嵌，打不开，点了一直转圈）
- **真实性**：✅ 真 bug（UI 标注 + 缺图形字幕兜底）；「转圈卡死」部分为旧包行为，当前 develop 已是「瞬间失败提示」。

### 根因（真实代码路径取证）
真机文件 1.27GB，`ffmpeg -i`（Python 走 UTF-16 argv，与 Dart `Process.start` 同编码路径，正常打开）显示**唯一**字幕轨：
`Stream #0:2(jpn): Subtitle: hdmv_pgs_subtitle (pgssub)`，title "Main Subtitle" —— 蓝光 **PGS 位图**字幕，无任何 ASS/SRT 文本轨。
实测抽取 `-map 0:s:0 → .srt` **瞬间失败（0.0s, rc=-22）**：ffmpeg `Subtitle encoding currently only possible from text to text or bitmap to bitmap`。位图无法转文本，不做 OCR 拿不到可查词文字。

1. **标错「内嵌」**：`video_subtitle_source.dart:396 _embeddedLabel` 生成 `内嵌 N: lang / codec`。容器内软字幕应叫**内封**；菜单也未区分「图形轨无法转文字」，用户无法在点击前分辨哪条能用。
2. **「打不开」**：`_loadEmbeddedCues` 对 `subtitleFormatForCodec()==null`（PGS 等图形）`return []`，菜单点击落 `video_subtitle_load_failed` 提示——当前 develop 是瞬间失败（非卡死）。旧包（BUG-104/071 守卫前）才会真转圈。
3. **缺兜底**：图形字幕既不能查词、也没被当画面字幕显示（`load()` 一律 `setSubtitleTrack(SubtitleTrack.no())` 关掉 libmpv 画面字幕）→ 用户既看不到字幕、也点不开 = 完全不可用。

### 方案（用户选定：标注 + 当画面字幕显示）
- **术语**：`_embeddedLabel` 全部「内嵌」→「内封」。
- **数据模型**：`SubtitleSource` 加 `isGraphicEmbedded`（`isEmbedded && subtitleFormatForCodec(codec)==null`）。
- **菜单**：图形轨用不同图标 + 副标题提示「图形字幕 · 画面显示 · 不可查词」。
- **选中（即时）**：`_selectSubtitleSource` 图形分支——清 overlay cue + `controller.selectEmbeddedGraphicTrack(streamIndex)` 让 libmpv 渲染该 PGS + 持久化 `embedded:<n>` + 提示「已显示图形字幕（画面显示，不可查词）」，**不弹加载遮罩**（瞬时）。
- **控制器**：加 `selectEmbeddedGraphicTrack(int)`：等 `tracks.subtitle` 就绪→把相对 streamIndex 映射到 libmpv 真实字幕轨（`[auto,no,real0,real1…]` 去 auto/no 后第 N 条，与 `currentAudioStreamIndex` 同范式）→`setSubtitleTrack`。
- **恢复**：`_restorePersistedSubtitle`/`_applyLoad`/`load()` 透传图形选择，进页面/换集时渲染该轨（替代「解析 cue 失败退 sidecar」）。
- **i18n**：经 `tool/i18n_sync.dart` 增 key（17 语言），不手改生成文件。

### 测试
- 纯函数：`subtitleFormatForCodec('hdmv_pgs_subtitle')==null`（已有）、`isGraphicEmbedded` pgs=true/ass=false、`_embeddedLabel` 含「内封」。
- 源码守卫：菜单对图形轨用提示文案、控制器有 `selectEmbeddedGraphicTrack`、`load()` 不无条件 no() 掉已选图形轨。
- libmpv 真实轨选择/恢复无法纯单测（无 headless libmpv）→ 真机验证原始文件。

- **[x] ① 已修复** — 术语「内嵌」→「内封」(`video_subtitle_source.dart _embeddedLabel`)；`SubtitleSource.isGraphicEmbedded`；菜单图形轨标注 `video_subtitle_graphic_hint`；选中走 `VideoPlayerController.selectEmbeddedGraphicTrack`（libmpv 画面渲染，不弹遮罩）；`load(renderGraphicStreamIndex)` + `_restorePersistedSubtitle`/`_loadSingle`/`_loadEpisode`/`_applyLoad` 透传恢复；i18n 新增 `video_subtitle_graphic_hint`/`video_subtitle_graphic_shown`（17 语言，经 i18n_sync）。
- **[x] ② 已加自动化测试** — `test/media/video/video_subtitle_source_test.dart`（`isGraphicEmbedded` pgs/dvd=true、ass/subrip/mov_text/空=false、外挂=false）；`test/pages/video_graphic_subtitle_guard_test.dart`（术语「内封」守卫 + 控制器/页面图形渲染接线 + 图形分支在遮罩前 return）。targeted 42 绿，i18n+media/video+pages 619 绿（2 预存 headless skip）。
- **备注**：libmpv 真实轨选择/恢复无 headless 测试，真机复验文件 `C:\Users\wrds\Downloads\QQ\[VCB-Studio] 第00話「守護術師フィッツ」.mkv`（PGS-only）待用户。「一直转圈卡死」为旧包行为（PGS 守卫前），当前 develop 已是瞬间失败提示，本次进一步改为「画面显示」兜底。
