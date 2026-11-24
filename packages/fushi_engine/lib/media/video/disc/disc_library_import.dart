// 原盘（蓝光文件夹 / DVD 文件夹 / DVD 镜像）入库的唯一实现。
//
// 一张盘 = 一个 `playlist` 合集（合集名取盘名，撞上别的盘 / 别的清单的同名合集换
// [blurayCollectionNameCandidates] 的下一个候选），一条入选标题 = 一行 `VideoBooks`
// （蓝光 `videoPath` 是真实的 `.mpls`，DVD 是虚拟的 `VIDEO_TS/TITLE_nn.dvdtitle`）；
// 只有「全部播放」的蓝光剧集盘按 PlayItem 切成各集（成员是虚拟的分集路径
// `00001.p03.mpls`，`bluray_episode.dart`），同一发布的几张这样的盘并进**一个**合集、
// 成员按盘序 × 盘内集序排（`disc_release_set.dart`）；
// 特典入库、带来源、不进盘合集。
//
// 合集的身份是确定性的整理分组键（[blurayReleaseSetOrganizeKey] / [discOrganizeKey]，
// 只由发布目录名、作品名 / 盘目录名决定），不是合集名：新建的原盘合集 `origin = rule`
// 带着键，用户改名、被 AI 整理并进别的合集（键进别名）之后重扫照样按键认回
// （`collectionHoldingOrganizeKey`，与整理收敛同一判据）；修前建的无键合集按成员重叠
// 认领一次并挂上键（[_adoptableCollection]）。重扫对齐只往合集里加；要移出的成员
// （特典、不再是正片的标题、被发布组合集取代的单盘合集），整理器管着的合集直接移出、
// 用户的合集记成库管家的待确认建议（用户 2026-11-24 拍板：「用户的合集整理器永远不能
// 往外移成员 取消这个设定吧，我觉得让用户显式同意就行了吧，用户可以永远拒绝」）。
// 用户删过的合集（墓碑 / 被拒绝的分组键）不复活。
//
// 来源扫描器（`SourceLibraryScanner`）与下载流水线（BUG-4245：下载整理后的原盘入库）
// 共用这一份——两边建出来的合集与库行必须逐字节一致，否则同一张盘先被下载入库、
// 再被扫描器重扫时会对出两份合集。盘面图（封面写入走 app 层服务）由调用方经
// [DiscCollectionReadyHook] 接，引擎不碰。

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart'
    show recordMemberRemovalProposals;
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart'
    show
        MemberRemovalProposal,
        kMemberRemovalReasonDiscExtra,
        kMemberRemovalReasonDiscStale,
        kMemberRemovalReasonDiscSuperseded;
import 'package:fushi_engine/media/collections/library_organize/organize_convergence.dart'
    show collectionHoldingOrganizeKey, kConvergenceOverlapRatio;
import 'package:fushi_engine/media/collections/collection_season_groups.dart'
    show discEpisodeOrdinalsOf;
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:fushi_engine/media/media_extensions.dart'
    show isAudioOnlyMediaPath;
import 'package:fushi_engine/media/video/video_filename_parser.dart'
    show VideoNameInfo, parseVideoPath;
import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_episode.dart';
import 'package:fushi_engine/media/video/bluray/bluray_library_title.dart';
import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart'
    show isBlurayPlaylistPath;
import 'package:fushi_engine/media/video/disc/disc_format.dart'
    show discRootForMemberPath;
import 'package:fushi_engine/media/video/disc/disc_release_set.dart';
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart';
import 'package:fushi_engine/media/video/dvd/dvd_library_title.dart';
import 'package:fushi_engine/media/video/dvd/dvd_ifo.dart'
    show DvdIfoFormatException;
