/// 互联视频刮削元数据的 wire 形态（`docs/specs/2026-09-12-interconnect-scrape-metadata.md` §1）。
///
/// 只做「作品自然键 + 领域模型 JSON」的搬运，不含任何合并/换源语义——覆盖保护在
/// host 的 [VideoMetadataHost] 实现与 `VideoMetadataDatabaseStore.apply` 里。
library;

import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart'
    show VideoMetadataLookup;
import 'package:fushi_engine/media/video/metadata/video_metadata_wire.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataWork;

/// 作品自然键：合集级 `(name, collectionType)` 或单条目 `bookUid`。跨端唯一，不依赖
/// 自增 id（与 `CollectionManifestEntry` / `RemoteVideoInfo.id` 同域）。
class VideoMetadataWorkKey {
  const VideoMetadataWorkKey.collection({
    required String name,
    required this.collectionType,
  })  : collectionName = name,
        bookUid = null;

  const VideoMetadataWorkKey.book(String this.bookUid)
      : collectionName = null,
        collectionType = null;

  final String? collectionName;
  final String? collectionType;
  final String? bookUid;

  bool get isCollection => bookUid == null;

  Map<String, Object?> toJson() => isCollection
      ? <String, Object?>{
          'collection': <String, Object?>{
            'name': collectionName,
            'collectionType': collectionType,
          },
        }
      : <String, Object?>{'bookUid': bookUid};

  /// 缺键 / 形态不对抛 [FormatException]（端点回 400）。
  static VideoMetadataWorkKey fromJson(Object? json) {
    if (json is! Map) throw const FormatException('work key must be an object');
    final Object? bookUid = json['bookUid'];
    if (bookUid is String && bookUid.isNotEmpty) {
      return VideoMetadataWorkKey.book(bookUid);
    }
    final Object? collection = json['collection'];
    if (collection is Map) {
      final Object? name = collection['name'];
      final Object? type = collection['collectionType'];
      if (name is String && name.isNotEmpty && type is String) {
        return VideoMetadataWorkKey.collection(
            name: name, collectionType: type);
      }
    }
    throw const FormatException('work key needs bookUid or collection');
  }

  @override
  bool operator ==(Object other) =>
      other is VideoMetadataWorkKey &&
      other.collectionName == collectionName &&
      other.collectionType == collectionType &&
      other.bookUid == bookUid;

  @override
  int get hashCode => Object.hash(collectionName, collectionType, bookUid);

  @override
  String toString() => isCollection
      ? 'collection:$collectionName/$collectionType'
      : 'book:$bookUid';
}

/// 一个作品在 wire 上的完整形态。
class VideoMetadataWorkEntry {
  const VideoMetadataWorkEntry({
    required this.key,
    required this.updatedAt,
    required this.lockedFields,
    required this.lookup,
    required this.work,
  });

  final VideoMetadataWorkKey key;

  /// host `VideoMetadataWorks.updatedAt`（epoch 毫秒）；客户端据此判新旧。
  final int updatedAt;

  /// host 字段锁名单（只读镜像，客户端不据此加锁）。
  final List<String> lockedFields;

  /// host 已确认的主身份；无主身份为 null。
  final VideoMetadataLookup? lookup;

  final VideoMetadataWork work;

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key.toJson(),
        'updatedAt': updatedAt,
        'lockedFields': lockedFields,
        if (lookup != null) 'lookup': encodeVideoMetadataLookup(lookup!),
        'work': encodeVideoMetadataWork(work),
      };

  static VideoMetadataWorkEntry fromJson(Object? json) {
    if (json is! Map) throw const FormatException('entry must be an object');
    final Object? work = json['work'];
    if (work is! Map) throw const FormatException('entry.work missing');
    return VideoMetadataWorkEntry(
      key: VideoMetadataWorkKey.fromJson(json['key']),
      updatedAt: switch (json['updatedAt']) {
        final num v => v.toInt(),
        _ => 0,
      },
      lockedFields: <String>[
        if (json['lockedFields'] case final List<Object?> list)
          for (final Object? v in list)
            if (v is String) v,
      ],
      lookup: decodeVideoMetadataLookup(json['lookup']),
      work: decodeVideoMetadataWork(work.cast<String, Object?>()),
    );
  }
}

