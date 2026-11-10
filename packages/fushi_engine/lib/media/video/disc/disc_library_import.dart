// 原盘（蓝光文件夹 / DVD 文件夹 / DVD 镜像）入库的唯一实现。
//
// 一张盘 = 一个 `playlist` 合集（合集名取盘名，撞上别的盘 / 别的清单的同名合集换
// [blurayCollectionNameCandidates] 的下一个候选），一条入选标题 = 一行 `VideoBooks`
// （蓝光 `videoPath` 是真实的 `.mpls`，DVD 是虚拟的 `VIDEO_TS/TITLE_nn.dvdtitle`）；
// 特典入库、带来源、不进盘合集。重扫按合集名找回本盘合集并对齐成员，用户删过的合集
// （墓碑）不复活。
//
// 来源扫描器（`SourceLibraryScanner`）与下载流水线（BUG-4245：下载整理后的原盘入库）
// 共用这一份——两边建出来的合集与库行必须逐字节一致，否则同一张盘先被下载入库、
// 再被扫描器重扫时会对出两份合集。盘面图（封面写入走 app 层服务）由调用方经
// [DiscCollectionReadyHook] 接，引擎不碰。

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_library_title.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart'
    show discRootForMemberPath;
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart';
import 'package:fushi_engine/media/video/dvd/dvd_library_title.dart';
import 'package:fushi_engine/media/video/dvd/dvd_ifo.dart'
    show DvdIfoFormatException;
import 'package:fushi_engine/media/video/m3u8_playlist.dart' show PlaylistEntry;
import 'package:fushi_engine/media/video/video_book_repository.dart';

/// 一张盘的合集就绪（新建或重扫对齐）后调用：盘根 + 合集 id。扫描器在这里补盘面图。
typedef DiscCollectionReadyHook =
    Future<void> Function(int collectionId, String discRootPath);

/// 一张已入库的盘。
class DiscLibraryImportedDisc {
  const DiscLibraryImportedDisc({
    required this.rootPath,
    required this.name,
    required this.collectionId,
    required this.titlePaths,
    required this.created,
  });

  /// 读盘得到的盘根（文件夹形态含 `BDMV` / `VIDEO_TS`；镜像是 `.iso` 本身）。
  final String rootPath;

  /// 合集名（盘名或其消歧候选）。
  final String name;

  final int collectionId;

  /// 盘合集成员（入选标题）的 `videoPath`，按盘上的标题顺序。
  final List<String> titlePaths;

  /// 本次新建了合集（而不是对齐既有合集）。
  final bool created;
}

/// 一批盘的入库结果。
class DiscLibraryImportReport {
  const DiscLibraryImportReport({
    required this.imported,
    required this.discs,
    this.failed = const <String>[],
    this.unreadable = const <String>[],
  });

  /// 新建了合集的盘数（重扫对齐不计）。
  final int imported;

  /// 入了库（新建或对齐）的盘，按入库顺序。
  final List<DiscLibraryImportedDisc> discs;

  /// IFO 损坏的 DVD（`<盘名> — <原因>`），不中断其它盘。
  final List<String> failed;

  /// 读不出盘 / 一条标题都选不出来的盘根（半张盘、BD 镜像、数据镜像）。不是错误：
  /// 盘文件原样在盘上，只是不进库。
  final List<String> unreadable;
}

/// 原盘入库器（扫描器与下载流水线共用）。
class DiscLibraryImporter {
  DiscLibraryImporter(this._db) : _videoRepo = VideoBookRepository(_db);

  final FushiDatabase _db;
  final VideoBookRepository _videoRepo;

