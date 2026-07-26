## BUG-1117 · 同步漏传与摘要漏报：未读书不上传、互联退书绕过 live、视频/书出站不可见
- **报告**：2026-07-26（用户：同步操作感觉有些没上传）
- **真实性**：✅ 真 bug。云端内容上传依附阅读进度裁决，两端进度均空或已一致会提前返回，远端缺 EPUB 也不传；退书互联只跑通用文件箱，未触达 host 实时书库；摘要未拼视频出站且无书籍出站计数。根因见 `hibiki/lib/src/sync/sync_manager.dart:792`、`sync_orchestrator.dart:460`、`manual_sync_ui.dart:21`。
- **[x] ① 已修复** — 云与互联都把书内容 upload sweep 从进度裁决拆开；退书改走 scoped orchestrator/live 进度；补 `booksPushed`、`videosExported/videosImported` 和真实 `assetsTransferred` 计数。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/sync_orchestrator_live_book_test.dart` 锁住“无进度也上传 EPUB”；`sync_summary_test.dart` 锁住书/视频出站与手动视频下载计数。
- **备注**：旧版仍不自动拉 GB 级视频的边界已按用户后续要求在 BUG-1118 改为开关内双向同步。