/// 远程候选（7a）：host 跑 `searchManualCandidates` 的一条结果。
class VideoMetadataCandidateEntry {
  const VideoMetadataCandidateEntry({required this.lookup, required this.work});

  final VideoMetadataLookup lookup;
  final VideoMetadataWork work;

  Map<String, Object?> toJson() => <String, Object?>{
        'lookup': encodeVideoMetadataLookup(lookup),
        'work': encodeVideoMetadataWork(work),
      };

  static VideoMetadataCandidateEntry fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('candidate must be an object');
    }
    final VideoMetadataLookup? lookup =
        decodeVideoMetadataLookup(json['lookup']);
    final Object? work = json['work'];
    if (lookup == null || work is! Map) {
      throw const FormatException('candidate needs lookup and work');
    }
    return VideoMetadataCandidateEntry(
      lookup: lookup,
      work: decodeVideoMetadataWork(work.cast<String, Object?>()),
    );
  }
}

/// host 对 7a / 7b 请求的三种可解释拒绝（端点回 409，body 带 `conflict`）。
enum VideoMetadataConflict {
  /// 一个合集在计划器里对应多个 `book:<uid>` 作品单元（BUG-2433），客户端须让
  /// 用户选后带 `bookUid` 重发。`works` 列出候选单元键。
  ambiguousWork,

  /// host 已有与入站不同的主身份，且请求未带 `replaceIdentity: true`
  /// （手动指定 ID 不静默换源）。`current` 为 host 现身份。
  identity,

  /// 作品在 host 上没有可刮削的本地来源（成员全是远端占位 / 来源已删）。
  notPlanned,

  /// host 跑了刮削链但失败（provider 挂 / 封禁 / 候选被类型门拒 / 资料清理中），
  /// 库里没有新资料。
  scrapeFailed,
}

/// [VideoMetadataHost] 写操作的结果：成功带 entry；拒绝带 conflict + 附加信息。
class VideoMetadataWriteResult {
  const VideoMetadataWriteResult.ok(VideoMetadataWorkEntry this.entry)
      : conflict = null,
        currentLookup = null,
        ambiguousWorks = const <VideoMetadataWorkKey>[];

  const VideoMetadataWriteResult.conflict(
    VideoMetadataConflict this.conflict, {
    this.currentLookup,
    this.ambiguousWorks = const <VideoMetadataWorkKey>[],
  }) : entry = null;

  final VideoMetadataWorkEntry? entry;
  final VideoMetadataConflict? conflict;
  final VideoMetadataLookup? currentLookup;
  final List<VideoMetadataWorkKey> ambiguousWorks;

  bool get isOk => conflict == null;

  Map<String, Object?> toJson() => isOk
      ? <String, Object?>{'ok': true, 'entry': entry!.toJson()}
      : <String, Object?>{
          'ok': false,
          'conflict': conflict!.name,
          if (currentLookup != null)
            'current': encodeVideoMetadataLookup(currentLookup!),
          if (ambiguousWorks.isNotEmpty)
            'works': <Object?>[
              for (final VideoMetadataWorkKey k in ambiguousWorks) k.toJson(),
            ],
        };

  static VideoMetadataWriteResult fromJson(Object? json) {
    if (json is! Map) throw const FormatException('result must be an object');
    if (json['ok'] == true) {
      return VideoMetadataWriteResult.ok(
        VideoMetadataWorkEntry.fromJson(json['entry']),
      );
    }
    final VideoMetadataConflict? conflict =
        VideoMetadataConflict.values.asNameMap()[json['conflict']];
    if (conflict == null) {
      throw FormatException('unknown conflict ${json['conflict']}');
    }
    return VideoMetadataWriteResult.conflict(
      conflict,
      currentLookup: decodeVideoMetadataLookup(json['current']),
      ambiguousWorks: <VideoMetadataWorkKey>[
        if (json['works'] case final List<Object?> list)
          for (final Object? v in list) VideoMetadataWorkKey.fromJson(v),
      ],
    );
  }
}
