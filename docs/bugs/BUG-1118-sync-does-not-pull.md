## BUG-1118 · 同步开关开启后书籍/有声书/视频仍不会自动拉取
- **报告**：2026-07-27（用户：修复不会拉取的问题）
- **真实性**：✅ 真 bug。完整同步仍把内容开关锁成 upload-only：互联远端独有 EPUB 在 `hibiki/lib/src/sync/sync_orchestrator.dart:1535` 只算 toPush；云有声书在 `:2843` 只上传包；云/互联视频在 `:1159`、`:2461` 只上传，远端独有项只允许 UI 手动下载。
- **[x] ① 已修复** — `run()` 先拉远端独有书再同步元数据/有声书；云与互联有声书双向补齐（含 standalone SRT uid）；云与互联远端独有单视频自动下载、字幕/标签入库，二次同步幂等；设置文案由“上传”改为“同步”。
- **[x] ② 已加自动化测试** — `sync_orchestrator_live_book_test.dart`、`sync_orchestrator_live_audio_test.dart`、`sync_orchestrator_video_test.dart`、`sync_orchestrator_live_video_test.dart` 分别覆盖互联书籍、配对/standalone 有声书、云视频与真实 host 视频拉取。
- **备注**：大文件开关仍默认关闭；开启对应开关即明确授权双向传输。多集视频仍不伪装成单文件拉取，避免破坏播放列表语义。
