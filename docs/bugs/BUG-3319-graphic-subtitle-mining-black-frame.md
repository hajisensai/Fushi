## BUG-3319 · 图形字幕制卡只有黑色静图、无同步视频和句子音频
- **报告**：2026-10-11（用户：图片字幕制卡，没有视频，只有一张黑色的图片，并且少了句子音频）
- **真实性**：✅ 真 bug（走查真实代码路径确认；BUG-3214 当时未复现的走查结论即本条情形 ①）。根因链：
  1. 选图形轨（PGS，libmpv 自绘）清空文本 cue：`fushi/lib/src/media/video/video_player_controller.dart:1596`
     `setCues([])`、`:1623` `_graphicSubtitleActive = true`；`miningCues`（`:893`）为空。
  2. 暂停 OCR 层点字查词不带锚点：`fushi/lib/src/pages/implementations/video_fushi_page.dart`
     `_buildGraphicSubtitleOcrOverlay` 的 `onCharTap` 原为 `_handleSubtitleLookupTap(..., null)`；
     `resolveVideoLookupAnchorCue`（`:391`）三级兜底全空 → `_lastLookupCue = null`。
  3. `fushi/lib/src/pages/implementations/video_fushi/lookup_mining.part.dart:160-215`：null cue →
     `clipStartMs = clipEndMs = 0`，`stillFrameAtMs = 0`。
  4. `fushi/lib/src/mining/immersion_mining_engine.dart`：无区间 → 不出同步片段（`:539` `hasRange` 假）、
     不抽句子音频；动图阶梯 `tryStartFrame`（`:579`）原来只判 `src != null`，在 0.000s 抽出片头黑帧并「成功」，
     当前帧兜底 `tryCurrentFrame` 永远轮不到；「字幕开头截图」模式（`:695`）同样。
- **[x] ① 已修复**（未提交，按要求不 commit）—
  - A 根因：`VideoPlayerController.currentGraphicSubtitleCue({text})` 读 mpv `sub-start` / `sub-end`，经纯函数
    `buildGraphicSubtitleAnchorCue`（`player_decoded_subtitle_cues.dart`）建在屏那句的锚点 cue（文本 = 被点的 OCR 句）。
    mpv `sub_get_times` 返回的是**字幕时基**（减过 `sub-delay`、不加回），与文本 cue 同坐标系；`delayMsForCue`
    对该锚点回主轨 `_delayMs`（= 图形模式下发的 `sub-delay`），`cueStreamOwning` 回单句流（不按副字幕邻句夹 padding）。
    暂停 OCR 层改走 `_handleGraphicSubtitleOcrLookupTap`：先取锚点再 `_handleSubtitleLookupTap(..., anchor)`，
    经 `_lastLookupCue` 走与文本字幕完全相同的区间 / 句子音频 / 同步片段链路。mpv 报无在屏字幕时锚点为 null。
  - B 引擎：`tryStartFrame` 加 `!req.hasClipWindow` 守卫（与 `tryGif` 同一窗几何判据），无窗不抽「字幕起点」帧，
    动图阶梯 / 字幕开头截图模式落到当前帧。
  - C 壳：无区间时 `stillFrameAtMs` = `controller.positionMs`（播放器轴），与 `sourceStartMs` 同口径。
  - D 不改：文本字幕卡的封面同样不烧字幕（字幕是 Flutter overlay、`screenshot()` 走 mpv `video` 标志、
    ffmpeg 从文件抽帧），图形字幕保持一致，不换成 `captureFrameWithSubtitles()`。
- **[x] ② 已加自动化测试** —
  - `fushi/test/mining/synchronized_video_mining_test.dart`：有源 + `0..0` 窗四种封面模式都不调抽帧器、
    落当前帧静图（撤掉引擎守卫后 videoClip / gif / subtitleStart 三条变红）；有窗时字幕开头截图照旧抽起点帧。
  - `fushi/test/media/video/graphic_subtitle_anchor_cue_test.dart`：锚点构造（mpv 秒值 / 无 sub-start / 缺 sub-end /
    空文本）、控制器按主轨调轴与单句流解释锚点、非图形模式不产锚点。
  - `fushi/test/pages/video_mining_context_guard_test.dart`：OCR 层查词必须带 `currentGraphicSubtitleCue` 锚点、
    无区间封面锚当前位置、引擎起点帧守卫（源码守卫）。
  - `fushi/test/settings/mining_audio_padding_guard_test.dart`：随 C 更新锚点表达式。
- **备注**：
  - 待补设备复测：真实 PGS 样片暂停 OCR 点字 → 制卡，确认卡上有同步片段 / 句子音频、时间窗与画面字幕对齐
    （含调轴非 0）。宿主无 libmpv，`sub-start` 对 sd_lavc（PGS）可用是按 mpv 源码 `sd_lavc.c get_times` 判断，未真机验证
    捆绑 libmpv 版本。
  - 未覆盖：不经暂停 OCR 查词的制卡入口（`_resolveVideoMiningRange` 的 currentCue / 按位置兜底）在图形模式下仍无锚点（走 C 的当前帧静图，无句子音频）；整轨 OCR 转文字后走
    文本 cue 路径，不受影响。
- **追加修复（2026-10-11）**：图形轨选中后在后台抽轨解析出 PGS 逐句时间表（与模糊遮蔽共用 `FfmpegGraphicSubtitleRegionLoader`，同一文件同一轨只抽一次），作为主字幕槽的无文字 cue 流并入 `miningCues` / `cueStreamOwning` / `delayMsForCue`——**任何制卡入口**（不只暂停 OCR 点字）都能按播放位置锚到那句，裁句子音频与同步片段，padding 按真实邻句夹边；mpv 缺 `sub-end` 时用时间表真实结束，画面恰好无字时按位置锚最近一句。测试：`fushi/test/media/video/graphic_subtitle_anchor_cue_test.dart`「图形字幕逐句时间表」组。仍不覆盖：远端流 / 非 PGS（VobSub、DVB）图形轨，这些只能靠 mpv `sub-start`/`sub-end`。
