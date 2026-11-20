/// 把视频文件在「作品单元」之间挪动：从一部作品里拆出来、并进另一部、几个文件
/// 另组一部（所有者 2026-11-20：「很多合集里面的第 0 季，并不是第 0 季，甚至可能是
/// 电影」）。
///
/// **作品单元由合集成员关系决定，不由文件在磁盘上的位置决定**
/// （[VideoSourceWorkPlanner]：成员数 ≥2 的非目录合集 = 一部剧集 `collection:<id>`，
/// 其余文件各自是 `book:<uid>`）。所以「电影被挂成某部剧的第 0 季」的修法不是搬
/// 文件——搬完重扫，文件还在原合集里、还是那部剧的一集——而是把它移出那个合集，
/// 让它成为独立的作品单元，再按电影识别。
///
/// 一次挪动同时做三件事（同一个事务）：
/// 1. 合集成员关系：移出原作品合集（写成员墓碑，重扫不再按文件名并回去）、加入
///    目标合集（如有）；
/// 2. 原作品里绑着这个文件的分集行解绑（否则原作品的「第 0 季第 1 集」还指着它）；
/// 3. 清掉这个文件的手动季集指定（那是相对原作品的季集号）。
///
/// 纯 Dart（不 import flutter / 插件 / `package:fushi`）。
library;

import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/scraper/collection_member_policy.dart'
    show multiMemberCollectionIdByVideoUid;

/// 挪到哪里。
sealed class VideoRegroupTarget {
  const VideoRegroupTarget();
}

/// 各自成为独立作品单元（`book:<uid>`）。
class VideoRegroupStandalone extends VideoRegroupTarget {
  const VideoRegroupStandalone();
}

/// 这几个文件另组一部作品（新建播放列表合集；同名合集已存在就并进去）。
class VideoRegroupNewWork extends VideoRegroupTarget {
  const VideoRegroupNewWork(this.name);

  final String name;
}

/// 并进已有的作品合集。
class VideoRegroupExistingWork extends VideoRegroupTarget {
  const VideoRegroupExistingWork(this.collectionId);

  final int collectionId;
}

/// 挪不了（整次不执行）。[code] 是给调用方分支用的短码。
class VideoRegroupRejected implements Exception {
  const VideoRegroupRejected(this.code, this.message);

  /// `no_items` / `unknown_file` / `unknown_collection` / `folder_collection` /
  /// `bad_name` / `would_empty_work`。
  final String code;
  final String message;

  @override
  String toString() => 'VideoRegroupRejected($code): $message';
}

/// 一次挪动的结论。
class VideoRegroupResult {
  const VideoRegroupResult({
    required this.moved,
    required this.skipped,
    required this.targetCollectionId,
    required this.createdTarget,
    required this.undo,
  });

  /// 实际挪动的文件：`uid`、`title`、`from`（原作品 id 或 null）、`to`（现在所属的
  /// 作品 id）。
  final List<Map<String, Object?>> moved;

  /// 没动的文件与原因：`unchanged`（已经在目标位置）、`pinned_by_user`（用户亲手
  /// 放进那个合集的成员，自动路径不移出）。
  final List<Map<String, Object?>> skipped;
  final int? targetCollectionId;
  final bool createdTarget;

  /// 撤销载荷（只有 id 与数字，不含路径）；什么都没挪时为 null。
  final Map<String, Object?>? undo;
}

/// 撤销的结论。
typedef VideoRegroupRevert = ({int reverted, int superseded, int failed});

String _bookKey(String uid) => 'book:$uid';
String _collectionKey(int id) => 'collection:$id';

