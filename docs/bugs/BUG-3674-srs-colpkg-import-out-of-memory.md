## BUG-3674 · Android 导入 .colpkg 报 Out of Memory
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：Android 上导入 .colpkg 报 Out of Memory。
- **真实性**：✅ 真 bug。根因：`importAnkiPackageFile` 用 `readAsBytes` 整读（`srs_apkg_import.dart` 约 158 行），`Isolate.run` 又复制一份，`ZipDecoder.decodeBytes` 整包解码（`srs_anki_package.dart` 约 120 行），archive 3.6.1 还缓存媒体内容，峰值内存数倍于包体积。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/apkg/srs_apkg_streaming_open_test.dart`
- **备注**：无。
