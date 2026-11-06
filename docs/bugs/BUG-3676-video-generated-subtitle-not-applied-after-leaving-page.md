## BUG-3676 · video-generated-subtitle-not-applied-after-leaving-page
- **报告**：2026-10-23（用户反馈 DEStBY5I66：视频生成的日语字幕不能直接应用；Windows，截图停在首页「继续观看」，日志无相关报错）
- **真实性**：✅ 真缺陷（沿代码路径确认；是否就是反馈人遇到的那一种，反馈信息不足以证实）。视频页「生成日语字幕」只在两处把产物变成当前字幕：① 页面还停在这一集时 `_applyPipelineSubtitleWhenDone`（`fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart`，页面已 dispose / 换集就直接 return）；② 服务端登记 `AppVideoSubtitleService._registerSubtitleSource`（`fushi/lib/src/media/video/subtitle/app_video_subtitle_service.dart`），但它照整季口径「条目已有字幕选择就不覆盖」。转录要好几分钟，用户常常先退出播放页：条目原本选着内嵌轨 / 下载字幕时两条路都走不到，`<视频名>.ja.srt` 写出来了，重进播放页 `_loadSingle` 仍恢复旧选择（还会先命中旧源的 cue 缓存），生成的字幕「用不上」，只能自己去字幕菜单找。
- **[x] ① 已修复** — `AppVideoSubtitleEpisode.replacesSubtitleSelection`：`resolveBook(bookUid, videoPath: …)`（只有视频页单集入口传 videoPath）标记为替换；任务导出后 `_registerSubtitleSource(replace: true)` 用 `saveSubtitleSelection` 把新字幕写成这一行的选择并清掉旧源的 cue 缓存（与播放页选字幕同一事务写法）。整季（`resolveCollection`）与 CLI（不带 videoPath）仍「已有选择不覆盖」。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle/app_video_subtitle_service_test.dart`「视频页单集入口：替换已有字幕选择并清掉旧 cue 缓存」。
- **备注**：若反馈人说的是别的情形（例如页面一直开着却没切过去、或字幕菜单里选了也加载失败），需要补充操作步骤 / 录屏。
