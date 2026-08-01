import 'package:hibiki_audio/hibiki_audio.dart' show FavoriteSentence;

/// A materialised, backend-agnostic snapshot of one device's aggregate state.
/// It carries the exact families AggregateMergeService folds (statistics +
/// favorites), the wire form the cloud backend stores as a per-device JSON
/// asset under the reserved `__aggregate__` namespace (TODO-1056 phase B):
/// the four statistic tables (reading / video watch / reading-hourly /
/// video-hourly), mining counts, favorite words, and the favorite-sentence
/// collection, each a flat row list keyed by the business identity the merge
/// folds use.
///
/// The snapshot is a pure value object: toJson / fromJson round-trip it, and
/// AggregateSyncService materialises it from a HibikiDatabase and applies a
/// merged snapshot back. Keeping the shape here (not inline in the orchestrator)
/// makes the round-trip and the merge unit-testable without any backend, and
/// pins the wire format under one guard.
class AggregateSnapshot {
  const AggregateSnapshot({
    this.readingStats = const <ReadingStatRecord>[],
    this.videoStats = const <VideoStatRecord>[],
    this.readingHourly = const <HourlyRecord>[],
    this.readingHourlyByFormat = const <HourlyFormatRecord>[],
    this.videoHourly = const <HourlyRecord>[],
    this.miningStats = const <MiningRecord>[],
    this.lookupMiningCounters = const <LookupMiningRecord>[],
    this.favoriteWords = const <FavoriteWordRecord>[],
    this.favoriteSentences = const <FavoriteSentence>[],
  });

  /// Wire format version. It is reserved for a genuinely BREAKING change (one
  /// that would make an old build mis-parse the payload); [fromJson] rejects a
  /// strictly-higher version by degrading to an empty snapshot. It is therefore
  /// deliberately NOT bumped for an ADDITIVE optional field.
  ///
  /// Forward/backward compatibility for additive fields (e.g. TODO-1204's
  /// `lookupMiningCounters`) rides on two invariants instead of the version:
  ///   - an OLD build reads a NEW payload and simply ignores the extra key it
  ///     does not know (it only reads the keys it asks for);
  ///   - a NEW build reads an OLD payload whose key is absent and defaults that
  ///     list to empty ([_decodeList] returns `[]` for a missing/non-list).
  /// Every family still folds either way. Bumping the version for an additive
  /// field would instead make every older peer reject the WHOLE snapshot, so the
  /// version stays put until a real incompatible reshape lands.
  static const int currentVersion = 1;

  final List<ReadingStatRecord> readingStats;
  final List<VideoStatRecord> videoStats;

  /// 阅读逐时**总量**（{dateKey, hour} 每桶一行 = 该小时全部阅读面之和）。
  /// 旧 wire 形状原样保留：不带 format 的旧端只认识这个 key，合并语义逐字节
  /// 不变（Never break userspace）。新端把它当「旧世界视角的小时总量」，应用
  /// 时只用来做差额归因（见 AggregateSyncService.applySnapshotToLocal）。
  final List<HourlyRecord> readingHourly;

  /// 阅读逐时**按写入面拆分**（{dateKey, hour, format} 每桶一行，v67）。加字段
  /// 走 additive-field 兼容不变量（见 [currentVersion] 注释）：旧端忽略本 key
  /// 且其上传不携带 → 新端把缺失当空列表，靠 [readingHourly] 差额归因兜底。
  final List<HourlyFormatRecord> readingHourlyByFormat;
  final List<HourlyRecord> videoHourly;
  final List<MiningRecord> miningStats;

  /// Per-book / per-video lookup + mine counters keyed by {title, sourceType,
  /// dateKey} (TODO-1204). Each row carries BOTH counts (lookupCount, mineCount)
  /// so the two columns of one `lookup_mining_counters` row travel together.
  final List<LookupMiningRecord> lookupMiningCounters;
  final List<FavoriteWordRecord> favoriteWords;
  final List<FavoriteSentence> favoriteSentences;