  /// 把 [discRoots] 里的蓝光盘导入成合集。
  ///
  /// 每条标题的 `videoPath` 是它自己的 `.mpls` 绝对路径——一个真实存在的文件，于是
  /// 「文件还在不在」「这路径被谁引用着」这些既有判据原样可用，不需要为 BD 另开一套。
  ///
  /// [restoreDissolvedGroups]：用户删过同名合集时是否仍重建（扫描器的「恢复已解散
  /// 分组」开关；下载流水线恒为 true——用户刚下载了这张盘，就是入库的明确意图）。
  Future<DiscLibraryImportReport> importBlurayDiscs(
    List<String> discRoots, {
    required int? sourceId,
    required bool restoreDissolvedGroups,
    DiscCollectionReadyHook? onCollectionReady,
  }) async {
    if (discRoots.isEmpty) {
      return const DiscLibraryImportReport(
        imported: 0,
        discs: <DiscLibraryImportedDisc>[],
      );
    }
    final Map<String, int> existingCollectionIds = await _playlistCollections();
    // 用户单独删掉的特典：挂在盘合集自然键下的成员墓碑（见
    // [planBlurayExtraDeletionTombstones]）。整轮一次查询。
    final Map<String, Set<String>> deletedExtras =
        await deletedBlurayExtraKeysByCollection(_db);

    int count = 0;
    final List<DiscLibraryImportedDisc> imported = <DiscLibraryImportedDisc>[];
    final List<String> unreadable = <String>[];
    for (final String root in discRoots) {
      final BlurayDisc? disc = await readBlurayDisc(root);
      // 半张盘 / 一条标题都选不出来：跳过而不是记错。盘里的文件已经在规划层被摘出
      // 散装视频，这里再报错只会把整次扫描标红。
      if (disc == null) {
        unreadable.add(root);
        continue;
      }
      final List<PlaylistEntry> entries = <PlaylistEntry>[
        for (final BlurayTitle title in disc.titles)
          PlaylistEntry(title: title.name, path: title.playlistPath),
      ];
      final _DiscCollection? collection = await _importDiscCollection(
        discName: disc.name,
        discRootPath: disc.rootPath,
        entries: entries,
        sourceId: sourceId,
        restoreDissolvedGroups: restoreDissolvedGroups,
        existingCollectionIds: existingCollectionIds,
      );
      if (collection == null) continue;
      if (collection.created) count++;
      await onCollectionReady?.call(collection.id, disc.rootPath);

      // 特典（菜单里的「特典映像」等）入库、带来源，但不进盘合集：索引器随后把它们
      // 挂到正片作品下，作品资料页的特典区就能看到、点开就播。排在合集墓碑守卫
      // 之后，且跳过用户单独删掉的那几条（PR #2058 审查：原先排在守卫之前，删掉
      // 整盘合集后重扫特典照样复活）。盘已读好，整盘一次入库。
      final Set<String> deleted =
          deletedExtras[collection.name] ?? const <String>{};
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
      imported.add(
        DiscLibraryImportedDisc(
          rootPath: disc.rootPath,
          name: collection.name,
          collectionId: collection.id,
          titlePaths: <String>[
            for (final PlaylistEntry entry in entries) entry.path,
          ],
          created: collection.created,
        ),
      );
    }
    return DiscLibraryImportReport(
      imported: count,
      discs: List<DiscLibraryImportedDisc>.unmodifiable(imported),
      unreadable: List<String>.unmodifiable(unreadable),
    );
  }

  /// 把 [discRoots] 里的 DVD（文件夹盘根或 `.iso` 镜像）导入成合集，与
  /// [importBlurayDiscs] 同构。成员路径是虚拟的 `VIDEO_TS/TITLE_nn.dvdtitle`。
  ///
  /// 多张盘先全部读完，再按 [compareDvdDiscOrder]（同一上级目录内按卷号，再按目录名）
  /// 排序后入库，入库时刻顺序就是盘序。IFO 损坏的盘记进 `failed`，不中断其它盘。
  ///
  /// `.iso` 镜像经 `readDvdDiscImage` 读出同样的 IFO 字节、走同一条选片链；镜像里是
  /// BD 的暂不入库（记进 `unreadable`）：蓝光的播放 / 规格 / 封面 / 制卡链路全部建立
  /// 在真实的 `STREAM/*.m2ts` 文件上（EDL 拼接），镜像里没有可给出的本地文件，要等
  /// 原生 libbluray 直接吃镜像那一路接上。
  Future<DiscLibraryImportReport> importDvdDiscs(
    List<String> discRoots, {
    required int? sourceId,
    required bool restoreDissolvedGroups,
    DiscCollectionReadyHook? onCollectionReady,
  }) async {
    if (discRoots.isEmpty) {
      return const DiscLibraryImportReport(
        imported: 0,
        discs: <DiscLibraryImportedDisc>[],
      );
    }
    final List<DvdDisc> discs = <DvdDisc>[];
    final List<String> failed = <String>[];
    final List<String> unreadable = <String>[];
    for (final String root in discRoots) {
      try {
        final DvdDisc? disc = await readDvdDisc(root);
        if (disc != null) {
          discs.add(disc);
        } else {
          unreadable.add(root);
        }
      } on DvdIfoFormatException catch (e) {
        failed.add('${p.basename(root)} — ${e.message}');
      }
    }
    discs.sort(compareDvdDiscOrder);

    final Map<String, Set<String>> deletedExtras =
        await deletedBlurayExtraKeysByCollection(_db);
    final Map<String, int> existingCollectionIds = await _playlistCollections();
    int count = 0;
    final List<DiscLibraryImportedDisc> imported = <DiscLibraryImportedDisc>[];
    for (final DvdDisc disc in discs) {
      final List<PlaylistEntry> entries = <PlaylistEntry>[
        for (final DvdTitle title in disc.titles)
          PlaylistEntry(title: title.name, path: title.titlePath),
      ];
      final _DiscCollection? collection = await _importDiscCollection(
        discName: disc.name,
        discRootPath: disc.rootPath,
        entries: entries,
        sourceId: sourceId,
        restoreDissolvedGroups: restoreDissolvedGroups,
        existingCollectionIds: existingCollectionIds,
      );
      if (collection == null) continue;
      if (collection.created) count++;
      await onCollectionReady?.call(collection.id, disc.rootPath);

      final Set<String> deleted =
          deletedExtras[collection.name] ?? const <String>{};
      final List<String> extras = <String>[
        for (final DvdTitle extra in disc.extras)
          if (!deleted.contains(blurayExtraTombstoneKey(extra.titlePath)))
            extra.titlePath,
      ];
      if (extras.isNotEmpty) {
        await ensureDvdDiscExtrasInLibrary(
          _db,
          disc: disc,
          titlePaths: extras,
          sourceId: sourceId,
        );
      }
      imported.add(
        DiscLibraryImportedDisc(
          rootPath: disc.rootPath,
          name: collection.name,
          collectionId: collection.id,
          titlePaths: <String>[
            for (final PlaylistEntry entry in entries) entry.path,
          ],
          created: collection.created,
        ),
      );
    }
    return DiscLibraryImportReport(
      imported: count,
      discs: List<DiscLibraryImportedDisc>.unmodifiable(imported),
      failed: List<String>.unmodifiable(failed),
      unreadable: List<String>.unmodifiable(unreadable),
    );
  }

