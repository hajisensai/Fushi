// 「来源库」行的消费侧别名（命名统一 §1-F / Phase 3.2）。
//
// DB 层 Drift 生成类名仍是 `MediaSourceRow`（hibiki_core tables.dart
// `@DataClassName('MediaSourceRow')`，表 MediaSources；表名/列名/落库值是持久化
// 契约，绝不动）。app 消费侧统一用本别名，把「来源库行」与 jidoujisho 血统的
// UI 媒体源 `abstract class MediaSource`（media/media_source.dart）在源码可读性
// 上区分开。守卫见 test/media/source_library/source_file_system_test.dart。

import 'package:fushi_core/fushi_core.dart';

/// 「来源库」（扫描根）单行：[MediaSourceRow] 的语义别名。
typedef SourceLibraryRow = MediaSourceRow;