  /// True when nothing in the snapshot would change a peer: used to skip an
  /// empty upload on a device that has no aggregate state yet.
  bool get isEmpty =>
      readingStats.isEmpty &&
      videoStats.isEmpty &&
      readingHourly.isEmpty &&
      readingHourlyByFormat.isEmpty &&
      videoHourly.isEmpty &&
      miningStats.isEmpty &&
      lookupMiningCounters.isEmpty &&
      favoriteWords.isEmpty &&
      favoriteSentences.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': currentVersion,
        'readingStats':
            readingStats.map((ReadingStatRecord r) => r.toJson()).toList(),
        'videoStats':
            videoStats.map((VideoStatRecord r) => r.toJson()).toList(),
        'readingHourly':
            readingHourly.map((HourlyRecord r) => r.toJson()).toList(),
        'readingHourlyByFormat': readingHourlyByFormat
            .map((HourlyFormatRecord r) => r.toJson())
            .toList(),
        'videoHourly': videoHourly.map((HourlyRecord r) => r.toJson()).toList(),
        'miningStats': miningStats.map((MiningRecord r) => r.toJson()).toList(),
        'lookupMiningCounters': lookupMiningCounters
            .map((LookupMiningRecord r) => r.toJson())
            .toList(),
        'favoriteWords':
            favoriteWords.map((FavoriteWordRecord r) => r.toJson()).toList(),
        'favoriteSentences':
            favoriteSentences.map((FavoriteSentence s) => s.toJson()).toList(),
      };

  /// Decodes a snapshot from a backend JSON asset. A null / non-map payload, or
  /// one whose version is strictly HIGHER than [currentVersion] (a future
  /// breaking reshape this build cannot understand), yields an empty snapshot —
  /// a peer snapshot the device cannot understand must degrade to a no-op, never
  /// abort the sweep. An equal / older version, or an additive key this build
  /// does not know, is read best-effort: known families fold, missing lists
  /// default to empty, and malformed individual rows are skipped, not fatal.
  static AggregateSnapshot fromJson(Object? json) {
    if (json is! Map) return const AggregateSnapshot();
    final Object? version = json['version'];
    if (version is int && version > currentVersion) {
      // A future device wrote a shape this build does not know: skip it rather
      // than mis-parse. Older/equal versions are read best-effort below.
      return const AggregateSnapshot();
    }
    return AggregateSnapshot(
      readingStats:
          _decodeList(json['readingStats'], ReadingStatRecord.fromJson),
      videoStats: _decodeList(json['videoStats'], VideoStatRecord.fromJson),
      readingHourly: _decodeList(json['readingHourly'], HourlyRecord.fromJson),
      readingHourlyByFormat: _decodeList(
          json['readingHourlyByFormat'], HourlyFormatRecord.fromJson),
      videoHourly: _decodeList(json['videoHourly'], HourlyRecord.fromJson),
      miningStats: _decodeList(json['miningStats'], MiningRecord.fromJson),
      lookupMiningCounters: _decodeList(
          json['lookupMiningCounters'], LookupMiningRecord.fromJson),
      favoriteWords:
          _decodeList(json['favoriteWords'], FavoriteWordRecord.fromJson),
      favoriteSentences: _decodeFavoriteSentences(json['favoriteSentences']),
    );
  }

  static List<T> _decodeList<T>(
    Object? raw,
    T? Function(Map<String, Object?> row) decode,
  ) {
    if (raw is! List) return <T>[];
    final List<T> out = <T>[];
    for (final Object? e in raw) {
      if (e is! Map) continue;
      final Map<String, Object?> row = e.cast<String, Object?>();
      final T? decoded = decode(row);
      if (decoded != null) out.add(decoded);
    }
    return out;
  }

  static List<FavoriteSentence> _decodeFavoriteSentences(Object? raw) {
    if (raw is! List) return <FavoriteSentence>[];
    final List<FavoriteSentence> out = <FavoriteSentence>[];
    for (final Object? e in raw) {
      if (e is! Map) continue;
      try {
        out.add(FavoriteSentence.fromJson(e.cast<String, dynamic>()));
      } catch (_) {
        // Skip a malformed sentence rather than abort the whole snapshot.
      }
    }
    return out;
  }
}

/// One reading-statistics bucket keyed by {title, dateKey}.
class ReadingStatRecord {
  const ReadingStatRecord({
    required this.title,
    required this.dateKey,
    required this.charactersRead,
    required this.readingTimeMs,
    required this.lastStatisticModified,
  });

  final String title;
  final String dateKey;
  final int charactersRead;
  final int readingTimeMs;
  final int lastStatisticModified;

  /// Business identity for the MAX-union fold: two rows with the same key are
  /// the same bucket and get field-wise MAX-ed. Length-prefixed title so a
  /// separator inside the title cannot forge the field boundary.
  String get key => '${title.length}:$title|$dateKey';

