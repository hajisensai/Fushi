## BUG-3556 · 复习：从本机 Anki 迁移时媒体目录枚举与媒体文件在 UI isolate 上同步读，卡帧
- **报告**：2026-10-19（PR #2336 审查遗留，协调要求根本性修复）
- **真实性**：✅ 真 bug。根因（修前）`packages/fushi_engine/lib/srs/apkg/anki_collection_snapshot.dart:454-472` `AnkiMediaFolder.index()` 用 `listSync`、`read()` 用 `readAsBytesSync`；导入任务跑在 UI isolate（`srs_apkg_import.dart:99` 调用），几万个文件的媒体目录一次卡若干帧，大视频文件逐个卡。读媒体的契约 `SrsAnkiMediaEntryLoader`（`srs_anki_package.dart:57`）是同步的。
- **[x] ① 已修复** — `index()` 改异步、枚举放 `Isolate.run`；`SrsAnkiMediaEntryLoader` / `SrsAnkiPackage.mediaBytes` 改成 Future，`AnkiMediaFolder.read` 用异步 `exists` / `readAsBytes`；`_inlinePackagedStyles` 先异步读齐包内样式文件再同步查表展开。纯 IO、不是计算，不进 fushi_compute。
- **[x] ② 已加自动化测试** — `anki_collection_snapshot_consistency_test.dart` AnkiMediaFolder.index 组（枚举与单文件读：调用前排的 Timer 先于结果触发）；变异实测：index 改回同步枚举、read 改回同步读，各自红。
- **备注**：
