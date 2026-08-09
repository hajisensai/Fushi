import 'dart:convert';

/// ッツ Ebook Reader / Hoshi Reader 兼容的同步数据模型。
///
/// **本文件只含ッツ外部 wire 契约**（[TtuProgress] / [TtuStatistics] /
/// [TtuAudioBook]）：JSON 字段名与 ッツ/Hoshi 格式一致，保证三方互通。
/// 这里的任何改名/字段增删都是跨 app 协议变更，需与ッツ/Hoshi 三方协商，
/// 不得在本仓单方面进行。**与ッツ无关的内部类型禁止住在本文件**——通用远端
/// 文件句柄与内部枚举已迁至 `sync_file_ref.dart`（命名统一轮 §1-H）。

class TtuProgress {
  TtuProgress({
    required this.dataId,
    required this.exploredCharCount,
    required this.progress,
    required this.lastBookmarkModified,
  });

  final int dataId;
  final int exploredCharCount;
  final double progress;
  final int lastBookmarkModified;

  // Integer fields use tolerant coercion: this format is shared three-way with
  // ッツ/Hoshi, so an int may arrive as a JSON float/null/string. A bare
  // `as int` would throw TypeError and abort the whole decode (HBK-AUDIT-030).
  factory TtuProgress.fromJson(Map<String, dynamic> json) => TtuProgress(
        dataId: (json['dataId'] as num?)?.toInt() ?? 0,
        exploredCharCount: (json['exploredCharCount'] as num?)?.toInt() ?? 0,
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        lastBookmarkModified:
            (json['lastBookmarkModified'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'dataId': dataId,
        'exploredCharCount': exploredCharCount,
        'progress': progress,
        'lastBookmarkModified': lastBookmarkModified,
      };

  static TtuProgress decode(String source) =>
      TtuProgress.fromJson(jsonDecode(source) as Map<String, dynamic>);

  String encode() => jsonEncode(toJson());
}

class TtuStatistics {
  TtuStatistics({
    required this.title,
    required this.dateKey,
    required this.charactersRead,
    required this.readingTimeSec,
    required this.minReadingSpeed,
    required this.altMinReadingSpeed,
    required this.lastReadingSpeed,
    required this.maxReadingSpeed,
    required this.lastStatisticModified,
  });

  final String title;
  final String dateKey;
  final int charactersRead;
  final double readingTimeSec;
  final int minReadingSpeed;
  final int altMinReadingSpeed;
  final int lastReadingSpeed;
  final int maxReadingSpeed;
  final int lastStatisticModified;

  // HBK-AUDIT-142: required string fields use `as String?` with an empty
  // fallback. This format is shared three-way with ッツ/Hoshi cloud APIs; a
  // malformed/partial payload that omits a field (or a 200-but-error body)
  // would make a bare `as String` throw a CastError that bypasses the
  // SyncBackendError contract. Coercing to '' keeps the decode total.
  factory TtuStatistics.fromJson(Map<String, dynamic> json) => TtuStatistics(
        title: json['title'] as String? ?? '',
        dateKey: json['dateKey'] as String? ?? '',
        charactersRead: (json['charactersRead'] as num?)?.toInt() ?? 0,
        readingTimeSec: (json['readingTime'] as num?)?.toDouble() ?? 0,
        minReadingSpeed: (json['minReadingSpeed'] as num?)?.toInt() ?? 0,
        altMinReadingSpeed: (json['altMinReadingSpeed'] as num?)?.toInt() ?? 0,
        lastReadingSpeed: (json['lastReadingSpeed'] as num?)?.toInt() ?? 0,
        maxReadingSpeed: (json['maxReadingSpeed'] as num?)?.toInt() ?? 0,
        lastStatisticModified:
            (json['lastStatisticModified'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'dateKey': dateKey,
        'charactersRead': charactersRead,
        'readingTime': readingTimeSec,
        'minReadingSpeed': minReadingSpeed,
        'altMinReadingSpeed': altMinReadingSpeed,
        'lastReadingSpeed': lastReadingSpeed,
        'maxReadingSpeed': maxReadingSpeed,
        'lastStatisticModified': lastStatisticModified,
      };

  static List<TtuStatistics> decodeList(String source) =>
      (jsonDecode(source) as List)
          .cast<Map<String, dynamic>>()
          .map(TtuStatistics.fromJson)
          .toList();

  static String encodeList(List<TtuStatistics> stats) =>
      jsonEncode(stats.map((s) => s.toJson()).toList());
}

class TtuAudioBook {
  TtuAudioBook({
    required this.title,
    required this.playbackPositionSec,
    required this.lastAudioBookModified,
  });

  final String title;
  final double playbackPositionSec;
  final int lastAudioBookModified;

  // HBK-AUDIT-142: tolerant `as String?` fallback (see TtuStatistics.fromJson).
  factory TtuAudioBook.fromJson(Map<String, dynamic> json) => TtuAudioBook(
        title: json['title'] as String? ?? '',
        playbackPositionSec:
            (json['playbackPosition'] as num?)?.toDouble() ?? 0,
        lastAudioBookModified:
            (json['lastAudioBookModified'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'playbackPosition': playbackPositionSec,
        'lastAudioBookModified': lastAudioBookModified,
      };

  static TtuAudioBook decode(String source) =>
      TtuAudioBook.fromJson(jsonDecode(source) as Map<String, dynamic>);

  String encode() => jsonEncode(toJson());
}