  Map<String, Object?> toJson() => <String, Object?>{
        'title': title,
        'dateKey': dateKey,
        'charactersRead': charactersRead,
        'readingTimeMs': readingTimeMs,
        'lastStatisticModified': lastStatisticModified,
      };

  static ReadingStatRecord? fromJson(Map<String, Object?> json) {
    final Object? title = json['title'];
    final Object? dateKey = json['dateKey'];
    if (title is! String || dateKey is! String) return null;
    return ReadingStatRecord(
      title: title,
      dateKey: dateKey,
      charactersRead: _asInt(json['charactersRead']),
      readingTimeMs: _asInt(json['readingTimeMs']),
      lastStatisticModified: _asInt(json['lastStatisticModified']),
    );
  }
}

/// One video-watch-statistics bucket keyed by {title, dateKey}.
class VideoStatRecord {
  const VideoStatRecord({
    required this.title,
    required this.dateKey,
    required this.subtitleChars,
    required this.watchTimeMs,
    required this.lastModified,
  });

  final String title;
  final String dateKey;
  final int subtitleChars;
  final int watchTimeMs;
  final int lastModified;

  String get key => '${title.length}:$title|$dateKey';

  Map<String, Object?> toJson() => <String, Object?>{
        'title': title,
        'dateKey': dateKey,
        'subtitleChars': subtitleChars,
        'watchTimeMs': watchTimeMs,
        'lastModified': lastModified,
      };

  static VideoStatRecord? fromJson(Map<String, Object?> json) {
    final Object? title = json['title'];
    final Object? dateKey = json['dateKey'];
    if (title is! String || dateKey is! String) return null;
    return VideoStatRecord(
      title: title,
      dateKey: dateKey,
      subtitleChars: _asInt(json['subtitleChars']),
      watchTimeMs: _asInt(json['watchTimeMs']),
      lastModified: _asInt(json['lastModified']),
    );
  }
}

/// One hourly-log bucket keyed by {dateKey, hour}. Shared shape for both the
/// reading and video hourly tables (each carries one duration column).
class HourlyRecord {
  const HourlyRecord({
    required this.dateKey,
    required this.hour,
    required this.durationMs,
  });

  final String dateKey;
  final int hour;
  final int durationMs;

  String get key => '$dateKey|$hour';

  Map<String, Object?> toJson() => <String, Object?>{
        'dateKey': dateKey,
        'hour': hour,
        'durationMs': durationMs,
      };

  static HourlyRecord? fromJson(Map<String, Object?> json) {
    final Object? dateKey = json['dateKey'];
    if (dateKey is! String) return null;
    return HourlyRecord(
      dateKey: dateKey,
      hour: _asInt(json['hour']),
      durationMs: _asInt(json['durationMs']),
    );
  }
}

/// One reading hourly-log bucket keyed by {dateKey, hour, format} (v67 拆分维度
/// 的 wire 形状)。[format] 是写入面身份（`BookFormat.dbValue`；`''` = 历史未区分
/// 桶），逐字节透传——未来新增格式值在旧端也原样保留、不折叠。
class HourlyFormatRecord {
  const HourlyFormatRecord({
    required this.dateKey,
    required this.hour,
    required this.format,
    required this.durationMs,
  });

  final String dateKey;
  final int hour;
  final String format;
  final int durationMs;

  /// 长度前缀防歧义（风格同 [MiningRecord.key]）：format 是自由串。
  String get key => '${format.length}:$format|$dateKey|$hour';

  Map<String, Object?> toJson() => <String, Object?>{
        'dateKey': dateKey,
        'hour': hour,
        'format': format,
        'durationMs': durationMs,
      };

  static HourlyFormatRecord? fromJson(Map<String, Object?> json) {
    final Object? dateKey = json['dateKey'];
    final Object? format = json['format'];
    if (dateKey is! String || format is! String) return null;
    return HourlyFormatRecord(
      dateKey: dateKey,
      hour: _asInt(json['hour']),
      format: format,
      durationMs: _asInt(json['durationMs']),
    );
  }
}

/// One mining-statistics bucket keyed by {sourceType, dateKey}.
class MiningRecord {
  const MiningRecord({
    required this.sourceType,
    required this.dateKey,
    required this.count,
  });

  final String sourceType;
  final String dateKey;
  final int count;

