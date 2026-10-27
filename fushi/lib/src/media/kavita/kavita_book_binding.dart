/// 本地 EPUB 书与 Kavita 章节的绑定（无 schema 变更）。
///
/// 绑定以 JSON 存进既有列 `EpubBooks.sourceMetadata`。该列对普通导入的 EPUB 恒为
/// null（只有在线漫画描述符 / LNReader 在线书 / Mihon 状态会写它），所以复用它不
/// 会和其它写入方打架；书被删时绑定随行消失，不需要额外清理。
///
/// 描述符带类型标记 [kKavitaBookMarker]，读取方一律先认标记再认字段：别人的
/// 描述符（在线漫画 / LNReader）解析为 null，绝不会被误当成 Kavita 绑定。
///
/// 描述符里**不存** API key / JWT / 带 key 的 URL，只存 `serverConfigId`，运行时再
/// 去 `kavita_servers` 取凭据。
library;

import 'dart:convert';

import 'package:fushi_engine/media/kavita/kavita_models.dart';

/// `sourceMetadata.type` 的取值；永不改（已写进用户库）。
const String kKavitaBookMarker = 'fushi-kavita-book';

const int _kBindingVersion = 1;

class KavitaBookBinding {
  const KavitaBookBinding({
    required this.serverConfigId,
    required this.seriesId,
    required this.volumeId,
    required this.chapterId,
    required this.libraryId,
    this.format = KavitaFormat.epub,
    this.cachedOnly = true,
    this.lastPushedAt,
    this.lastPulledAt,
    this.lastPushedPage,
    this.bookScrollId,
  });

  final String serverConfigId;
  final int seriesId;
  final int volumeId;
  final int chapterId;
  final int libraryId;

  /// `KavitaFormat` 值（目前只会是 epub）。
  final int format;

  /// true = 打开时拉取的缓存副本（可被清理）；false = 用户「下载」固定的副本。
  final bool cachedOnly;

  /// 最近一次成功推给服务器的本地时刻（epoch 毫秒）；null = 从没推过。
  final int? lastPushedAt;

  /// 最近一次从服务器拉进度的本地时刻（epoch 毫秒）。
  final int? lastPulledAt;

  /// 最近一次两侧达成一致的页号（脊柱页）：推送成功、打开时采用服务器进度、或拉取时
  /// 两侧本就相同。既用来去重（原地踏步不重复上报），也是打开时判断「本地动过没有」
  /// 的页级基线（见 `resolveKavitaProgress` 的 `lastSyncedPage`）。JSON 键名沿用
  /// `lastPushedPage`。
  final int? lastPushedPage;

  /// 最近一次与服务器交换的 `bookScrollId`（尽力而为的章内锚点）。
  final String? bookScrollId;

  KavitaBookBinding copyWith({
    bool? cachedOnly,
    int? lastPushedAt,
    int? lastPulledAt,
    int? lastPushedPage,
    String? bookScrollId,
  }) => KavitaBookBinding(
    serverConfigId: serverConfigId,
    seriesId: seriesId,
    volumeId: volumeId,
    chapterId: chapterId,
    libraryId: libraryId,
    format: format,
    cachedOnly: cachedOnly ?? this.cachedOnly,
    lastPushedAt: lastPushedAt ?? this.lastPushedAt,
    lastPulledAt: lastPulledAt ?? this.lastPulledAt,
    lastPushedPage: lastPushedPage ?? this.lastPushedPage,
    bookScrollId: bookScrollId ?? this.bookScrollId,
  );

  /// 是否指向同一台服务器上的同一章。
  bool sameChapterAs(String serverConfigId, int chapterId) =>
      this.serverConfigId == serverConfigId && this.chapterId == chapterId;

  String encode() => jsonEncode(<String, Object?>{
    'type': kKavitaBookMarker,
    'version': _kBindingVersion,
    'serverConfigId': serverConfigId,
    'seriesId': seriesId,
    'volumeId': volumeId,
    'chapterId': chapterId,
    'libraryId': libraryId,
    'format': format,
    'cachedOnly': cachedOnly,
    if (lastPushedAt != null) 'lastPushedAt': lastPushedAt,
    if (lastPulledAt != null) 'lastPulledAt': lastPulledAt,
    if (lastPushedPage != null) 'lastPushedPage': lastPushedPage,
    if (bookScrollId != null) 'bookScrollId': bookScrollId,
  });

  /// 解析 `sourceMetadata`；不是 Kavita 绑定 / 字段缺失 / 非 JSON 一律 null。
  static KavitaBookBinding? tryParse(String? sourceMetadata) {
    if (sourceMetadata == null || !sourceMetadata.contains(kKavitaBookMarker)) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(sourceMetadata);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?> ||
        decoded['type'] != kKavitaBookMarker) {
      return null;
    }
    final Object? serverId = decoded['serverConfigId'];
    final Object? chapterId = decoded['chapterId'];
    final Object? seriesId = decoded['seriesId'];
    if (serverId is! String || serverId.isEmpty) return null;
    if (chapterId is! int || seriesId is! int) return null;
    int intOr(Object? v, int fallback) => v is int ? v : fallback;
    return KavitaBookBinding(
      serverConfigId: serverId,
      seriesId: seriesId,
      volumeId: intOr(decoded['volumeId'], 0),
      chapterId: chapterId,
      libraryId: intOr(decoded['libraryId'], 0),
      format: intOr(decoded['format'], KavitaFormat.epub),
      cachedOnly: decoded['cachedOnly'] is bool
          ? decoded['cachedOnly']! as bool
          : true,
      lastPushedAt: decoded['lastPushedAt'] is int
          ? decoded['lastPushedAt']! as int
          : null,
      lastPulledAt: decoded['lastPulledAt'] is int
          ? decoded['lastPulledAt']! as int
          : null,
      lastPushedPage: decoded['lastPushedPage'] is int
          ? decoded['lastPushedPage']! as int
          : null,
      bookScrollId: decoded['bookScrollId'] is String
          ? decoded['bookScrollId']! as String
          : null,
    );
  }
}

/// `sourceMetadata` 是否 Kavita 绑定（廉价判定，供过滤用）。
bool isKavitaBookMetadata(String? sourceMetadata) =>
    KavitaBookBinding.tryParse(sourceMetadata) != null;
