## BUG-1115 · 本地vs远端对比框缺有声书/音频数据库/视频三个维度
- **报告**：2026-07-26（用户：Hibiki 互联缺上传视频等操作，对比框缺有声书/音频数据库）
- **真实性**：✅ 真 bug。对比框只建书籍/词典行，且云有声书曾把 `audioBook_1_6_*.json` 播放位置误当 `audiobook.hibikiaudio`；资产删除统一把业务 identity 交给 `deleteAsset`，互联和云视频均删错目标。根因见 `hibiki/lib/src/sync/sync_compare_dialog.dart:343`、`hibiki/lib/src/sync/sync_compare_assets.dart:98`。
- **[x] ① 已修复** — 新增词典/有声书/本地音频数据库/视频四维真实对齐；逐条上传/下载使用真实业务路径，视频支持云清单删除与互联 host DELETE，动作后重新列举真实 locator。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/sync_compare_assets_test.dart`、`sync_compare_delete_test.dart`、`sync_orchestrator_video_test.dart`、`hibiki_sync_server_video_test.dart`。
- **备注**：本轮定向 89 tests 全绿；`flutter analyze --no-pub` 0 issue。
