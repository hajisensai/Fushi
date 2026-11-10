// 一张蓝光原盘入库成「盘合集」的唯一实现：来源库扫描器（app 侧
// `SourceLibraryScanner._importBlurayDiscs`）与视频下载流水线的导入阶段共用。
//
// 形状与 m3u8 清单完全同构（一张盘 = 一个 `playlist` 合集，一条标题 = 一行
// `VideoBooks`，成员 `videoPath` 是该标题自己的 `.mpls` 绝对路径），幂等性、墓碑
// 守卫、重扫对齐全部复用清单那套。两条入口曾经只有扫描器认盘：下载流水线把盘内
// 每个 m2ts 当一集视频，盘被拆散后连扫描器也认不出来了。

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_library_title.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart'
    show discRootForMemberPath;
import 'package:fushi_engine/media/video/m3u8_playlist.dart' show PlaylistEntry;
import 'package:fushi_engine/media/video/video_book_repository.dart';

/// 一张盘入库的结果。
class BlurayDiscImportOutcome {
  const BlurayDiscImportOutcome({
    required this.collectionId,
    required this.collectionName,
    required this.created,
    required this.titleUids,
  });

  /// 这张盘的 `playlist` 合集。
  final int collectionId;
  final String collectionName;

  /// 本次新建了合集（false = 已有合集，按当前标题表对齐了成员）。
  final bool created;

  /// 新建时各标题的库行 uid（按盘标题顺序）；对齐既有合集时为空。
  final List<String> titleUids;
}

/// 按盘批量入库：整批共用一次「合集名 → id」表与特典墓碑表。
class BlurayDiscLibraryImporter {
  BlurayDiscLibraryImporter._(
    this._db,
    this._repository,
    this._playlistCollectionIds,
    this._deletedExtras,
  );

  /// 读一次全库的 `playlist` 合集名与特典墓碑，供整批盘共用。
  static Future<BlurayDiscLibraryImporter> load(FushiDatabase db) async {
    return BlurayDiscLibraryImporter._(
      db,
      VideoBookRepository(db),
      <String, int>{
        for (final MediaCollectionRow c in await db.getAllMediaCollections())
          if (c.collectionType == 'playlist') c.name: c.id,
      },
      await deletedBlurayExtraKeysByCollection(db),
    );
  }

  final FushiDatabase _db;
  final VideoBookRepository _repository;
  final Map<String, int> _playlistCollectionIds;
  final Map<String, Set<String>> _deletedExtras;

  /// 把读好的 [disc] 入库：标题进盘合集，特典（菜单里的「特典映像」等）入库、
  /// 带来源、不进盘合集。
  ///
  /// 合集名不能只按盘名全局对号：`S1/DISC1` 与 `S2/DISC1` 同名不同盘，对到一起会
  /// 互相吞成员（见 [blurayCollectionNameCandidates]）。撞上别的盘 / 别的清单的
  /// 合集就换下一个候选名，直到找到本盘的或一个空位。
  ///
  /// 用户删过这张盘的合集（墓碑）且 [restoreDissolvedGroups] 为 false 时整张盘不
  /// 复活、特典也不入库（它们挂在这张盘的正片下，盘都删了特典没有归处），返回 null。
  Future<BlurayDiscImportOutcome?> importDisc(
    BlurayDisc disc, {
    int? sourceId,
    bool restoreDissolvedGroups = false,
  }) async {
    final List<PlaylistEntry> entries = <PlaylistEntry>[
      for (final BlurayTitle title in disc.titles)
        PlaylistEntry(title: title.name, path: title.playlistPath),
    ];

    String collectionName = disc.name;
    int? existingId;
    for (final String candidate in blurayCollectionNameCandidates(
      disc.name,
      disc.rootPath,
    )) {
      collectionName = candidate;
      existingId = _playlistCollectionIds[candidate];
      if (existingId == null) break;
      if (await collectionBelongsToDisc(_db, existingId, disc.rootPath)) break;
      existingId = null;
    }

    final BlurayDiscImportOutcome outcome;
    if (existingId != null) {
      await _repository.reconcileSplitPlaylist(
        collectionId: existingId,
        entries: entries,
        sourceId: sourceId,
      );
      outcome = BlurayDiscImportOutcome(
        collectionId: existingId,
        collectionName: collectionName,
        created: false,
        titleUids: const <String>[],
      );
    } else {
      // BUG-1739 同款守卫：用户删过同名合集，重扫不复活。
      if (!restoreDissolvedGroups &&
          await _db.hasCollectionDeletionTombstone(
            collectionName,
            'playlist',
          )) {
        return null;
      }
      final SplitPlaylistImportResult result = await _repository
          .importSplitPlaylist(
            collectionName: collectionName,
            entries: entries,
            sourceId: sourceId,
            reuseExistingPaths: true,
          );
      _playlistCollectionIds[collectionName] = result.collectionId;
      await _repository.recordVideoImportActivity(
        bookUid: result.episodeUids.first,
        title: collectionName,
      );
      outcome = BlurayDiscImportOutcome(
        collectionId: result.collectionId,
        collectionName: collectionName,
        created: true,
        titleUids: List<String>.unmodifiable(result.episodeUids),
      );
    }

    // 特典排在合集墓碑守卫之后，且跳过用户单独删掉的那几条（PR #2058 审查：原先
    // 排在守卫之前，删掉整盘合集后重扫特典照样复活）。盘已读好，整盘一次入库。
    final Set<String> deleted =
        _deletedExtras[collectionName] ?? const <String>{};
    final List<String> extras = <String>[
      for (final BlurayTitle extra in disc.extras)
        if (!deleted.contains(blurayExtraTombstoneKey(extra.playlistPath)))
          extra.playlistPath,
    ];
    if (extras.isNotEmpty) {
      await ensureBlurayDiscTitlesInLibrary(
        _db,
        discRoot: disc.rootPath,
        playlistPaths: extras,
        disc: disc,
        sourceId: sourceId,
      );
    }
    return outcome;
  }
}

/// 既有合集 [collectionId] 是不是 [discRootPath] 这张盘的：成员全是本盘的原盘标题
/// （蓝光 `BDMV/PLAYLIST/*.mpls` / DVD `VIDEO_TS/TITLE_nn.dvdtitle`，或还没有任何
/// 视频成员）才算；有任何一条来自别的盘、或根本不是原盘标题（同名 m3u8 清单合集），
/// 都不算。
Future<bool> collectionBelongsToDisc(
  FushiDatabase db,
  int collectionId,
  String discRootPath,
) async {
  final String root = p.normalize(discRootPath);
  for (final MediaCollectionItemRow item in await db.getCollectionItems(
    collectionId,
  )) {
    final VideoBookRow? row = await db.getVideoBookByBookUid(item.entryKey);
    if (row == null) continue;
    final String? owner = discRootForMemberPath(row.videoPath);
    if (owner == null || p.normalize(owner) != root) return false;
  }
  return true;
}
