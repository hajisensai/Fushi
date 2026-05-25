import 'dart:convert';

/// ッツ Ebook Reader / Hoshi Reader 兼容的 Google Drive 同步数据模型。
///
/// JSON 字段名与 ッツ/Hoshi 格式一致，保证三方互通。

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

  factory TtuProgress.fromJson(Map<String, dynamic> json) => TtuProgress(
        dataId: json['dataId'] as int,
        exploredCharCount: json['exploredCharCount'] as int,
        progress: (json['progress'] as num).toDouble(),
        lastBookmarkModified: json['lastBookmarkModified'] as int,
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

  factory TtuStatistics.fromJson(Map<String, dynamic> json) => TtuStatistics(
        title: json['title'] as String,
        dateKey: json['dateKey'] as String,
        charactersRead: json['charactersRead'] as int,
        readingTimeSec: (json['readingTime'] as num).toDouble(),
        minReadingSpeed: json['minReadingSpeed'] as int,
        altMinReadingSpeed: json['altMinReadingSpeed'] as int,
        lastReadingSpeed: json['lastReadingSpeed'] as int,
        maxReadingSpeed: json['maxReadingSpeed'] as int,
        lastStatisticModified: json['lastStatisticModified'] as int,
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

  factory TtuAudioBook.fromJson(Map<String, dynamic> json) => TtuAudioBook(
        title: json['title'] as String,
        playbackPositionSec: (json['playbackPosition'] as num).toDouble(),
        lastAudioBookModified: json['lastAudioBookModified'] as int,
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

class DriveFile {
  const DriveFile({required this.id, required this.name});

  final String id;
  final String name;

  factory DriveFile.fromJson(Map<String, dynamic> json) => DriveFile(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}

class DriveSyncFiles {
  const DriveSyncFiles({this.progress, this.statistics, this.audioBook});

  final DriveFile? progress;
  final DriveFile? statistics;
  final DriveFile? audioBook;
}

enum SyncDirection { importFromTtu, exportToTtu, synced }

enum StatisticsSyncMode { merge, replace }

enum SyncResult {
  synced,
  imported,
  exported,
  skipped,
}