import 'package:fushi_engine/media/video/m3u8_playlist.dart' show PlaylistEntry;
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart' show DeleteScope;

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

  /// 读不出盘 / 一条标题都选不出来的盘根（半张盘、BD 镜像、数据镜像），以及库里
  /// 已有分集、但它背后的播放列表或片段这一轮缺着的盘（还在拷）。不是错误：盘文件
  /// 原样在盘上，只是本轮不入库、不对齐、不回收。
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
    // 用户单独删掉的特典：挂在盘合集自然键下的成员墓碑（见
    // [planBlurayExtraDeletionTombstones]）。整轮一次查询。
    final Map<String, Set<String>> deletedExtras =
        await deletedBlurayExtraKeysByCollection(_db);

    // 先把本轮的盘全部读完再分组：同一发布的几张剧集盘要并进一个合集、按盘序排。
    final List<BlurayDisc> read = <BlurayDisc>[];
    final List<String> unreadable = <String>[];
    for (final String root in discRoots) {
      final BlurayDisc? disc = await readBlurayDisc(root);
      // 半张盘 / 一条标题都选不出来：跳过而不是记错。盘里的文件已经在规划层被摘出
      // 散装视频，这里再报错只会把整次扫描标红。库里已有的分集背后的播放列表 / 片段
      // 缺了（盘不完整、还在拷）同样整盘跳过：本轮切集结果不可信，不能拿它回收或
      // 对齐合集（[_hasUnsettledEpisodeRows]）。
      if (disc == null || await _hasUnsettledEpisodeRows(disc)) {
        unreadable.add(root);
      } else if (restoreDissolvedGroups ||
          !await _legacyDiscCollectionDeleted(disc)) {
        read.add(disc);
      }
    }

    int count = 0;
    final List<DiscLibraryImportedDisc> imported = <DiscLibraryImportedDisc>[];
    for (final BlurayReleaseSet set in planBlurayReleaseSets(read)) {
      final List<_PendingRemoval> removals = <_PendingRemoval>[];
      // 剧集组先把存量的整卷行就地改成第 1 集，合集对齐时按路径认回这一行。
      final List<_WholeTitleCarry> carries = <_WholeTitleCarry>[
        if (set.episodic)
          for (final BlurayDisc disc in set.discs)
            ...await _adoptWholeTitleRows(disc),
      ];
      // 反向：上一轮切成集、这一轮整条选成标题的播放列表，把第 1 集的行就地改回整卷。
      final List<_RevertedEpisodes> reverted = <_RevertedEpisodes>[
        for (final BlurayDisc disc in set.discs)
          ...await _revertUnsplitEpisodeRows(disc),
      ];
      final Map<BlurayDisc, List<PlaylistEntry>> entriesByDisc =
          <BlurayDisc, List<PlaylistEntry>>{
            for (final BlurayDisc disc in set.discs)
              disc: <PlaylistEntry>[
                for (final BlurayTitle title in disc.titles)
                  PlaylistEntry(title: title.name, path: title.playlistPath),
              ],
          };
      final _DiscCollection? collection = set.episodic
          ? await _importReleaseSetCollection(
              set: set,
              entries: <PlaylistEntry>[
                for (final BlurayDisc disc in set.discs)
                  ...entriesByDisc[disc]!,
              ],
              sourceId: sourceId,
              restoreDissolvedGroups: restoreDissolvedGroups,
              extraPaths: <String>{
                for (final BlurayDisc disc in set.discs)
                  for (final BlurayTitle extra in disc.extras)
                    normalizeVideoPath(extra.playlistPath),
              },
              removals: removals,
            )
          : await _importDiscCollection(
              discName: set.name,
              discRootPath: set.discs.single.rootPath,
              entries: entriesByDisc[set.discs.single]!,
              extraPaths: <String>{
                for (final BlurayTitle extra in set.discs.single.extras)
                  normalizeVideoPath(extra.playlistPath),
              },
              sourceId: sourceId,
              restoreDissolvedGroups: restoreDissolvedGroups,
              removals: removals,
            );
      for (final _WholeTitleCarry carry in carries) {
        await _foldWholeTitleProgress(carry);
      }
      await _unbindRevertedEpisodes(
        reverted,
        keepCollectionId: collection?.id,
        removals: removals,
      );
      for (final BlurayDisc disc in set.discs) {
        await _reclaimStaleDiscRows(disc);
        await _syncAutoDiscTitleNames(disc);
      }
      if (collection != null && set.episodic) {
        for (final BlurayDisc disc in set.discs) {
          await _dissolveSupersededDiscCollections(
            disc,
            keepCollectionId: collection.id,
            removals: removals,
          );
        }
      }
      // 回收之后再记建议：被回收的整卷行已不在合集里，不该再请用户确认移出它。
      await _settleRemovals(removals);
      if (collection == null) continue;
      if (collection.created) count++;
      await onCollectionReady?.call(collection.id, set.discs.first.rootPath);

      // 特典（菜单里的「特典映像」等）入库、带来源，但不进盘合集：索引器随后把它们
      // 挂到正片作品下，作品资料页的特典区就能看到、点开就播。排在合集墓碑守卫
      // 之后，且跳过用户单独删掉的那几条（PR #2058 审查：原先排在守卫之前，删掉
      // 整盘合集后重扫特典照样复活）。盘已读好，整盘一次入库。
      final Set<String> deleted =
          deletedExtras[collection.name] ?? const <String>{};
      for (final BlurayDisc disc in set.discs) {
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
              for (final PlaylistEntry entry in entriesByDisc[disc]!)
                entry.path,
            ],
            created: collection.created && identical(disc, set.discs.first),
          ),
        );
      }
    }
    return DiscLibraryImportReport(
      imported: count,
      discs: List<DiscLibraryImportedDisc>.unmodifiable(imported),
      unreadable: List<String>.unmodifiable(unreadable),
    );
  }

  /// [disc] 是一张要并进发布组的剧集盘，修前它按盘名单独成一个合集，那个合集被用户
  /// 删过（墓碑挂在旧盘名 / 它的「盘名 (上级目录)」消歧名下），且这张盘还没有任何
  /// 分集行（从没按新方案入过库）。是的话本轮跳过整张盘，与修前「用户删过盘合集，
  /// 重扫不复活」同一语义（§7-D5）：发布组合集改用去卷标的作品名之后，旧名下的墓碑
  /// 不会再被 [_importReleaseSetCollection] 查到。已经有分集行的盘说明删除之后又
  /// 入过库（下载入库 / 恢复分组），不再拿旧墓碑挡它。
  Future<bool> _legacyDiscCollectionDeleted(BlurayDisc disc) async {
    if (!disc.titles.any((BlurayTitle title) => title.isEpisode)) return false;
    final String stem = blurayReleaseStem(disc);
    // 只认盘名与「盘名 (上级目录)」两个候选：再往后的 `(2)`、`(3)` 不带这张盘的
    // 任何特征，可能是别的同名盘的合集。
    final String second = blurayCollectionNameCandidates(
      disc.name,
      disc.rootPath,
    ).elementAt(1);
    final List<String> legacyNames = <String>[
      disc.name,
      if (second != '${disc.name} (2)') second,
    ].where((String name) => name != stem).toList();
    bool deleted = false;
    for (final String name in legacyNames) {
      if (await _db.hasCollectionDeletionTombstone(name, 'playlist')) {
        deleted = true;
        break;
      }
    }
    if (!deleted) return false;
    for (final VideoBookRow row in await _rowsOnDisc(disc.rootPath)) {
      if (isBlurayEpisodePath(row.videoPath)) return false;
    }
    return true;
  }

  /// 库里盘根是 [discRootPath] 的行。
  Future<List<VideoBookRow>> _rowsOnDisc(String discRootPath) async {
    final String root = normalizeVideoPath(discRootPath);
    return <VideoBookRow>[
      for (final VideoBookRow row in await _videoRepo.listAll())
        if (discRootForMemberPath(row.videoPath) case final String owner
            when normalizeVideoPath(owner) == root)
          row,
    ];
  }

  /// [title] 是不是入库时自动起的盘标题名（`<盘名>` / `<盘名> - NN`），用户没改过。
  static bool _isAutoDiscTitle(String title, String discName) =>
      title == discName ||
      (title.startsWith('$discName - ') &&
          RegExp(r'^\d{2,5}$').hasMatch(title.substring(discName.length + 3)));

  /// 把 [disc] 上标题 / 特典行的自动名对齐到本轮的选片结论：标题是 `<盘名> - NN`
  /// （盘内标题序号），特典是 `<盘名> - <MPLS 号>`。选片判据变了的存量行（修前被
  /// 选成第 3 个标题、这一轮降为特典的采访 `00005.mpls`）还顶着「- 03」，读起来就是
  /// 第 3 集。用户改过的名字（不是 [_isAutoDiscTitle] 形状）不动。
  Future<void> _syncAutoDiscTitleNames(BlurayDisc disc) async {
    final Map<String, String> nameByPath = <String, String>{
      for (final BlurayTitle extra in disc.extras)
        normalizeVideoPath(extra.playlistPath): extra.name,
      for (final BlurayTitle title in disc.titles)
        normalizeVideoPath(title.playlistPath): title.name,
    };
    for (final VideoBookRow row in await _rowsOnDisc(disc.rootPath)) {
      final String? expected = nameByPath[normalizeVideoPath(row.videoPath)];
      if (expected == null || expected == row.title) continue;
      if (!_isAutoDiscTitle(row.title, disc.name)) continue;
      await _videoRepo.updateTitle(row.bookUid, expected);
    }
  }

  /// 存量迁移第一步：[disc] 上被切成集的整条播放列表若已有库行（修前「一卷一个
  /// 条目」），把它**就地改成第 1 集**——`videoPath` 换成第 1 集的分集路径，`bookUid`、
  /// 封面、观看统计、制卡记录全部留在这一行上。第 1 集已另有其行时不改，记成重复、
  /// 之后回收。返回的快照供 [_foldWholeTitleProgress] 把断点折到对应那一集。
  Future<List<_WholeTitleCarry>> _adoptWholeTitleRows(BlurayDisc disc) async {
    final Map<String, List<BlurayTitle>> episodesBySource =
        <String, List<BlurayTitle>>{};
    for (final BlurayTitle title in disc.titles) {
      final String? source = title.sourcePlaylistId;
      if (source == null) continue;
      episodesBySource.putIfAbsent(source, () => <BlurayTitle>[]).add(title);
    }
    if (episodesBySource.isEmpty) return const <_WholeTitleCarry>[];
    final Map<String, VideoBookRow> byPath = <String, VideoBookRow>{
      for (final VideoBookRow row in await _rowsOnDisc(disc.rootPath))
        normalizeVideoPath(row.videoPath): row,
    };
    final List<_WholeTitleCarry> carries = <_WholeTitleCarry>[];
    for (final MapEntry<String, List<BlurayTitle>> entry
        in episodesBySource.entries) {
      final VideoBookRow? whole =
          byPath[normalizeVideoPath(
            p.join(disc.rootPath, 'BDMV', 'PLAYLIST', '${entry.key}.mpls'),
          )];
      if (whole == null) continue;
      BlurayPlaylist? playlist;
      for (final BlurayPlaylist candidate in disc.playlists) {
        if (candidate.id == entry.key) playlist = candidate;
      }
      if (playlist == null) continue;
      final BlurayTitle first = entry.value.first;
      final bool adopted = !byPath.containsKey(
        normalizeVideoPath(first.playlistPath),
      );
      if (adopted) {
        await _videoRepo.updateLocalMediaPaths(
          whole.bookUid,
          videoPath: first.playlistPath,
        );
        if (_isAutoDiscTitle(whole.title, disc.name)) {
          await _videoRepo.updateTitle(whole.bookUid, first.name);
        }
      }
      carries.add(
        _WholeTitleCarry(
          row: whole,
          adopted: adopted,
          playlist: playlist,
          episodePaths: <String>[
            for (final BlurayTitle title in entry.value) title.playlistPath,
          ],
        ),
      );
    }
    return carries;
  }

  /// 存量迁移第二步：把整卷行原来的观看状态折到各集上。看完的整卷 → 各集都记看完；
  /// 断点落在第 k 集 → 第 1～k-1 集记看完、断点减去该集起点写到第 k 集。看完标记只补空；
  /// 第 k 集已有断点时按最后观看时刻新者胜（§7-D4：菜单绑定新建的整卷行每轮都会被
  /// 回收，它上面较新的断点不能因为那一集早先看过而丢掉）。
  Future<void> _foldWholeTitleProgress(_WholeTitleCarry carry) async {
    final VideoBookRow whole = carry.row;
    final DateTime? completedAt = whole.completedAt;
    final int position = whole.lastPositionMs;
    if (completedAt == null && position <= 0) return;
    final List<BlurayEpisodeSpan> spans = splitBlurayPlaylistEpisodes(
      carry.playlist,
    );
    if (spans.length != carry.episodePaths.length) return;
    final Map<String, VideoBookRow> byPath = <String, VideoBookRow>{
      for (final VideoBookRow row in await _videoRepo.listAll())
        normalizeVideoPath(row.videoPath): row,
    };
    final List<VideoBookRow> episodes = <VideoBookRow>[];
    for (final String path in carry.episodePaths) {
      final VideoBookRow? row = byPath[normalizeVideoPath(path)];
      // 合集被墓碑挡下没建出各集：没有可折的去处。
      if (row == null) return;
      episodes.add(row);
    }
    if (completedAt != null) {
      for (final VideoBookRow episode in episodes) {
        await _db.markVideoCompleted(episode.bookUid, completedAt);
      }
      return;
    }
    int startMsOf(int index) =>
        blurayEpisodeStartTicks(carry.playlist, spans[index]) *
        1000 ~/
        kBlurayTimeScale;
    int index = spans.length - 1;
    for (int i = 0; i + 1 < spans.length; i++) {
      if (position < startMsOf(i + 1)) {
        index = i;
        break;
      }
    }
    final int playedAt = whole.lastPlayedAt ?? 0;
    // 分集行没有断点，或整卷行上的断点更新（从原盘菜单「本編再生」接着看过）：
    // 整卷行回收前把断点交给那一集。分集行自己的断点更新时不动。
    bool wholeSupersedes(VideoBookRow episode) =>
        episode.lastPositionMs <= 0 || playedAt > (episode.lastPlayedAt ?? 0);
    if (index == 0) {
      // 断点就在第 1 集里：就地接管的行原样带着它；重复行的断点交给第 1 集。
      if (!carry.adopted && wholeSupersedes(episodes.first)) {
        await _db.updateVideoBookPosition(
          episodes.first.bookUid,
          position,
          playedAt: playedAt,
        );
      }
      return;
    }
    final DateTime watchedAt = playedAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(playedAt)
        : DateTime.now();
    for (int i = 0; i < index; i++) {
      await _db.markVideoCompleted(episodes[i].bookUid, watchedAt);
    }
    if (carry.adopted) {
      // 第 1 集的行还带着整卷时间轴上的断点（已超出这一集的长度），清掉。
      await (_db.update(_db.videoBooks)
            ..where((t) => t.bookUid.equals(episodes.first.bookUid)))
          .write(const VideoBooksCompanion(lastPositionMs: Value<int>(0)));
    }
    if (wholeSupersedes(episodes[index])) {
      await _db.updateVideoBookPosition(
        episodes[index].bookUid,
        position - startMsOf(index),
        playedAt: playedAt,
      );
    }
  }

  /// [disc] 上有没有「对不上本轮任何一集」的分集行，且它背后的播放列表不在、或那条
  /// 播放列表引用的片段没能确证全在（盘不完整 / 还在拷 / `STREAM` 读不动）。有就说明
  /// 本轮的切集结果建立在一张残盘上：整盘本轮不回收、不对齐合集，与 [readBlurayDisc]
  /// 返回 null 同一语义，留到盘完整的那一轮再判。
  Future<bool> _hasUnsettledEpisodeRows(BlurayDisc disc) async {
    final Set<String> titlePaths = <String>{
      for (final BlurayTitle title in disc.titles)
        normalizeVideoPath(title.playlistPath),
    };
    final Map<String, BlurayPlaylist> byId = <String, BlurayPlaylist>{
      for (final BlurayPlaylist playlist in disc.playlists)
        playlist.id: playlist,
    };
    for (final VideoBookRow row in await _rowsOnDisc(disc.rootPath)) {
      final BlurayEpisodeRef? ref = parseBlurayEpisodePath(row.videoPath);
      if (ref == null) continue;
      if (titlePaths.contains(normalizeVideoPath(row.videoPath))) continue;
      final BlurayPlaylist? backing =
          byId[p.basenameWithoutExtension(ref.playlistPath)];
      if (backing == null || !disc.hasAllClipsOf(backing)) return true;
    }
    return false;
  }

  /// 存量迁移的反向（D1 的对称）：[disc] 上某条播放列表上一轮被切成了集、这一轮整条
  /// 被选成了标题（切集判据收紧、或盘上新冒出了逐集播放列表），把**第 1 集的行就地
  /// 改回整卷路径**——`bookUid`、封面、统计、制卡记录留在这一行上；其余各集的进度
  /// 折回整卷时间轴（[_foldEpisodeProgressBack]）。整卷路径已另有其行时不改路径，只把
  /// 进度补给那一行（只补空）。其余分集行不删，合集对齐之后再从导入器建的合集里解绑
  /// （[_unbindRevertedEpisodes]）。
  ///
  /// 只处理背后播放列表就在本轮标题里、且 PlayItem 序号都落在它范围内的分集行；
  /// 对不上的（盘被换过）原样留着。
  Future<List<_RevertedEpisodes>> _revertUnsplitEpisodeRows(
    BlurayDisc disc,
  ) async {
    final Map<String, BlurayTitle> wholeTitles = <String, BlurayTitle>{
      for (final BlurayTitle title in disc.titles)
        if (!title.isEpisode) title.playlist.id: title,
    };
    if (wholeTitles.isEmpty) return const <_RevertedEpisodes>[];
    final List<VideoBookRow> rows = await _rowsOnDisc(disc.rootPath);
    final Map<String, VideoBookRow> byPath = <String, VideoBookRow>{
      for (final VideoBookRow row in rows)
        normalizeVideoPath(row.videoPath): row,
    };
    final Map<String, List<({int playItem, VideoBookRow row})>> bySource =
        <String, List<({int playItem, VideoBookRow row})>>{};
    for (final VideoBookRow row in rows) {
      final BlurayEpisodeRef? ref = parseBlurayEpisodePath(row.videoPath);
      if (ref == null) continue;
      final String source = p.basenameWithoutExtension(ref.playlistPath);
      if (!wholeTitles.containsKey(source)) continue;
      bySource
          .putIfAbsent(source, () => <({int playItem, VideoBookRow row})>[])
          .add((playItem: ref.playItemNumber, row: row));
    }
    final List<_RevertedEpisodes> reverted = <_RevertedEpisodes>[];
    for (final MapEntry<String, List<({int playItem, VideoBookRow row})>> entry
        in bySource.entries) {
      final BlurayTitle title = wholeTitles[entry.key]!;
      final List<({int playItem, VideoBookRow row})> episodes = entry.value
        ..sort((a, b) => a.playItem.compareTo(b.playItem));
      if (episodes.any((e) => e.playItem > title.playlist.clips.length)) {
        continue;
      }
      final VideoBookRow? whole =
          byPath[normalizeVideoPath(title.playlistPath)];
      final VideoBookRow first = episodes.first.row;
      final bool adopted = whole == null;
      if (adopted) {
        await _videoRepo.updateLocalMediaPaths(
          first.bookUid,
          videoPath: title.playlistPath,
        );
        if (_isAutoDiscTitle(first.title, disc.name)) {
          await _videoRepo.updateTitle(first.bookUid, title.name);
        }
      }
      await _foldEpisodeProgressBack(
        title.playlist,
        episodes,
        target: whole ?? first,
        adopted: adopted,
      );
      reverted.add(
        _RevertedEpisodes(
          discRootPath: disc.rootPath,
          uids: <String>[
            for (final ({int playItem, VideoBookRow row}) e in episodes)
              e.row.bookUid,
          ],
        ),
      );
    }
    return reverted;
  }

  /// 把各集（迁移前快照，按 PlayItem 序）的观看状态折回整卷时间轴，写到 [target]：
  /// 全部看完 → 整卷看完；否则取进度最远的那一集，断点 = 该集在整卷上的起点 + 集内
  /// 断点（那一集只有看完标记 → 下一集的起点）。[adopted] = [target] 就是原第 1 集
  /// 的行（它的断点本来就在整卷时间轴上，看完标记属于第 1 集、要清掉）；否则 [target]
  /// 是整卷原有的行，只补空。
  ///
  /// 各集起点不依赖切集判据（这条播放列表这一轮恰恰不切了）：第一条分集行从 0 起，
  /// 其余从它的锚点 PlayItem 起——与切集时「锚点之前的短段并进第一集、锚点之后的短段
  /// 并进前一集」同一口径。
  Future<void> _foldEpisodeProgressBack(
    BlurayPlaylist playlist,
    List<({int playItem, VideoBookRow row})> episodes, {
    required VideoBookRow target,
    required bool adopted,
  }) async {
    if (!adopted && (target.completedAt != null || target.lastPositionMs > 0)) {
      return;
    }
    int startMsOf(int index) {
      if (index == 0) return 0;
      int ticks = 0;
      for (int i = 0; i < episodes[index].playItem - 1; i++) {
        ticks += playlist.clips[i].durationTicks;
      }
      return ticks * 1000 ~/ kBlurayTimeScale;
    }

    final List<VideoBookRow> rows = <VideoBookRow>[
      for (final ({int playItem, VideoBookRow row}) e in episodes) e.row,
    ];
    final int playedAt = rows.fold<int>(
      0,
      (int latest, VideoBookRow row) =>
          (row.lastPlayedAt ?? 0) > latest ? row.lastPlayedAt! : latest,
    );
    if (rows.every((VideoBookRow row) => row.completedAt != null)) {
      if (!adopted) {
        await _db.markVideoCompleted(target.bookUid, rows.last.completedAt!);
      }
      return;
    }
    int? furthest;
    for (int i = 0; i < rows.length; i++) {
      if (rows[i].completedAt != null || rows[i].lastPositionMs > 0) {
        furthest = i;
      }
    }
    if (adopted && rows.first.completedAt != null) {
      // 第 1 集看完 ≠ 整卷看完。
      await (_db.update(
        _db.videoBooks,
      )..where((t) => t.bookUid.equals(target.bookUid))).write(
        const VideoBooksCompanion(completedAt: Value<DateTime?>(null)),
      );
    }
    if (furthest == null) return;
    final VideoBookRow row = rows[furthest];
    final int position;
    if (row.lastPositionMs > 0) {
      position = startMsOf(furthest) + row.lastPositionMs;
    } else if (furthest + 1 < rows.length) {
      position = startMsOf(furthest + 1);
    } else {
      position = playlist.durationTicks * 1000 ~/ kBlurayTimeScale;
    }
    if (adopted && furthest == 0 && row.lastPositionMs > 0) return;
    await _db.updateVideoBookPosition(
      target.bookUid,
      position,
      playedAt: playedAt,
    );
  }

  /// 反向迁移过的分集行（含改回整卷的那一行）从导入器建的合集（成员全是这个发布
  /// 目录下的原盘成员，见 [_collectionBelongsToRelease]）里移出，[keepCollectionId]
  /// （本轮这张盘对齐 / 新建的合集）除外。只解绑，不删行——与
  /// `VideoBookRepository.reconcileSplitPlaylist` 同一约定；混了别的东西的合集不碰。
  /// 移出经 [_retire]：用户的合集只记建议。
  Future<void> _unbindRevertedEpisodes(
    List<_RevertedEpisodes> reverted, {
    required int? keepCollectionId,
    required List<_PendingRemoval> removals,
  }) async {
    if (reverted.isEmpty) return;
    final List<MediaCollectionItemRow> items = await _db
        .getAllCollectionItems();
    final Map<String, bool> belongsCache = <String, bool>{};
    for (final _RevertedEpisodes group in reverted) {
      final Set<String> uids = group.uids.toSet();
      // 与 [_collectionBelongsToRelease] 同一判据（跳过 `BD` 这类介质包装目录）。
      final String release = discReleaseDirectory(group.discRootPath);
      for (final MediaCollectionItemRow item in items) {
        if (item.collectionId == keepCollectionId) continue;
        if (item.mediaType != MediaKind.video.dbValue) continue;
        if (!uids.contains(item.entryKey)) continue;
        final String cacheKey = '${item.collectionId}|$release';
        final bool belongs = belongsCache[cacheKey] ??=
            await _isImporterReleaseCollection(item.collectionId, release);
        if (!belongs) continue;
        await _retire(
          item.collectionId,
          <String>[item.entryKey],
          kMemberRemovalReasonDiscStale,
          removals,
        );
      }
    }
  }

  Future<bool> _isImporterReleaseCollection(
    int collectionId,
    String releasePath,
  ) async {
    final MediaCollectionRow? collection = await _db.getMediaCollectionById(
      collectionId,
    );
    if (collection?.collectionType != 'playlist') return false;
    return _collectionBelongsToRelease(collectionId, releasePath);
  }

  /// 回收 [disc] 上「不再是标题也不是特典」且**结构上**能确证永远不是内容的成员行：
  /// - 菜单背景循环（[isBlurayMenuLoop]）：修前它按总时长被选成标题进了库；
  /// - 本轮确实被切成集、且各集都已有行的那条整卷播放列表（进度已由
  ///   [_foldWholeTitleProgress] 折过去）。合集被墓碑挡下、各集没建出来时不回收，
  ///   整卷行和它的进度原样留着。
  ///
  /// 分集行一律不物理删除：它对不上本轮切集结果只说明启发式这一轮给了别的答案（或
  /// 盘被换过），行上的进度、看完标记、封面、统计不能跟着丢。整卷重新被选成标题的
  /// 由 [_revertUnsplitEpisodeRows] 改回去；盘不完整的整盘在读盘处就跳过了。
  ///
  /// 其它非标题非特典的行（厂标、章节子集等用户从原盘菜单点进去过的）不动。走既有
  /// 回收路径：不删用户文件、不写跨设备删除墓碑。拿不到刮削租约就留到下一轮。
  Future<void> _reclaimStaleDiscRows(BlurayDisc disc) async {
    final List<VideoBookRow> rows = await _rowsOnDisc(disc.rootPath);
    final Set<String> present = <String>{
      for (final VideoBookRow row in rows) normalizeVideoPath(row.videoPath),
    };
    final Set<String> keep = <String>{
      for (final BlurayTitle title in disc.titles)
        normalizeVideoPath(title.playlistPath),
      for (final BlurayTitle extra in disc.extras)
        normalizeVideoPath(extra.playlistPath),
    };
    final Map<String, List<String>> episodesBySource = <String, List<String>>{};
    for (final BlurayTitle title in disc.titles) {
      if (title.sourcePlaylistId case final String source) {
        episodesBySource
            .putIfAbsent(source, () => <String>[])
            .add(normalizeVideoPath(title.playlistPath));
      }
    }
    final Set<String> retired = <String>{
      for (final BlurayPlaylist playlist in disc.playlists)
        if (isBlurayMenuLoop(playlist)) playlist.id,
      for (final MapEntry<String, List<String>> entry
          in episodesBySource.entries)
        if (entry.value.every(present.contains)) entry.key,
    };
    final List<String> stale = <String>[
      for (final VideoBookRow row in rows)
        if (isBlurayPlaylistPath(row.videoPath) &&
            !isBlurayEpisodePath(row.videoPath) &&
            !keep.contains(normalizeVideoPath(row.videoPath)) &&
            retired.contains(p.basenameWithoutExtension(row.videoPath)))
          row.bookUid,
    ];
    if (stale.isEmpty) return;
    try {
      await _videoRepo.deleteVideoBooksAndReclaimAssets(
        stale,
        scope: DeleteScope.keepLocalOnly,
        compactDatabase: false,
        deleteLocalFiles: false,
      );
    } on StateError {
      // 刮削资料清理在跑：这些行留在库里，下一轮扫描再回收。
    } on VideoBooksDeleteException {
      // 部分成功：没删掉的下一轮再判。
    }
  }

  /// 修前 [disc] 自己的那个单盘合集（成员全在本盘、不是 [keepCollectionId]）：成员
  /// 已经并进发布组的合集，把它们从旧合集移出，旧合集移空自删。经 [_retire]：
  /// 用户的合集（修前导入器建的合集一律是 `user`，分不出来）记成待确认建议。
  Future<void> _dissolveSupersededDiscCollections(
    BlurayDisc disc, {
    required int keepCollectionId,
    required List<_PendingRemoval> removals,
  }) async {
    final Set<String> discUids = <String>{
      for (final VideoBookRow row in await _rowsOnDisc(disc.rootPath))
        row.bookUid,
    };
    if (discUids.isEmpty) return;
    final Map<int, List<MediaCollectionItemRow>> byCollection =
        <int, List<MediaCollectionItemRow>>{};
    for (final MediaCollectionItemRow item
        in await _db.getAllCollectionItems()) {
      byCollection
          .putIfAbsent(item.collectionId, () => <MediaCollectionItemRow>[])
          .add(item);
    }
    for (final MapEntry<int, List<MediaCollectionItemRow>> entry
        in byCollection.entries) {
      if (entry.key == keepCollectionId) continue;
      final bool allOnDisc = entry.value.every(
        (MediaCollectionItemRow item) =>
            item.mediaType == MediaKind.video.dbValue &&
            discUids.contains(item.entryKey),
      );
      if (!allOnDisc) continue;
      final MediaCollectionRow? collection = await _db.getMediaCollectionById(
        entry.key,
      );
      if (collection?.collectionType != 'playlist') continue;
      await _retire(
        entry.key,
        <String>[
          for (final MediaCollectionItemRow item in entry.value) item.entryKey,
        ],
        kMemberRemovalReasonDiscSuperseded,
        removals,
      );
    }
  }

  /// 一个发布组（同一发布的几张剧集盘）的合集：按分组键找回并对齐，或新建；用户删过
  /// 这个合集且不恢复时返回 null。新建时合集名是去卷标的作品名（撞上别的合集换
  /// [blurayCollectionNameCandidates] 的下一个），只有一张盘在库时也用它——之后另一张
  /// 盘到了按键并进来。成员每轮按盘序 × 盘内集序重排。
  Future<_DiscCollection?> _importReleaseSetCollection({
    required BlurayReleaseSet set,
    required List<PlaylistEntry> entries,
    required int? sourceId,
    required bool restoreDissolvedGroups,
    required Set<String> extraPaths,
    required List<_PendingRemoval> removals,
  }) async {
    final String release = normalizeVideoPath(set.parentPath);
    final _DiscCollection? collection = await _resolveDiscCollection(
      organizeKey: blurayReleaseSetOrganizeKey(set),
      nameCandidates: blurayCollectionNameCandidates(
        set.name,
        set.discs.first.rootPath,
      ),
      entries: entries,
      owns: (String discRoot) =>
          normalizeVideoPath(discReleaseDirectory(discRoot)) == release,
      minDiscRoots: set.discs.length > 1 ? 2 : 1,
      sourceId: sourceId,
      restoreDissolvedGroups: restoreDissolvedGroups,
    );
    if (collection == null) return null;
    if (!collection.created) {
      await _reconcileReleaseSetCollection(
        collectionId: collection.id,
        entries: entries,
        discRoots: <String>{
          for (final BlurayDisc disc in set.discs)
            normalizeVideoPath(disc.rootPath),
        },
        extraPaths: extraPaths,
        sourceId: sourceId,
        removals: removals,
      );
    }
    await _orderReleaseSetCollection(collection.id, set);
    return collection;
  }

  /// 按分组键 [organizeKey] 找回这组盘的合集，找不到就新建（`origin = rule`、带键、
  /// 名字取 [nameCandidates] 里第一个没被占的）。找回的顺序：
  /// 1. 修前建的无键合集（[_adoptableCollection]）认领一次：挂上键、`origin` 原样
  ///    （存量的多半是 `user`）；
  /// 2. 持有这个键的合集（`collectionHoldingOrganizeKey`，与整理收敛同一判据：整理器
  ///    合集认主键与别名，用户合集只认主键——改过名的、被 AI 并进别的合集的都在这）；
  /// 3. 别名里带这个键、成员也确实是这组盘的合集（用户接手了吸收过它的合集）。
  /// 用户删过（同名合集墓碑 / 分组键被拒绝）且不恢复时返回 null。
  Future<_DiscCollection?> _resolveDiscCollection({
    required String organizeKey,
    required Iterable<String> nameCandidates,
    required List<PlaylistEntry> entries,
    required bool Function(String discRoot) owns,
    required int minDiscRoots,
    required int? sourceId,
    required bool restoreDissolvedGroups,
  }) async {
    final Set<String> wanted = <String>{
      for (final PlaylistEntry entry in entries) normalizeVideoPath(entry.path),
    };
    final ({MediaCollectionRow? keyless, MediaCollectionRow? aliased}) found =
        await _adoptableCollection(
          organizeKey: organizeKey,
          wantedPaths: wanted,
          owns: owns,
          minDiscRoots: minDiscRoots,
        );
    if (found.keyless case final MediaCollectionRow legacy) {
      await _db.setMediaCollectionOrganizeState(
        legacy.id,
        origin: CollectionOrigin.parse(legacy.origin),
        organizeKey: organizeKey,
        organizeAliases: decodeOrganizeAliases(legacy.organizeAliases),
      );
    }
    final MediaCollectionRow? existing =
        await collectionHoldingOrganizeKey(_db, organizeKey) ?? found.aliased;
    if (existing != null) {
      return _DiscCollection(
        id: existing.id,
        name: existing.name,
        created: false,
      );
    }
    String name = nameCandidates.first;
    for (final String candidate in nameCandidates) {
      name = candidate;
      if (await _db.getMediaCollectionByNaturalKey(candidate, 'playlist') ==
          null) {
        break;
      }
    }
    // BUG-1739 同款守卫：用户删过这个合集（修前按名字记的墓碑，或带着分组键的删除
    // 哨兵），重扫不复活。
    if (!restoreDissolvedGroups &&
        (await _db.hasCollectionDeletionTombstone(name, 'playlist') ||
            (await _db.getRejectedOrganizeGroups()).containsKey(organizeKey))) {
      return null;
    }
    final SplitPlaylistImportResult result = await _videoRepo
        .importSplitPlaylist(
          collectionName: name,
          entries: entries,
          sourceId: sourceId,
          reuseExistingPaths: true,
          origin: CollectionOrigin.rule,
          organizeKey: organizeKey,
        );
    await _videoRepo.recordVideoImportActivity(
      bookUid: result.episodeUids.first,
      title: name,
    );
    return _DiscCollection(id: result.collectionId, name: name, created: true);
  }

  /// 修前（没有分组键时）建的、这组盘的合集。只看 `playlist` 合集（导入器只建这种），
  /// 成员里有本轮的标题行（[wantedPaths]）、视频成员至少一半（[kConvergenceOverlapRatio]，
  /// 与收敛的成员重叠同一口径）在 [owns] 认的盘上、且跨了至少 [minDiscRoots] 张盘
  /// （几张盘并组时，修前那种一盘一个的单盘合集不当发布组合集认领，由
  /// [_dissolveSupersededDiscCollections] 收拾）。多个候选取本轮标题行最多的，再取
  /// 盘上成员最多的，再取 id 小的。
  ///
  /// `keyless` 是还没挂键的候选（认领一次后就有键，之后按键找回）；`aliased` 是别名里
  /// 带 [organizeKey] 的候选（被并进了别的合集、那个合集又被用户接手，收敛只认用户合集
  /// 的主键，找不到它）。
  Future<({MediaCollectionRow? keyless, MediaCollectionRow? aliased})>
  _adoptableCollection({
    required String organizeKey,
    required Set<String> wantedPaths,
    required bool Function(String discRoot) owns,
    required int minDiscRoots,
  }) async {
    final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
      for (final VideoBookRow row in await _videoRepo.listAll())
        row.bookUid: row,
    };
    final Map<int, List<MediaCollectionItemRow>> itemsById =
        <int, List<MediaCollectionItemRow>>{};
    for (final MediaCollectionItemRow item
        in await _db.getAllCollectionItems()) {
      (itemsById[item.collectionId] ??= <MediaCollectionItemRow>[]).add(item);
    }
    MediaCollectionRow? keyless;
    MediaCollectionRow? aliased;
    (int, int)? keylessScore;
    (int, int)? aliasedScore;
    bool better((int, int) score, (int, int)? best, int id, int? bestId) {
      if (best == null) return true;
      if (score.$1 != best.$1) return score.$1 > best.$1;
      if (score.$2 != best.$2) return score.$2 > best.$2;
      return id < bestId!;
    }

    for (final MediaCollectionRow c in await _db.getAllMediaCollections()) {
      final bool isKeyless =
          c.organizeKey == null && c.collectionType == 'playlist';
      final bool isAliased = decodeOrganizeAliases(
        c.organizeAliases,
      ).contains(organizeKey);
      if (!isKeyless && !isAliased) continue;
      int videos = 0;
      int owned = 0;
      int titles = 0;
      final Set<String> roots = <String>{};
      for (final MediaCollectionItemRow item
          in itemsById[c.id] ?? const <MediaCollectionItemRow>[]) {
        if (item.mediaType != MediaKind.video.dbValue) continue;
        final VideoBookRow? row = byUid[item.entryKey];
        if (row == null) continue;
        videos++;
        if (wantedPaths.contains(normalizeVideoPath(row.videoPath))) titles++;
        final String? owner = discRootForMemberPath(row.videoPath);
        if (owner != null && owns(owner)) {
          owned++;
          roots.add(normalizeVideoPath(owner));
        }
      }
      if (titles == 0 ||
          owned < videos * kConvergenceOverlapRatio ||
          roots.length < minDiscRoots) {
        continue;
      }
      final (int, int) score = (titles, owned);
      if (isKeyless && better(score, keylessScore, c.id, keyless?.id)) {
        keyless = c;
        keylessScore = score;
      } else if (isAliased && better(score, aliasedScore, c.id, aliased?.id)) {
        aliased = c;
        aliasedScore = score;
      }
    }
    return (keyless: keyless, aliased: aliased);
  }

  /// 自动路径要把 [uids] 移出合集 [collectionId]：整理器管着的合集（`rule` / `ai`）
  /// 直接移出（用户钉住的成员拒移，见 `removeFromCollectionAutomatically`）；其它
  /// （用户的、文件夹的）记进 [removals]，本组盘处理完由 [_settleRemovals] 记成库管家
  /// 的待确认建议。
  Future<void> _retire(
    int collectionId,
    List<String> uids,
    String reasonCode,
    List<_PendingRemoval> removals,
  ) async {
    if (uids.isEmpty) return;
    final MediaCollectionRow? collection = await _db.getMediaCollectionById(
      collectionId,
    );
    if (collection == null) return;
    if (CollectionOrigin.parse(collection.origin).isOrganizerManaged) {
      for (final String uid in uids) {
        await _db.removeFromCollectionAutomatically(
          collectionId,
          MediaKind.video.dbValue,
          uid,
        );
      }
      return;
    }
    for (final String uid in uids) {
      removals.add(
        _PendingRemoval(
          collectionId: collectionId,
          uid: uid,
          reasonCode: reasonCode,
        ),
      );
    }
  }

  /// 把 [removals] 按（合集、原因）记成「从合集移出成员」的待确认建议（trigger
  /// [kDiscImportOrganizeTrigger]）。此刻已不在合集里 / 被用户钉住的成员由
  /// `recordMemberRemovalProposals` 剔掉；同一建议已在等确认或被拒绝的不重复记。
  Future<void> _settleRemovals(List<_PendingRemoval> removals) async {
    if (removals.isEmpty) return;
    final Map<(int, String), List<String>> grouped =
        <(int, String), List<String>>{};
    for (final _PendingRemoval r in removals) {
      final List<String> uids = grouped[(r.collectionId, r.reasonCode)] ??=
          <String>[];
      if (!uids.contains(r.uid)) uids.add(r.uid);
    }
    await recordMemberRemovalProposals(
      _db,
      trigger: kDiscImportOrganizeTrigger,
      proposals: <MemberRemovalProposal>[
        for (final MapEntry<(int, String), List<String>> e in grouped.entries)
          MemberRemovalProposal(
            collectionId: e.key.$1,
            members: <CollectionMemberKey>[
              for (final String uid in e.value)
                (mediaType: MediaKind.video.dbValue, entryKey: uid),
            ],
            reasonCode: e.key.$2,
          ),
      ],
    );
  }

  /// 发布组合集的成员按「盘序 × 盘内集序」重排。合集里可能还有本轮没读到的盘
  /// （移动硬盘没插）的各集，所以不能只排本轮的成员：每个成员按它所在盘的卷号
  /// （本轮读到的盘看盘内标题，没读到的只看目录名）、盘根路径、成员文件名排——
  /// 文件名 `00001.p01` < `00001.p02` < `00002` 的自然序就是盘内的标题顺序。
  ///
  /// 用户自己塞进来的普通视频（用户 2026-11-24：「塞普通视频无所谓吧，你优化优化」）
  /// 按文件名解出的第 1 季集号 N 排到原盘第 N 集后面（原盘集号是分集在原盘之间的顺位，
  /// [discEpisodeOrdinalsOf]）：与原盘撞号的两个都留着、相邻排，原盘在前；超出原盘
  /// 集数的排在最后一集原盘分集后面，同号按路径。解不出集号的普通视频不参与排序，
  /// 留在原位（[FushiDatabase.reorderCollectionItemsAutomatically] 只重排给出的子集）。
  Future<void> _orderReleaseSetCollection(
    int collectionId,
    BlurayReleaseSet set,
  ) async {
    final Map<String, int> volumeByRoot = <String, int>{
      for (final BlurayDisc disc in set.discs)
        normalizeVideoPath(disc.rootPath): blurayDiscVolumeOrder(disc),
    };
    final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
      for (final VideoBookRow row in await _videoRepo.listAll())
        row.bookUid: row,
    };
    final List<({String uid, int volume, String root, String path})> members =
        <({String uid, int volume, String root, String path})>[];
    final List<({String uid, int episode, String path})> loose =
        <({String uid, int episode, String path})>[];
    for (final MediaCollectionItemRow item in await _db.getCollectionItems(
      collectionId,
    )) {
      final VideoBookRow? row = item.mediaType == MediaKind.video.dbValue
          ? byUid[item.entryKey]
          : null;
      if (row == null) continue;
      final String? owner = discRootForMemberPath(row.videoPath);
      if (owner == null) {
        final VideoNameInfo info = parseVideoPath(row.videoPath);
        if (info.episode case final int episode
            when (info.season ?? 1) == 1 &&
                !isAudioOnlyMediaPath(row.videoPath)) {
          loose.add((uid: row.bookUid, episode: episode, path: row.videoPath));
        }
        continue;
      }
      members.add((
        uid: row.bookUid,
        volume:
            volumeByRoot[normalizeVideoPath(owner)] ??
            discDirectoryVolumeOrder(owner),
        root: owner,
        path: row.videoPath,
      ));
    }
    members.sort((a, b) {
      final int byVolume = a.volume.compareTo(b.volume);
      if (byVolume != 0) return byVolume;
      final int byRoot = naturalCompare(a.root, b.root);
      if (byRoot != 0) return byRoot;
      return naturalCompare(a.path, b.path);
    });
    final List<String> ordered = <String>[
      for (final ({String uid, int volume, String root, String path}) member
          in members)
        member.uid,
    ];
    final List<int?> ordinals = discEpisodeOrdinalsOf(<String>[
      for (final ({String uid, int volume, String root, String path}) member
          in members)
        member.path,
    ]);
    final int lastOrdinal = ordinals.whereType<int>().fold(
      0,
      (int a, int b) => a > b ? a : b,
    );
    if (lastOrdinal > 0 && loose.isNotEmpty) {
      loose.sort((a, b) {
        final int byEpisode = a.episode.compareTo(b.episode);
        if (byEpisode != 0) return byEpisode;
        return naturalCompare(a.path, b.path);
      });
      final Map<int, List<String>> after = <int, List<String>>{};
      for (final ({String uid, int episode, String path}) v in loose) {
        final int anchor = v.episode < lastOrdinal ? v.episode : lastOrdinal;
        (after[anchor] ??= <String>[]).add(v.uid);
      }
      ordered
        ..clear()
        ..addAll(<String>[
          for (int i = 0; i < members.length; i++) ...<String>[
            members[i].uid,
            if (ordinals[i] case final int n) ...?after[n],
          ],
        ]);
    }
    await _db.reorderCollectionItemsAutomatically(
      collectionId,
      <CollectionMemberKey>[
        for (final String uid in ordered)
          (mediaType: MediaKind.video.dbValue, entryKey: uid),
      ],
    );
  }

  /// 把发布组合集的成员对齐到 [entries]。与 [VideoBookRepository.reconcileSplitPlaylist]
  /// 的区别是**按完整路径**对账：同一发布的两张盘各有一条 `00001.p01.mpls`，基身份
  /// 相同，按基身份对账会把第二张盘的各集判成「已是成员」。只移出盘根在 [discRoots]
  /// 里（本轮确实读到了）的原盘成员——没插上的那张盘的各集、用户自己加进来的普通视频
  /// 原样留着；移出经 [_retire]（用户的合集只记建议），特典（[extraPaths]）与其它不再
  /// 是标题的成员分开说明原因。单盘合集同样走这里（[discRoots] 只有那一张盘）。
  Future<void> _reconcileReleaseSetCollection({
    required int collectionId,
    required List<PlaylistEntry> entries,
    required Set<String> discRoots,
    required Set<String> extraPaths,
    required int? sourceId,
    required List<_PendingRemoval> removals,
  }) async {
    final List<VideoBookRow> books = await _videoRepo.listAll();
    final Map<String, VideoBookRow> byPath = <String, VideoBookRow>{};
    final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{};
    for (final VideoBookRow row in books) {
      byUid[row.bookUid] = row;
      byPath.putIfAbsent(normalizeVideoPath(row.videoPath), () => row);
    }
    final Set<String> taken = byUid.keys.toSet();
    final Set<String> members = <String>{
      for (final MediaCollectionItemRow item in await _db.getCollectionItems(
        collectionId,
      ))
        if (item.mediaType == MediaKind.video.dbValue) item.entryKey,
    };
    final Set<String> wanted = <String>{
      for (final PlaylistEntry entry in entries) normalizeVideoPath(entry.path),
    };
    final List<String> extras = <String>[];
    final List<String> stale = <String>[];
    await _db.transaction(() async {
      // 先加后删：绝不让合集瞬时空掉被「移空自删」误删。
      for (final PlaylistEntry entry in entries) {
        final String key = normalizeVideoPath(entry.path);
        final VideoBookRow? existing = byPath[key];
        final String uid;
        if (existing != null) {
          uid = existing.bookUid;
          if (sourceId != null && existing.sourceId == null) {
            await _videoRepo.assignSourceIfNull(uid, sourceId);
          }
        } else {
          uid = coreUniqueVideoBookUid(
            coreSingleVideoBookUid(entry.path),
            taken,
          );
          taken.add(uid);
          await _videoRepo.saveVideoBook(
            VideoBooksCompanion(
              bookUid: Value<String>(uid),
              title: Value<String>(entry.title),
              videoPath: Value<String>(entry.path),
              embeddedSubtitleTrack: const Value<int?>(0),
              importedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
            ),
            sourceId: sourceId,
          );
        }
        if (members.add(uid)) {
          await _db.addToCollection(
            collectionId,
            MediaKind.video,
            uid,
            userIntent: false,
          );
        }
      }
      for (final String uid in members) {
        final VideoBookRow? row = byUid[uid];
        if (row == null) continue;
        final String? owner = discRootForMemberPath(row.videoPath);
        if (owner == null || !discRoots.contains(normalizeVideoPath(owner))) {
          continue;
        }
        final String path = normalizeVideoPath(row.videoPath);
        if (wanted.contains(path)) continue;
        (extraPaths.contains(path) ? extras : stale).add(uid);
      }
      await _retire(
        collectionId,
        extras,
        kMemberRemovalReasonDiscExtra,
        removals,
      );
      await _retire(
        collectionId,
        stale,
        kMemberRemovalReasonDiscStale,
        removals,
      );
    });
  }

  /// 既有合集 [collectionId] 是不是 [parentPath] 这个发布目录下的盘的：成员全是原盘
  /// 标题、且盘的发布目录（[discReleaseDirectory]，与并组同一判据）就是它（本轮没
  /// 读到的那张盘的成员也算）。
  Future<bool> _collectionBelongsToRelease(
    int collectionId,
    String parentPath,
  ) async {
    final String parent = normalizeVideoPath(parentPath);
    for (final MediaCollectionItemRow item in await _db.getCollectionItems(
      collectionId,
    )) {
      final VideoBookRow? row = await _videoRepo.getByBookUid(item.entryKey);
      if (row == null) continue;
      final String? owner = discRootForMemberPath(row.videoPath);
      if (owner == null ||
          normalizeVideoPath(discReleaseDirectory(owner)) != parent) {
        return false;
      }
    }
    return true;
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
    int count = 0;
    final List<DiscLibraryImportedDisc> imported = <DiscLibraryImportedDisc>[];
    for (final DvdDisc disc in discs) {
      final List<PlaylistEntry> entries = <PlaylistEntry>[
        for (final DvdTitle title in disc.titles)
          PlaylistEntry(title: title.name, path: title.titlePath),
      ];
      final List<_PendingRemoval> removals = <_PendingRemoval>[];
      final _DiscCollection? collection = await _importDiscCollection(
        discName: disc.name,
        discRootPath: disc.rootPath,
        entries: entries,
        extraPaths: <String>{
          for (final DvdTitle extra in disc.extras)
            normalizeVideoPath(extra.titlePath),
        },
        sourceId: sourceId,
        restoreDissolvedGroups: restoreDissolvedGroups,
        removals: removals,
      );
      await _settleRemovals(removals);
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

  /// 一张盘的合集：按分组键（[discOrganizeKey]，盘所在的发布目录 + 盘目录）找回并
  /// 对齐成员，或新建；用户删过这个合集且不恢复时返回 null（整张盘都不复活，特典也
  /// 不例外——它们挂在这张盘的正片下，盘都删了特典没有归处）。
  ///
  /// 新建时合集名取盘名，撞上别的合集换 [blurayCollectionNameCandidates] 的下一个
  /// （`S1/DISC1` 与 `S2/DISC1` 同名不同盘）；名字只是显示，身份是键。对齐按完整路径、
  /// 只动这张盘上的原盘成员（[_reconcileReleaseSetCollection]），用户自己加进来的
  /// 普通视频不碰。
  Future<_DiscCollection?> _importDiscCollection({
    required String discName,
    required String discRootPath,
    required List<PlaylistEntry> entries,
    required Set<String> extraPaths,
    required int? sourceId,
    required bool restoreDissolvedGroups,
    required List<_PendingRemoval> removals,
  }) async {
    final String root = normalizeVideoPath(discRootPath);
    final _DiscCollection? collection = await _resolveDiscCollection(
      organizeKey: discOrganizeKey(discRootPath),
      nameCandidates: blurayCollectionNameCandidates(discName, discRootPath),
      entries: entries,
      owns: (String owner) => normalizeVideoPath(owner) == root,
      minDiscRoots: 1,
      sourceId: sourceId,
      restoreDissolvedGroups: restoreDissolvedGroups,
    );
    if (collection != null && !collection.created) {
      await _reconcileReleaseSetCollection(
        collectionId: collection.id,
        entries: entries,
        discRoots: <String>{root},
        extraPaths: extraPaths,
        sourceId: sourceId,
        removals: removals,
      );
    }
    return collection;
  }
}

/// 原盘合集记「移出成员」待确认建议时的整理运行 trigger。
const String kDiscImportOrganizeTrigger = 'disc_import';

/// 发布组（同一发布的几张剧集盘）合集的整理分组键：发布目录名 + 去卷标的作品名。
/// 只由目录名与盘内信息决定（不含本机路径前缀），同一套盘在每台设备上算出同一个键。
String blurayReleaseSetOrganizeKey(BlurayReleaseSet set) =>
    'd:video:set:${_foldKeyPart(p.basename(set.parentPath))}/'
    '${_foldKeyPart(set.name)}';

/// 单盘合集的整理分组键：盘所在的发布目录名 + 盘目录名（跳过 `BD` 这类介质包装层，
/// 镜像是文件名）。与 [blurayReleaseSetOrganizeKey] 一样不含本机路径前缀。
String discOrganizeKey(String discRootPath) =>
    'd:video:disc:'
    '${_foldKeyPart(p.basename(discReleaseDirectory(discRootPath)))}/'
    '${_foldKeyPart(p.basename(discFolderPath(discRootPath)))}';

/// 键里的一段：与标题键同一折叠口径（全半角、大小写、假名统一）；折叠后为空（全是
/// 标点）时用原文。
String _foldKeyPart(String raw) {
  final String folded = foldMediaTitle(raw);
  return folded.isEmpty ? raw.trim() : folded;
}

/// 本组盘处理完再记成建议的一条「移出」：用户的合集不直接移。
class _PendingRemoval {
  const _PendingRemoval({
    required this.collectionId,
    required this.uid,
    required this.reasonCode,
  });

  final int collectionId;
  final String uid;
  final String reasonCode;
}

/// 被切成集的整条播放列表在库里原有的那一行，以及它迁移前的观看状态。
class _WholeTitleCarry {
  const _WholeTitleCarry({
    required this.row,
    required this.adopted,
    required this.playlist,
    required this.episodePaths,
  });

  /// 迁移前的行快照（断点、看完标记、最后观看时刻取自这里）。
  final VideoBookRow row;

  /// 这一行是否已就地改成第 1 集；false = 第 1 集另有其行，这一行是待回收的重复。
  final bool adopted;

  /// 整条播放列表（未切）。
  final BlurayPlaylist playlist;

  /// 各集的成员路径，按集序。
  final List<String> episodePaths;
}

/// 一组被反向迁移（整卷重新成了标题）的分集行。
class _RevertedEpisodes {
  const _RevertedEpisodes({required this.discRootPath, required this.uids});

  final String discRootPath;

  /// 各集行的 `bookUid`，按 PlayItem 序；第一个就是改回整卷路径的那一行（整卷原有
  /// 其行时它仍是分集）。
  final List<String> uids;
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
