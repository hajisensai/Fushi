## BUG-3103 · 选中图形字幕后重开视频被取消选中（库里残留文本 cue 时恢复分支丢掉图形轨）
- **报告**：2026-10-09（用户 + 开发者哈吉千歳：选中图形字幕后重新打开视频，会被自动取消选中）
- **真实性**：✅ 真 bug（代码路径确证；未在真机重放用户原数据）。选轨本身有持久化（`embedded:<n>`），丢的是恢复：
  - `fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart:2757`（旧）：播放列表里的一集选中图形轨时
    **只写源指针**（`updateSubtitleSource`），不清这本书在库里的 cue。这份 cue 来自此前选过的文本字幕、OCR 转出的文字
    字幕、字幕合集面板批量指派（`subtitle_collection_panel.dart` 的 `saveSubtitleSelection`）或单视频模式下的选择。
  - `fushi/lib/src/pages/implementations/video_fushi_page.dart:4539`（旧）：重开时 `_loadSingle` 发现「库里有 cue 且源是
    `embedded:<n>`」就走 `rehydrateEmbedded` 分支重解析这条内嵌轨。`_restorePersistedSubtitle` 对图形轨正确地返回了
    「空 cue + graphicStreamIndex」，但这条分支只认 `restored.cues.isNotEmpty`，把图形轨结果当成「解析不出来」丢掉，
    继续用库里的旧 cue，且 `renderGraphicStreamIndex` 没传给播放器——libmpv 不渲染图形字幕、画面上换成旧文本字幕，
    用户看到的就是「图形字幕被自动取消选中」。之后的兜底链又因为 cue 非空整段跳过。
- **[x] ① 已修复**（4869645cba）— 两侧一起修：
  1. 恢复：重解析结果的三种去向收成纯函数 `mergeRestoredEmbeddedSubtitle`
     （`fushi/lib/src/media/video/video_subtitle_restore_plan.dart`）——图形轨清掉库里的 cue 并把序号交给
     `_applyLoad(renderGraphicStreamIndex:)`；文本轨用重解析的 cue；失败才保留缓存 cue。已确定渲染图形轨时不再进
     「没 cue → sidecar」兜底链。
  2. 选轨：图形轨无论单视频还是播放列表的一集，都用 `saveSubtitleSelection(cues: [])` 原子写源指针 + 清 cue，不再留
     会顶掉图形字幕的旧数据。
- **[x] ② 已加自动化测试**（4869645cba）— `fushi/test/media/video/video_subtitle_restore_plan_test.dart`：三种去向（图形轨清旧 cue
  并透传序号 / 文本轨用新 cue / 失败保留缓存）+ 视频页接线源码守卫（`_loadSingle` 走纯函数并透传 `graphicStreamIndex`、
  图形轨选轨分支清 cue 且不再只写指针）。
- **备注**：另一种「看起来没恢复」的路径是枚举内嵌轨的 `ffmpeg -i` 超时（预算 ≥60 s，罕见），那时恢复拿不到轨表、
  不知道 `embedded:<n>` 是不是图形轨；本次未改，若再报可让播放器按 libmpv 轨表的 codec 自判。
