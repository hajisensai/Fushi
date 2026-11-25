## BUG-4263 · iOS 单个导入的视频过一阵「找不到文件」，重新导入后又失效
- **报告**：2026-11-09（用户：应用内反馈 HfXM-ECaE8，iOS 27.0.1 iPad17,1 / app 3.0.0+19763）
- **真实性**：✅ 真 bug（沿代码路径验证，未上 iPad 真机）。视频导入 `_pickVideo` 调丢掉出处的 `pickRealFilePath`（`fushi/lib/src/media/video/video_import_dialog.dart:433`，修复前行号）；iOS 上 file_picker 是 import 模式，交回 `NSTemporaryDirectory()` 里的临时副本，`pickRealFilePathDetailed` 本就把它标 `isRealPath: false`（`fushi/lib/src/media/import/real_path_directory_picker.dart:287`，文档写明「只能立刻复制消费，不能作为长期引用落库」）。但这条路径被原样写进 `VideoBooks.videoPath`（`video_import_dialog.dart:623/637`）。之后系统清 `tmp/`，或词典导入 / 外部阅读器导入调 `FilePicker.clearTemporaryFiles()` 清空整个 `tmp/`，条目就变成「找不到文件」。播放页「重新选择文件」（`fushi/lib/src/pages/implementations/video_fushi_page.dart:6485`）同样调 `pickRealFilePath` 拿 tmp 副本，所以重链后会再次失效。安卓无全文件访问 / provider 解析不出真实路径时落 app cache 副本，是同一个根因。BUG-2863 备注里已经记下这个后果，当时没有修。
- **[x] ① 已修复** — 新增 `adoptPickedVideoCopy`（`packages/fushi_engine/lib/media/video/video_local_files.dart`）：`isRealPath=false` 时把临时副本挪进 `EnginePaths.pickedVideoCopiesDirectory()` = `<support>/imported_videos/<sanitize(bookUid)>/<原文件名>`。先 rename，跨卷失败时退回 copy + 删源。视频导入和播放页重链都改走 `pickRealFilePathDetailed`，落库前先过这个函数。持久目录已加进 `EnginePaths.pickerImportCopyDirectories` 的默认项，`AppPathsEngineBridge` 在 iOS 上额外保留 `tmp/`，这样 BUG-2863 的删除回收对新、旧条目都继续生效。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/picked_video_copy_adoption_test.dart`，覆盖：副本挪进持久目录、原 tmp 文件已移走、仍被副本回收判据命中；真实路径不动；同 uid 旧副本被替换；持久目录默认登记；另有源码守卫，禁止两个持久化拾取点调用 `pickRealFilePath(`。
- **备注**：
  - 存量条目不追溯：修复前落库的 tmp 副本多半已被清掉，用户需要重新选择文件，重选一次后路径就持久了。
  - 未上 iPad 真机复测原始失败路径（导入 → 词典导入触发清 tmp → 再打开视频）。
  - 删条目后 `<support>/imported_videos/<uid>/` 下会留一个空目录，不占空间。
  - 「浏览」字幕搜索的「装到已有视频」（`home_page.dart:3244` 的 `pickVideo`）不持久化视频路径，但在 iOS 上会把字幕装到 tmp 副本旁边。这属于另一个交互问题（应当从库里选视频），本次没有改。
