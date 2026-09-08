/// 媒体源偏好键的拼法（从 app 的 media_source.dart / reader_fushi_source.dart 抽出）。
///
/// 这些是持久化键的形状（DB `preferences` 表里真实存的字符串），互联 host 读书名
/// 覆盖时要按它们拼前缀；app 侧 `dbSourcePrefKey` / `MediaSource.overrideTitleKeyFor`
/// / `ReaderFushiSource.mediaIdentifierFor` 全部委派到这里。**值冻结**。
library;

import 'package:fushi_engine/media/override_title_key.dart';

export 'package:fushi_engine/media/override_title_key.dart';

/// `src:<sourceId>:<key>`。
String dbSourcePrefKey(String sourceId, String key) => 'src:$sourceId:$key';

/// 阅读器媒体源的持久化 id。
const String kReaderSourcePersistedKey = 'reader_fushi';

/// 书籍媒体标识前缀（`fushi://book/<bookKey>`）。
const String kReaderBookIdentifierPrefix = 'fushi://book/';

String readerBookMediaIdentifierFor(String bookKey) =>
    '$kReaderBookIdentifierPrefix$bookKey';

/// 规范书名覆盖键：`override_title://<mediaIdentifier>`。
String overrideTitleKeyFor(String mediaIdentifier) =>
    '$kOverrideTitleKeyMarker$mediaIdentifier';