  String get key => '${sourceType.length}:$sourceType|$dateKey';

  Map<String, Object?> toJson() => <String, Object?>{
        'sourceType': sourceType,
        'dateKey': dateKey,
        'count': count,
      };

  static MiningRecord? fromJson(Map<String, Object?> json) {
    final Object? sourceType = json['sourceType'];
    final Object? dateKey = json['dateKey'];
    if (sourceType is! String || dateKey is! String) return null;
    return MiningRecord(
      sourceType: sourceType,
      dateKey: dateKey,
      count: _asInt(json['count']),
    );
  }
}

/// One lookup/mining counter bucket keyed by {title, sourceType, dateKey}
/// (TODO-1204). Mirrors one `lookup_mining_counters` row: both counters
/// (lookupCount, mineCount) travel together and are MAX-ed independently on
/// merge. [bookKey] is optional metadata (the book/video identity) that is NOT
/// part of the dedupe key (a no-book lookup has title='' and bookKey=null); it
/// travels so a peer-only bucket lands with its book identity, and on a key
/// collision the merge keeps whichever side has a non-null bookKey.
class LookupMiningRecord {
  const LookupMiningRecord({
    required this.bookKey,
    required this.title,
    required this.sourceType,
    required this.dateKey,
    required this.lookupCount,
    required this.mineCount,
  });

  final String? bookKey;
  final String title;
  final String sourceType;
  final String dateKey;
  final int lookupCount;
  final int mineCount;

  /// Business identity for the MAX-union fold, exactly the table's unique key
  /// {title, sourceType, dateKey}. Length-prefixed title / sourceType so a
  /// separator inside a field cannot forge the boundary.
  String get key =>
      '${title.length}:$title|${sourceType.length}:$sourceType|$dateKey';

  Map<String, Object?> toJson() => <String, Object?>{
        'bookKey': bookKey,
        'title': title,
        'sourceType': sourceType,
        'dateKey': dateKey,
        'lookupCount': lookupCount,
        'mineCount': mineCount,
      };

  static LookupMiningRecord? fromJson(Map<String, Object?> json) {
    final Object? title = json['title'];
    final Object? sourceType = json['sourceType'];
    final Object? dateKey = json['dateKey'];
    if (title is! String || sourceType is! String || dateKey is! String) {
      return null;
    }
    return LookupMiningRecord(
      bookKey: json['bookKey'] as String?,
      title: title,
      sourceType: sourceType,
      dateKey: dateKey,
      lookupCount: _asInt(json['lookupCount']),
      mineCount: _asInt(json['mineCount']),
    );
  }
}

/// One favorite word keyed by {expression, reading, sourceType}. createdAt /
/// glossary / dateKey travel so a peer-only word lands with its own metadata,
/// but they are NOT part of the dedupe identity (mirrors favorite_words' unique
/// key).
class FavoriteWordRecord {
  const FavoriteWordRecord({
    required this.expression,
    required this.reading,
    required this.glossary,
    required this.sourceType,
    required this.dateKey,
    required this.createdAt,
  });

  final String expression;
  final String reading;
  final String glossary;
  final String sourceType;
  final String dateKey;
  final int createdAt;

  /// Dedupe identity: {expression, reading, sourceType}, exactly the table's
  /// unique key. Length-prefixed so a separator inside a field cannot forge a
  /// boundary.
  String get uniqueKey =>
      '${expression.length}:$expression|${reading.length}:$reading|$sourceType';

  Map<String, Object?> toJson() => <String, Object?>{
        'expression': expression,
        'reading': reading,
        'glossary': glossary,
        'sourceType': sourceType,
        'dateKey': dateKey,
        'createdAt': createdAt,
      };

  static FavoriteWordRecord? fromJson(Map<String, Object?> json) {
    final Object? expression = json['expression'];
    final Object? sourceType = json['sourceType'];
    if (expression is! String || sourceType is! String) return null;
    return FavoriteWordRecord(
      expression: expression,
      reading: (json['reading'] as String?) ?? '',
      glossary: (json['glossary'] as String?) ?? '',
      sourceType: sourceType,
      dateKey: (json['dateKey'] as String?) ?? '',
      createdAt: _asInt(json['createdAt']),
    );
  }
}

/// Tolerant int coercion: a JSON int survives; a double or numeric string (from
/// a lenient encoder) is floored/parsed; anything else is 0.
int _asInt(Object? v) {
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}