/// 全库的「视频 uid → 所属作品合集 id」（与 [VideoSourceWorkPlanner] 同一口径：
/// 目录合集不算，成员数 ≥2 才算）。
Future<Map<String, int>> primaryVideoWorkCollections(FushiDatabase db) async {
  final Set<int> folderCollections = <int>{
    for (final MediaCollectionRow c in await db.getAllMediaCollections())
      if (c.sourceFolderPath != null) c.id,
  };
  return multiMemberCollectionIdByVideoUid(<MediaCollectionItemRow>[
    for (final MediaCollectionItemRow item in await db.getAllCollectionItems())
      if (!folderCollections.contains(item.collectionId)) item,
  ]);
}

Map<String, Object?> _episodeSnapshot(VideoMetadataEpisodeRow row) =>
    <String, Object?>{
      'id': row.id,
      'anidbEpisodeId': row.anidbEpisodeId,
      'anidbEpisodeNumber': row.anidbEpisodeNumber,
      'anidbMatchRating': row.anidbMatchRating,
    };

/// 把 [bookUids] 挪到 [target]。
Future<VideoRegroupResult> regroupVideoFiles(
  FushiDatabase db, {
  required List<String> bookUids,
  required VideoRegroupTarget target,
}) => db.transaction(() async {
  final List<String> uids = bookUids.toSet().toList();
  if (uids.isEmpty) {
    throw const VideoRegroupRejected('no_items', '没有给要挪动的视频');
  }
  final Map<String, VideoBookRow> books = <String, VideoBookRow>{};
  for (final String uid in uids) {
    final VideoBookRow? row = await db.getVideoBookByBookUid(uid);
    if (row == null) {
      throw VideoRegroupRejected('unknown_file', '没有这个视频：$uid');
    }
    books[uid] = row;
  }

  int? targetId;
  bool created = false;
  String? newName;
  switch (target) {
    case VideoRegroupStandalone():
      break;
    case VideoRegroupExistingWork(:final int collectionId):
      final MediaCollectionRow? c = await db.getMediaCollectionById(
        collectionId,
      );
      if (c == null) {
        throw VideoRegroupRejected(
          'unknown_collection',
          '没有这个合集：$collectionId',
        );
      }
      if (c.sourceFolderPath != null) {
        throw const VideoRegroupRejected(
          'folder_collection',
          '目录合集按磁盘目录组织，不是作品，不能作为挪动目标',
        );
      }
      targetId = collectionId;
    case VideoRegroupNewWork(:final String name):
      newName = name.trim();
      if (newName.isEmpty) {
        throw const VideoRegroupRejected('bad_name', '新作品需要一个名字');
      }
      final MediaCollectionRow? existing = await db
          .getMediaCollectionByNaturalKey(newName, 'playlist');
      if (existing != null) {
        if (existing.sourceFolderPath != null) {
          throw const VideoRegroupRejected(
            'folder_collection',
            '同名合集是目录合集，换一个名字',
          );
        }
        targetId = existing.id;
      }
  }

  final Map<String, int> primary = await primaryVideoWorkCollections(db);
  final List<Map<String, Object?>> skipped = <Map<String, Object?>>[];
  final List<(String uid, int? from, MediaCollectionItemRow? row)> plan =
      <(String, int?, MediaCollectionItemRow?)>[];
  final Map<int, int> leaving = <int, int>{};
  for (final String uid in uids) {
    final int? from = primary[uid];
    final bool alreadyThere = target is VideoRegroupStandalone
        ? from == null
        : targetId != null && from == targetId;
    if (alreadyThere) {
      skipped.add(<String, Object?>{'uid': uid, 'reason': 'unchanged'});
      continue;
    }
    MediaCollectionItemRow? row;
    if (from != null) {
      for (final MediaCollectionItemRow item in await db.getCollectionItems(
        from,
      )) {
        if (item.mediaType == MediaKind.video.dbValue && item.entryKey == uid) {
          row = item;
        }
      }
      if (row != null && row.pinnedByUser) {
        skipped.add(<String, Object?>{'uid': uid, 'reason': 'pinned_by_user'});
        continue;
      }
      leaving[from] = (leaving[from] ?? 0) + 1;
    }
    plan.add((uid, from, row));
  }
  for (final MapEntry<int, int> e in leaving.entries) {
    final int total = (await db.getCollectionItems(e.key)).length;
    if (e.value >= total) {
      final MediaCollectionRow? c = await db.getMediaCollectionById(e.key);
      throw VideoRegroupRejected(
        'would_empty_work',
        '这会把《${c?.name ?? e.key}》的成员全部挪走（空合集会被删除）。整部作品'
            '认错了就直接重新识别这部作品，不用拆',
      );
    }
  }
  if (plan.isEmpty) {
    return VideoRegroupResult(
      moved: const <Map<String, Object?>>[],
      skipped: skipped,
      targetCollectionId: targetId,
      createdTarget: false,
      undo: null,
    );
  }

  if (targetId == null && newName != null) {
    targetId = await db.createMediaCollection(
      newName,
      collectionType: 'playlist',
      origin: CollectionOrigin.ai,
    );
    created = true;
  }

  final int now = DateTime.now().millisecondsSinceEpoch;
  final List<Map<String, Object?>> undoItems = <Map<String, Object?>>[];
  for (final (String uid, int? from, MediaCollectionItemRow? row) in plan) {
    final VideoEpisodeBindingOverrideRow? pin = await db
        .getVideoEpisodeBindingOverride(uid);
    final List<VideoMetadataEpisodeRow> bound = await db
        .getVideoMetadataEpisodesByBook(uid);
    undoItems.add(<String, Object?>{
      'uid': uid,
      'from': from,
      'sortIndex': row?.sortIndex,
      'override': pin == null
          ? null
          : <String, Object?>{
              'season': pin.seasonNumber,
              'episode': pin.episodeNumber,
            },
      'episodes': <Map<String, Object?>>[
        for (final VideoMetadataEpisodeRow e in bound) _episodeSnapshot(e),
      ],
    });
    if (from != null) {
      await db.removeFromCollectionRaw(
        from,
        MediaKind.video.dbValue,
        uid,
        userIntent: false,
      );
    }
    for (final VideoMetadataEpisodeRow e in bound) {
      await (db.update(
        db.videoMetadataEpisodes,
      )..where((tbl) => tbl.id.equals(e.id))).write(
        VideoMetadataEpisodesCompanion(
          bookUid: const Value<String?>(null),
          anidbEpisodeId: const Value<int?>(null),
          anidbEpisodeNumber: const Value<String?>(null),
          anidbMatchRating: const Value<String?>(null),
          updatedAt: Value<int>(now),
        ),
      );
    }
    if (pin != null) await db.clearVideoEpisodeBindingOverride(uid);
    if (targetId != null) {
      await db.addToCollection(
        targetId,
        MediaKind.video,
        uid,
        userIntent: false,
      );
    }
  }

  final Map<String, int> after = await primaryVideoWorkCollections(db);
  db.notifyVideoLibraryChanged();
  return VideoRegroupResult(
    moved: <Map<String, Object?>>[
      for (final (String uid, int? from, MediaCollectionItemRow? _) in plan)
        <String, Object?>{
          'uid': uid,
          'title': books[uid]!.title,
          'from': from == null ? _bookKey(uid) : _collectionKey(from),
          'to': after[uid] == null
              ? _bookKey(uid)
              : _collectionKey(after[uid]!),
        },
    ],
    skipped: skipped,
    targetCollectionId: targetId,
    createdTarget: created,
    undo: <String, Object?>{'target': targetId, 'items': undoItems},
  );
});

