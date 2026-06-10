## BUG-171 · 字幕拖到主页视频卡未挂到该视频（重复导入建副本）
- **报告**：2026-06-11（用户：「请把字幕拖到某个书籍或者视频上，我明明在主页拖到视频上了」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/home_video_page.dart:178-182`（旧 `attachToVideoCard` 分支）。
  在主页「视频」tab 把字幕拖到某张视频卡，决策层 `decideDropIntent` 正确返回 `attachToVideoCard`，
  但接线调 `_openVideoImportPrefilled(videoPath: hit.videoPath, subtitlePath: 字幕)` →
  打开 `VideoImportDialog` 预填后由 `_doImport()`（`video_import_dialog.dart:419-426`）走
  `_uniqueBookUid(singleVideoBookUid(videoPath))`：对**已存在**的视频重算 bookUid，命中同名碰撞后
  `uniqueVideoBookUid` 静默加后缀 `(2)`（`video_import_dialog.dart:59-65`）→ **新建 `video/<name> (2)`
  重复视频书**，字幕落到副本上，命中的原视频卡字幕没变。即「拖到视频上了，但没成功」。
  （书架 books 表面的视频卡另有问题：`_buildVideoCard` 未包 `CardDropZone`，但实验开关开启时书架不显示
  视频区，视频在视频 tab，属本次范围外的旧路径，未改动。）
- **[x] ① 已修复** — commit `<本轮>`：新增纯落库 helper
  `hibiki/lib/src/media/video/video_subtitle_attach.dart` 的 `attachSubtitleToVideoBook`，复刻播放页
  `_importExternalSubtitle` 的「拷盘到 `<appDocs>/video_subtitles/` → `parseSubtitleContent` 解析 cue →
  `VideoBookRepository.saveSubtitleSelection` 原子写源指针+cue」链路，但**直接对命中卡的既有 bookUid 写**，
  不重新导入、不去重加后缀。`home_video_page.dart` 的 `attachToVideoCard` 分支改调
  `_attachSubtitleToVideoCard(hit, 字幕)`，按结果给 SnackBar 反馈（成功带视频名+句数；播放列表卡无单一
  字幕语义，提示进播放页按集挂；不支持/拷贝失败/空 cue 各走对应文案）。
- **[x] ② 已加自动化测试** —
  `hibiki/test/media/video/video_subtitle_attach_test.dart`（4 例 DB 行为：单视频挂到同 bookUid 且不新建
  副本 / 播放列表不落库提示进播放页 / 不支持扩展名 / 空 cue 不覆盖）+
  `hibiki/test/pages/home_video_subtitle_drop_guard_test.dart`（源码守卫：`attachToVideoCard` 必经
  `_attachSubtitleToVideoCard`→`attachSubtitleToVideoBook`，且该分支不再调 `_openVideoImportPrefilled(`
  重复导入路径，防回归）。
- **备注**：真机拖放命中几何（`localToGlobal` 屏幕坐标命中卡）headless 测不到，需桌面真机复测原始失败路径。
  新增 i18n key `video_subtitle_attached_to_video` / `video_subtitle_attach_playlist_hint`（17 语言，
  英文占位待译）。