  Future<Map<String, int>> _playlistCollections() async => <String, int>{
    for (final MediaCollectionRow c in await _db.getAllMediaCollections())
      if (c.collectionType == 'playlist') c.name: c.id,
  };

  /// 一张盘的合集：找回本盘的既有合集并对齐成员，或新建；用户删过同名合集（墓碑）
  /// 且不恢复时返回 null（整张盘都不复活，特典也不例外——它们挂在这张盘的正片下，
  /// 盘都删了特典没有归处）。
  ///
  /// 合集名不能只按盘名全局对号：`S1/DISC1` 与 `S2/DISC1` 同名不同盘，对到一起会
  /// 互相吞成员（见 [blurayCollectionNameCandidates]）。撞上别的盘 / 别的清单的合集
  /// 就换下一个候选名，直到找到本盘的或一个空位。
  Future<_DiscCollection?> _importDiscCollection({
    required String discName,
    required String discRootPath,
    required List<PlaylistEntry> entries,
    required int? sourceId,
    required bool restoreDissolvedGroups,
    required Map<String, int> existingCollectionIds,
  }) async {
    String collectionName = discName;
    int? existingId;
    for (final String candidate in blurayCollectionNameCandidates(
      discName,
      discRootPath,
    )) {
      collectionName = candidate;
      existingId = existingCollectionIds[candidate];
      if (existingId == null) break;
      if (await _collectionBelongsToDisc(existingId, discRootPath)) break;
      existingId = null;
    }
    if (existingId != null) {
      await _videoRepo.reconcileSplitPlaylist(
        collectionId: existingId,
        entries: entries,
        sourceId: sourceId,
      );
      return _DiscCollection(
        id: existingId,
        name: collectionName,
        created: false,
      );
    }
    // BUG-1739 同款守卫：用户删过同名合集，重扫不复活。
    if (!restoreDissolvedGroups &&
        await _db.hasCollectionDeletionTombstone(collectionName, 'playlist')) {
      return null;
    }
    final SplitPlaylistImportResult result = await _videoRepo
        .importSplitPlaylist(
          collectionName: collectionName,
          entries: entries,
          sourceId: sourceId,
          reuseExistingPaths: true,
        );
    existingCollectionIds[collectionName] = result.collectionId;
    await _videoRepo.recordVideoImportActivity(
      bookUid: result.episodeUids.first,
      title: collectionName,
    );
    return _DiscCollection(
      id: result.collectionId,
      name: collectionName,
      created: true,
    );
  }

  /// 既有合集 [collectionId] 是不是 [discRootPath] 这张盘的：成员全是本盘的原盘标题
  /// （蓝光 `BDMV/PLAYLIST/*.mpls` / DVD `VIDEO_TS/TITLE_nn.dvdtitle`，或还没有任何
  /// 视频成员）才算；有任何一条来自别的盘、或根本不是原盘标题（同名 m3u8 清单合集），
  /// 都不算。
  Future<bool> _collectionBelongsToDisc(
    int collectionId,
    String discRootPath,
  ) async {
    final String root = p.normalize(discRootPath);
    for (final MediaCollectionItemRow item in await _db.getCollectionItems(
      collectionId,
    )) {
      final VideoBookRow? row = await _videoRepo.getByBookUid(item.entryKey);
      if (row == null) continue;
      final String? owner = discRootForMemberPath(row.videoPath);
      if (owner == null || p.normalize(owner) != root) return false;
    }
    return true;
  }
}

class _DiscCollection {
  const _DiscCollection({
    required this.id,
    required this.name,
    required this.created,
  });

  final int id;
  final String name;
  final bool created;
}