/// 按 [regroupVideoFiles] 给的撤销载荷挪回去。逐文件判断：
/// - 文件已不在这次挪到的位置（用户之后又挪过）→ superseded，保留现状；
/// - 原作品合集已不存在 → failed，保留现状；
/// - 其余：移出目标合集（挪空的新建合集随之删除）、放回原合集的原位置、把当时解绑
///   的分集行绑回来（之后已被别的文件占用的行不抢）、恢复手动季集指定。
Future<VideoRegroupRevert> revertVideoRegroup(
  FushiDatabase db,
  Object? payload,
) => db.transaction(() async {
  if (payload is! Map || payload['items'] is! List) {
    return (reverted: 0, superseded: 0, failed: 1);
  }
  final int? target = (payload['target'] as num?)?.toInt();
  int reverted = 0;
  int superseded = 0;
  int failed = 0;
  final int now = DateTime.now().millisecondsSinceEpoch;

  Future<bool> isMember(int collectionId, String uid) async =>
      (await db.getCollectionItems(collectionId)).any(
        (MediaCollectionItemRow item) =>
            item.mediaType == MediaKind.video.dbValue && item.entryKey == uid,
      );

  for (final Object? raw in payload['items'] as List) {
    if (raw is! Map || raw['uid'] is! String) {
      failed++;
      continue;
    }
    final String uid = raw['uid'] as String;
    final int? from = (raw['from'] as num?)?.toInt();
    if (await db.getVideoBookByBookUid(uid) == null) {
      superseded++;
      continue;
    }
    final bool backAlready = from != null && await isMember(from, uid);
    final bool stillAtTarget = target == null
        ? !backAlready
        : await isMember(target, uid);
    if (!stillAtTarget) {
      superseded++;
      continue;
    }
    if (from != null && await db.getMediaCollectionById(from) == null) {
      failed++;
      continue;
    }
    if (target != null) {
      await db.removeFromCollectionRaw(
        target,
        MediaKind.video.dbValue,
        uid,
        userIntent: false,
      );
    }
    if (from != null && !backAlready) {
      await db.addToCollectionRaw(
        from,
        MediaKind.video.dbValue,
        uid,
        userIntent: false,
        pinnedByUser: false,
      );
      final int? sortIndex = (raw['sortIndex'] as num?)?.toInt();
      if (sortIndex != null) {
        await (db.update(db.mediaCollectionItems)..where(
              (tbl) =>
                  tbl.collectionId.equals(from) &
                  tbl.mediaType.equals(MediaKind.video.dbValue) &
                  tbl.entryKey.equals(uid),
            ))
            .write(MediaCollectionItemsCompanion(sortIndex: Value(sortIndex)));
      }
    }
    final Object? episodes = raw['episodes'];
    if (episodes is List) {
      for (final Object? e in episodes) {
        if (e is! Map || e['id'] is! num) continue;
        // 只绑回仍然空着的行：之后的刮削可能已经把别的文件绑到这一集上。
        await (db.update(db.videoMetadataEpisodes)..where(
              (tbl) =>
                  tbl.id.equals((e['id'] as num).toInt()) &
                  tbl.bookUid.isNull(),
            ))
            .write(
              VideoMetadataEpisodesCompanion(
                bookUid: Value<String?>(uid),
                anidbEpisodeId: Value<int?>(
                  (e['anidbEpisodeId'] as num?)?.toInt(),
                ),
                anidbEpisodeNumber: Value<String?>(
                  e['anidbEpisodeNumber'] as String?,
                ),
                anidbMatchRating: Value<String?>(
                  e['anidbMatchRating'] as String?,
                ),
                updatedAt: Value<int>(now),
              ),
            );
      }
    }
    final Object? pin = raw['override'];
    if (pin is Map &&
        pin['season'] is num &&
        pin['episode'] is num &&
        await db.getVideoEpisodeBindingOverride(uid) == null) {
      await db.setVideoEpisodeBindingOverride(
        uid,
        seasonNumber: (pin['season'] as num).toInt(),
        episodeNumber: (pin['episode'] as num).toInt(),
      );
    }
    reverted++;
  }
  if (reverted > 0) db.notifyVideoLibraryChanged();
  return (reverted: reverted, superseded: superseded, failed: failed);
});
