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

/// 用户自定义 TMDB API key 的偏好键（存 Drift `preferences` 表，不改 schema）。
/// app 侧 `tmdb_default_key.dart` 再导出它并与内置 key 一起决定「这次请求用哪把」；
/// 服务端刮削装配直接读它。
const String kVideoScraperTmdbApiKeyPref = 'video_scraper_tmdb_api_key';
