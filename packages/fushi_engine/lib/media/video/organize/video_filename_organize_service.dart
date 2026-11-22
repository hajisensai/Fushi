/// 视频库「整理文件名」的 IO 部分（反馈 ZDYNkAP3Ln）：读刮削身份 → 排计划 →
/// 查做种联动 / 目录合集 / 作品级 sidecar → 执行（失败整条回滚）→ 迁库 → 给出
/// 撤销计划。
///
/// 两种布局（[VideoOrganizeLayout]）：只改文件名；或同时归到来源库根下的规范
/// 目录（`标题 (年份)/[Season XX/]`）。
///
/// 做种不能断：文件若属于下载后端里的种子，改名 / 搬动**必须走引擎**
/// （libtorrent `rename_file` / qBittorrent `renameFile`，即
/// [TorrentBackend.renameFile]，种子内相对路径可以带目录）——引擎自己知道数据换了
/// 位置，继续从新位置读盘上传；直接改磁盘会让下一次校验判文件缺失、整个种子停掉。
/// 引擎只能在种子保存目录**之内**改相对路径，要搬出保存目录的条目判
/// [VideoFilenamePlanStatus.torrentOutsideSaveRoot]，不做。查不清文件是否在做种
/// （后端连不上、后端保存位置映射不到本机）时，计划上标
/// [VideoFilenameTorrentCheck.unverified]，由 UI 明确告诉用户、让用户选，执行时
/// 必须显式传 `allowUnverifiedTorrents`。
///
/// 按目录关联的数据（只在归目录时出现）：
/// - 来源库根：规范目录只建在文件所属的本机来源库根之下，库扫描照旧能找到它；
///   不在任何来源库根下的条目判 [VideoFilenamePlanStatus.outsideLibraryRoot]；
/// - 目录合集（`media_collections.source_folder_path`）：整个合集的成员一起搬进
///   同一个新目录时，合集的目录身份跟着换成新目录键（否则下次扫描会按新目录再建
///   一个合集、旧合集成了空壳）；会把合集拆开的判
///   [VideoFilenamePlanStatus.folderCollectionSplit]；
/// - 作品级 / 季级刮削 sidecar（`tvshow.nfo`、`poster.jpg`、`season.nfo`…，按
///   `video_sidecar_artifacts` 所有权认）：作品（季）的全部条目都在这一批里时
///   跟着搬进新作品（季）目录；
/// - 搬空的旧目录（来源库根之内）顺手删掉，撤销时按需重建。
///
/// 按 bookUid 关联的数据（观看进度、统计、制卡出处——出处链接是 uid + 内容
/// 指纹，与路径无关）本就不随路径变；按路径关联的列由
/// [VideoBookRepository.applyMediaFileMoves] 一处枚举、一个事务迁移。
///
/// 一致性：每个条目「磁盘 → 库」成对完成。磁盘任一步失败，已做的步骤逆序撤回，
/// 库一个字节不动；迁库失败同样撤回磁盘——失败态永远是「这一条什么都没变」。
library;

import 'dart:io';

import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/media_extensions.dart'
    show isAudioOnlyMediaPath;
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart'
    show isBlurayPlaylistPath;
import 'package:fushi_engine/media/video/download/video_download_path_mapping.dart';
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart' show isDvdTitlePath;
import 'package:fushi_engine/media/video/m3u8_playlist.dart'
    show playlistEpisodeCount;
import 'package:fushi_engine/media/video/organize/video_filename_organize.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_folder_group_coordinator.dart'
    show videoAudioAlbumFolderPath, videoSourceFolderPath;
import 'package:fushi_engine/media/video/video_local_files.dart'
    show localVideoFileCandidates, playlistEntryPaths;
import 'package:fushi_engine/media/video/video_path_migration.dart';

/// 计划阶段对「这些文件是否在做种」查到了什么程度。
enum VideoFilenameTorrentCheck {
  /// 本平台 / 本配置没有下载后端：没有种子要保护。
  noBackend,

  /// 已向后端逐个核对；属于种子的文件已标出 [VideoFilenameTorrentLink]。
  verified,

  /// 后端连不上，或有种子的保存位置映射不到本机：说不清。
  unverified,
}

/// 一个文件在下载后端里的身份。
class VideoFilenameTorrentLink {
  const VideoFilenameTorrentLink({
    required this.infoHash,
    required this.fileIndex,
    required this.currentRelativePath,
    required this.newRelativePath,
  });

  final String infoHash;
  final int fileIndex;

  /// 种子内相对路径（POSIX `/`）。
  final String currentRelativePath;
  final String newRelativePath;

  VideoFilenameTorrentLink get inverse => VideoFilenameTorrentLink(
    infoHash: infoHash,
    fileIndex: fileIndex,
    currentRelativePath: newRelativePath,
    newRelativePath: currentRelativePath,
  );
}

/// 一个磁盘文件的身份指纹：大小 + 修改时间（rename 两者都不变；本机与引擎的
/// 改名都只是 rename）。撤销 / 回滚前用它确认「现在躺在搬过去位置上的」仍是
/// 当初搬过去的那个文件，而不是之后被别人放到同名位置上的另一个文件。
class VideoFileFingerprint {
  const VideoFileFingerprint({required this.size, required this.modifiedMs});

  final int size;
  final int modifiedMs;

  /// [path] 上普通文件的指纹；不存在 / 不是普通文件返回 null。
  static Future<VideoFileFingerprint?> of(String path) async {
    final FileStat stat = await FileStat.stat(path);
    if (stat.type != FileSystemEntityType.file) return null;
    return VideoFileFingerprint(
      size: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VideoFileFingerprint &&
      other.size == size &&
      other.modifiedMs == modifiedMs;

  @override
  int get hashCode => Object.hash(size, modifiedMs);

  @override
  String toString() => '$size bytes @ $modifiedMs';
}

/// 计划里的一个文件改名 / 搬动（附做种联动）。
class VideoFilenamePlannedMove {
  const VideoFilenamePlannedMove({
    required this.move,
    this.torrent,
    this.sourceFingerprint,
  });

  final VideoFileMove move;

  /// 非 null = 这个文件在做种，改名走引擎。
  final VideoFilenameTorrentLink? torrent;

  /// 非 null = [VideoFileMove.from] 上必须正是这个文件才搬（撤销 / 回滚步骤
  /// 带着执行时记下的指纹）；对不上就整条失败、不动磁盘。正向计划为 null。
  final VideoFileFingerprint? sourceFingerprint;

  VideoFilenamePlannedMove get inverse => VideoFilenamePlannedMove(
    move: VideoFileMove(from: move.to, to: move.from, isVideo: move.isVideo),
    torrent: torrent?.inverse,
  );
}

/// 一个视频条目的计划。
class VideoFilenameItemPlan {
  const VideoFilenameItemPlan({
    required this.bookUid,
    required this.title,
    required this.status,
    this.moves = const <VideoFilenamePlannedMove>[],
    this.libraryRoot,
  });

  final String bookUid;

  /// 库里显示的条目名（UI 列表用）。
  final String title;
  final VideoFilenamePlanStatus status;
  final List<VideoFilenamePlannedMove> moves;

  /// 归目录时文件所属的来源库根：搬空的旧目录只在它之内清理。只改文件名时
  /// 为 null（目录不变，没有要清理的）。
  final String? libraryRoot;

  bool get isSeeding =>
      moves.any((VideoFilenamePlannedMove m) => m.torrent != null);

  /// 这一条会不会换目录（UI 据此显示新目录）。
  bool get changesDirectory => moves.any(
    (VideoFilenamePlannedMove m) =>
        platformPathKey(p.dirname(m.move.from)) !=
        platformPathKey(p.dirname(m.move.to)),
  );
}

/// 目录合集跟着成员换目录身份（`source_folder_path`）。
class VideoFolderCollectionMove {
  const VideoFolderCollectionMove({
    required this.collectionId,
    required this.collectionName,
    required this.fromKey,
    required this.toKey,
    required this.memberUids,
  });

  final int collectionId;
  final String collectionName;
  final String fromKey;
  final String toKey;

  /// 合集的全部视频成员：全部整理成功才换键。
  final Set<String> memberUids;

  VideoFolderCollectionMove get inverse => VideoFolderCollectionMove(
    collectionId: collectionId,
    collectionName: collectionName,
    fromKey: toKey,
    toKey: fromKey,
    memberUids: memberUids,
  );
}

/// 一次整理的完整计划（预览给用户确认，确认后原样交给 [VideoFilenameOrganizeService.apply]）。
class VideoFilenameOrganizePlan {
  const VideoFilenameOrganizePlan({
    required this.items,
    required this.torrentCheck,
    this.torrentCheckError,
    this.layout = VideoOrganizeLayout.filenameOnly,
    this.folderCollectionMoves = const <VideoFolderCollectionMove>[],
  });

  final List<VideoFilenameItemPlan> items;
  final VideoFilenameTorrentCheck torrentCheck;

  /// [VideoFilenameTorrentCheck.unverified] 的原因（后端原文）。
  final String? torrentCheckError;
  final VideoOrganizeLayout layout;

  /// 跟着成员换目录身份的目录合集（只在归目录时出现）。
  final List<VideoFolderCollectionMove> folderCollectionMoves;

  List<VideoFilenameItemPlan> get ready => <VideoFilenameItemPlan>[
    for (final VideoFilenameItemPlan item in items)
      if (item.status == VideoFilenamePlanStatus.ready) item,
  ];
}

/// 单个条目的执行结果。
class VideoFilenameItemOutcome {
  const VideoFilenameItemOutcome({
    required this.item,
    required this.ok,
    this.error,
    this.rollbackError,
    this.undoMoves = const <VideoFilenamePlannedMove>[],
  });

  final VideoFilenameItemPlan item;
  final bool ok;

  /// 成功时：每一步的逆向（与 [VideoFilenameItemPlan.moves] 同序），带着搬完
  /// 那一刻在目标上量到的 [VideoFilenamePlannedMove.sourceFingerprint]。撤销
  /// 计划按它逆序执行。
  final List<VideoFilenamePlannedMove> undoMoves;

  /// 失败原因（引擎 / 文件系统 / 库的原文）。
  final String? error;

  /// 撤回已做步骤时又失败了（极少见：此时磁盘可能停在半途，必须告诉用户）。
  final String? rollbackError;
}

/// 一次执行的结果。
class VideoFilenameOrganizeResult {
  const VideoFilenameOrganizeResult({
    required this.outcomes,
    this.layout = VideoOrganizeLayout.filenameOnly,
    this.appliedCollectionMoves = const <VideoFolderCollectionMove>[],
    this.collectionErrors = const <String>[],
  });

  final List<VideoFilenameItemOutcome> outcomes;
  final VideoOrganizeLayout layout;

  /// 实际换了目录身份的目录合集。
  final List<VideoFolderCollectionMove> appliedCollectionMoves;

  /// 目录合集换键失败的原文（文件已搬好，合集仍指着旧目录）。
  final List<String> collectionErrors;

  int get renamedCount =>
      outcomes.where((VideoFilenameItemOutcome o) => o.ok).length;

  List<VideoFilenameItemOutcome> get failures => <VideoFilenameItemOutcome>[
    for (final VideoFilenameItemOutcome o in outcomes)
      if (!o.ok) o,
  ];

  /// 撤销计划：成功条目逐文件逆向（做种的仍走引擎），换过键的目录合集换回。
  /// 没有成功条目时为 null。
  VideoFilenameOrganizePlan? get undoPlan {
    final List<VideoFilenameItemPlan> items = <VideoFilenameItemPlan>[
      for (final VideoFilenameItemOutcome o in outcomes)
        if (o.ok)
          VideoFilenameItemPlan(
            bookUid: o.item.bookUid,
            title: o.item.title,
            status: VideoFilenamePlanStatus.ready,
            libraryRoot: o.item.libraryRoot,
            moves: o.undoMoves.reversed.toList(),
          ),
    ];
    if (items.isEmpty) return null;
    return VideoFilenameOrganizePlan(
      items: items,
      torrentCheck: VideoFilenameTorrentCheck.verified,
      layout: layout,
      folderCollectionMoves: <VideoFolderCollectionMove>[
        for (final VideoFolderCollectionMove m in appliedCollectionMoves)
          m.inverse,
      ],
    );
  }
}

/// 计划要求先确认「说不清是否在做种」却没确认就执行。
class VideoFilenameUnverifiedTorrentsException implements Exception {
  const VideoFilenameUnverifiedTorrentsException();

  @override
  String toString() =>
      'torrent linkage is unverified; pass allowUnverifiedTorrents to proceed';
}

/// 整理文件名要不要去问下载后端「这些文件在不在做种」（纯函数，app 接线用）。
///
/// 不问 = 计划标 [VideoFilenameTorrentCheck.noBackend]，直接改磁盘。只有确定
/// 「不可能有种子」时才不问：
/// - 本平台没有下载中心（商店合规）；
/// - 选的是内置引擎、session 还没建、磁盘上也没有任何 fast-resume 文件——内置
///   引擎里一个种子都没有。此时为了改个名去建 session 会绑 6881 并起 DHT
///   （BUG-1053），而且建出来也是空的；
/// - 选的是外接 qBittorrent 但地址没配——连都连不上，问了只会让每次改名都弹
///   「无法确认是否在做种」。
bool videoFilenameOrganizeShouldConsultBackend({
  required bool downloadsAvailable,
  required bool embeddedSelected,
  required bool embeddedSessionAlive,
  required bool embeddedHasResumeFiles,
  required String qbBaseUrl,
  bool remoteHostSelected = false,
}) {
  if (!downloadsAvailable) return false;
  // 借互联设备的引擎：种子在对端，本机无从判断有没有，一律问它。
  if (remoteHostSelected) return true;
  if (embeddedSelected) return embeddedSessionAlive || embeddedHasResumeFiles;
  return qbBaseUrl.trim().isNotEmpty;
}

/// 视频库「整理文件名」服务。
class VideoFilenameOrganizeService {
  VideoFilenameOrganizeService({
    required FushiDatabase database,
    TorrentBackend Function()? backendFactory,
    Future<List<VideoDownloadPathMapping>> Function()? pathMappings,
  }) : _db = database,
       _backendFactory = backendFactory,
       _pathMappings = pathMappings;

  final FushiDatabase _db;

  /// null = 本平台没有下载后端（iOS 商店合规不带下载中心）。
  final TorrentBackend Function()? _backendFactory;
  final Future<List<VideoDownloadPathMapping>> Function()? _pathMappings;

  /// 为 [bookUids] 排计划（只读：不动磁盘、不动库、不动引擎）。
  ///
  /// [customTargets] 里点了名的条目不按刮削身份算规范名，目录 / 文件名用调用方
  /// 给的（[VideoFilenameCustomTarget]，不合法抛 [ArgumentError]）；做种核对、
  /// 目录合集、撞名与来源库根这些门照旧。它们没有身份可认，作品级 / 季级 sidecar
  /// 不跟着搬（逐文件的字幕与 NFO 仍跟）。
  Future<VideoFilenameOrganizePlan> plan(
    Iterable<String> bookUids, {
    VideoOrganizeLayout layout = VideoOrganizeLayout.filenameOnly,
    Map<String, VideoFilenameCustomTarget> customTargets =
        const <String, VideoFilenameCustomTarget>{},
  }) async {
    for (final VideoFilenameCustomTarget target in customTargets.values) {
      final String? reason = invalidVideoCustomTargetReason(target);
      if (reason != null) throw ArgumentError(reason);
    }
    final bool directories = layout == VideoOrganizeLayout.directories;
    // 点名换目录的条目与「归到规范目录」走同一套目录门（库根 / 目录合集）。
    final bool movesDirectories =
        directories ||
        customTargets.values.any(
          (VideoFilenameCustomTarget t) => t.directorySegments != null,
        );
    final Map<String, VideoBookRow> rows = <String, VideoBookRow>{
      for (final VideoBookRow row in await _db.allVideoBooks())
        row.bookUid: row,
    };
    final Map<int, String> sourceRoots = <int, String>{
      if (movesDirectories)
        for (final MediaSourceRow source in await _db.getAllMediaSources())
          if (source.transport == 'local' && source.mediaKind == 'video')
            source.id: source.rootPath,
    };
    final Map<String, List<String>> dirListings = <String, List<String>>{};
    Future<List<String>> listing(String dir) async =>
        dirListings[platformPathKey(dir)] ??= await _listFileNames(dir);
    final Set<String> claimed = <String>{};
    final List<_Draft> drafts = <_Draft>[];
    for (final String uid in <String>{...bookUids}) {
      final VideoBookRow? row = rows[uid];
      if (row == null) continue;
      if (_isDiscEntry(row)) {
        drafts.add(_Draft(row, VideoFilenamePlanStatus.disc));
        continue;
      }
      final List<String> files = _localFiles(row);
      if (files.isEmpty) {
        drafts.add(_Draft(row, VideoFilenamePlanStatus.notLocalFile));
        continue;
      }
      final bool playlist = files.length > 1;
      final VideoFilenameCustomTarget? custom = customTargets[uid];
      final VideoFilenameIdentity? identity = custom == null
          ? await readIdentity(uid)
          : null;
      final String? stem = custom != null
          ? custom.stem
          : identity == null
          ? null
          : canonicalVideoFileStem(identity);
      final List<String>? segments = custom != null
          ? custom.directorySegments
          : identity == null
          ? null
          : canonicalVideoDirectorySegments(identity);
      if (custom == null && (stem == null || segments == null)) {
        drafts.add(_Draft(row, VideoFilenamePlanStatus.noIdentity));
        continue;
      }
      // 这一条换不换目录：规范布局按 [layout]，点名的看它给没给目录。
      final bool toDirectory = custom == null ? directories : segments != null;
      if (playlist && (custom == null ? !directories : stem != null)) {
        drafts.add(
          _Draft(row, VideoFilenamePlanStatus.playlistNeedsDirectories),
        );
        continue;
      }
      String? root;
      String? targetDir;
      if (toDirectory) {
        root = _libraryRootOf(row, files, sourceRoots);
        if (root == null) {
          drafts.add(_Draft(row, VideoFilenamePlanStatus.outsideLibraryRoot));
          continue;
        }
        targetDir = p.joinAll(<String>[root, ...segments!]);
      }
      final List<String> targetNames = targetDir == null
          ? const <String>[]
          : await listing(targetDir);
      VideoFilenamePlanStatus status = VideoFilenamePlanStatus.unchanged;
      final List<VideoFileMove> moves = <VideoFileMove>[];
      final Set<String> itemClaims = <String>{...claimed};
      for (final String file in files) {
        final VideoFilenameItemDraft draft = planVideoFileMoves(
          videoPath: file,
          dirFileNames: await listing(p.dirname(file)),
          targetDirectory: targetDir,
          // 多集播放列表只归目录、保留原文件名（各集没有逐文件的分集绑定）。
          targetStem: playlist ? null : stem,
          targetDirFileNames: targetNames,
          claimedTargets: itemClaims,
        );
        if (draft.status == VideoFilenamePlanStatus.unchanged) continue;
        if (draft.status != VideoFilenamePlanStatus.ready) {
          status = draft.status;
          moves.clear();
          break;
        }
        status = VideoFilenamePlanStatus.ready;
        for (final VideoFileMove move in draft.moves) {
          itemClaims.add(platformPathKey(move.to));
          moves.add(move);
        }
      }
      if (status == VideoFilenamePlanStatus.ready) claimed.addAll(itemClaims);
      drafts.add(
        _Draft(
          row,
          status,
          moves: moves,
          identity: identity,
          libraryRoot: root,
          workDirectory: root == null || segments == null || segments.isEmpty
              ? null
              : p.join(root, segments.first),
        ),
      );
    }

    // 作品级 / 季级 sidecar 先按「全员都在这一批」暂排，一起去问做种；之后条目
    // 可能被做种 / 目录合集挡下，挂靠前再按最终结果复核一遍。
    final List<_ArtifactMove> artifacts = movesDirectories
        ? await _workArtifactMoves(drafts, claimed)
        : const <_ArtifactMove>[];

    final List<String> sources = <String>[
      for (final _Draft d in drafts)
        for (final VideoFileMove m in d.moves) m.from,
      for (final _ArtifactMove a in artifacts) a.move.from,
    ];
    final _TorrentScan scan = await _scanTorrents(sources);
    final Map<String, VideoFilenameTorrentLink?> links =
        <String, VideoFilenameTorrentLink?>{};
    for (final _Draft d in drafts) {
      for (final VideoFileMove m in d.moves) {
        final _TorrentResolution r = scan.resolve(m.from, m.to);
        if (r.outsideSaveRoot) {
          d.block(VideoFilenamePlanStatus.torrentOutsideSaveRoot);
          break;
        }
        links[platformPathKey(m.from)] = r.link;
      }
    }

    final List<VideoFolderCollectionMove> collectionMoves = movesDirectories
        ? await _folderCollectionMoves(drafts, rows.keys.toSet())
        : const <VideoFolderCollectionMove>[];

    // 作品 / 季 sidecar 复核：条目被挡下后「全员都在」可能不再成立。
    final Set<String> readyUids = <String>{
      for (final _Draft d in drafts)
        if (d.status == VideoFilenamePlanStatus.ready) d.row.bookUid,
    };
    for (final _ArtifactMove a in artifacts) {
      if (!a.ownerBooks.every(readyUids.contains)) continue;
      final _TorrentResolution r = scan.resolve(a.move.from, a.move.to);
      if (r.outsideSaveRoot) continue;
      links[platformPathKey(a.move.from)] = r.link;
      final _Draft? host = drafts.lastWhereOrNull(
        (_Draft d) => d.row.bookUid == a.hostUid,
      );
      host?.moves.add(a.move);
    }

    return VideoFilenameOrganizePlan(
      torrentCheck: scan.check,
      torrentCheckError: scan.error,
      layout: layout,
      folderCollectionMoves: collectionMoves,
      items: <VideoFilenameItemPlan>[
        for (final _Draft d in drafts)
          VideoFilenameItemPlan(
            bookUid: d.row.bookUid,
            title: d.row.title,
            status: d.status,
            libraryRoot: d.libraryRoot,
            moves: <VideoFilenamePlannedMove>[
              for (final VideoFileMove m in d.moves)
                VideoFilenamePlannedMove(
                  move: m,
                  torrent: links[platformPathKey(m.from)],
                ),
            ],
          ),
      ],
    );
  }

  /// 执行 [plan] 里 ready 的条目。计划的做种核对是 unverified 时必须显式
  /// [allowUnverifiedTorrents]（用户已在提示里选了「仍然改名」），否则抛
  /// [VideoFilenameUnverifiedTorrentsException]、什么都不做。
  Future<VideoFilenameOrganizeResult> apply(
    VideoFilenameOrganizePlan plan, {
    bool allowUnverifiedTorrents = false,
  }) async {
    if (plan.torrentCheck == VideoFilenameTorrentCheck.unverified &&
        !allowUnverifiedTorrents) {
      throw const VideoFilenameUnverifiedTorrentsException();
    }
    final List<VideoFilenameItemPlan> ready = plan.ready;
    final bool needsBackend = ready.any(
      (VideoFilenameItemPlan item) => item.isSeeding,
    );
    final TorrentBackend? backend = needsBackend
        ? _backendFactory?.call()
        : null;
    final VideoBookRepository repo = VideoBookRepository(_db);
    final List<VideoFilenameItemOutcome> outcomes =
        <VideoFilenameItemOutcome>[];
    try {
      for (final VideoFilenameItemPlan item in ready) {
        outcomes.add(await _applyItem(item, backend, repo));
      }
    } finally {
      backend?.close();
    }
    final Set<String> succeeded = <String>{
      for (final VideoFilenameItemOutcome o in outcomes)
        if (o.ok) o.item.bookUid,
    };
    final List<VideoFolderCollectionMove> applied =
        <VideoFolderCollectionMove>[];
    final List<String> collectionErrors = <String>[];
    for (final VideoFolderCollectionMove move in plan.folderCollectionMoves) {
      // 有成员没搬成：合集横跨新旧两个目录，换不换键都不对，保持原样（失败
      // 条目已逐条报给用户）。
      if (!move.memberUids.every(succeeded.contains)) continue;
      try {
        await (_db.update(_db.mediaCollections)..where(
              (tbl) =>
                  tbl.id.equals(move.collectionId) &
                  tbl.sourceFolderPath.equals(move.fromKey),
            ))
            .write(
              MediaCollectionsCompanion(
                sourceFolderPath: Value<String?>(move.toKey),
              ),
            );
        applied.add(move);
      } catch (e) {
        collectionErrors.add('${move.collectionName}: $e');
      }
    }
    if (succeeded.isNotEmpty) _db.notifyVideoLibraryChanged();
    return VideoFilenameOrganizeResult(
      outcomes: outcomes,
      layout: plan.layout,
      appliedCollectionMoves: applied,
      collectionErrors: collectionErrors,
    );
  }

  Future<VideoFilenameItemOutcome> _applyItem(
    VideoFilenameItemPlan item,
    TorrentBackend? backend,
    VideoBookRepository repo,
  ) async {
    // 已做步骤的逆向（同序），带着搬完那一刻在目标上量到的指纹：回滚与撤销
    // 都只搬回「仍是当初搬过去的那个文件」。
    final List<VideoFilenamePlannedMove> done = <VideoFilenamePlannedMove>[];
    String? error;
    for (final VideoFilenamePlannedMove step in item.moves) {
      error = await _move(step, backend);
      if (error != null) break;
      final VideoFilenamePlannedMove inverse = step.inverse;
      done.add(
        VideoFilenamePlannedMove(
          move: inverse.move,
          torrent: inverse.torrent,
          sourceFingerprint: await VideoFileFingerprint.of(step.move.to),
        ),
      );
    }
    if (error == null) {
      try {
        await repo.applyMediaFileMoves(
          moved: MovedMediaFiles(<String, String>{
            for (final VideoFilenamePlannedMove m in item.moves)
              m.move.from: m.move.to,
          }),
          torrentRenames: <TorrentFileRenameRecord>[
            for (final VideoFilenamePlannedMove m in item.moves)
              if (m.torrent != null)
                TorrentFileRenameRecord(
                  infoHash: m.torrent!.infoHash,
                  fileIndex: m.torrent!.fileIndex,
                  newRelativePath: m.torrent!.newRelativePath,
                ),
          ],
        );
        await _removeEmptiedDirectories(item, <String>[
          for (final VideoFilenamePlannedMove m in item.moves) m.move.from,
        ]);
        return VideoFilenameItemOutcome(
          item: item,
          ok: true,
          undoMoves: List<VideoFilenamePlannedMove>.unmodifiable(done),
        );
      } catch (e) {
        error = '$e';
      }
    }
    // 逆序撤回已做的步骤：失败态 = 这一条什么都没变。
    final List<String> rollbackErrors = <String>[];
    for (final VideoFilenamePlannedMove step in done.reversed) {
      final String? undoError = await _move(step, backend);
      if (undoError != null) rollbackErrors.add(undoError);
    }
    // 撤回后新建的规范目录可能空着。
    await _removeEmptiedDirectories(item, <String>[
      for (final VideoFilenamePlannedMove m in done) m.move.from,
    ]);
    return VideoFilenameItemOutcome(
      item: item,
      ok: false,
      error: error,
      rollbackError: rollbackErrors.isEmpty ? null : rollbackErrors.join('; '),
    );
  }

  /// 删掉被搬空的目录（只在 [VideoFilenameItemPlan.libraryRoot] 之内、只删真的
  /// 空了的；非递归删除，目录里还有别的东西就保留）。
  Future<void> _removeEmptiedDirectories(
    VideoFilenameItemPlan item,
    List<String> vacated,
  ) async {
    final String? root = item.libraryRoot;
    if (root == null || vacated.isEmpty) return;
    for (final String dir in emptiedDirectoryCandidates(vacated, root)) {
      final Directory directory = Directory(dir);
      if (!await directory.exists()) continue;
      if (!await directory.list(followLinks: false).isEmpty) continue;
      try {
        await directory.delete();
      } on FileSystemException {
        // 空目录删不掉（权限 / 句柄占用）只是留一个空目录，不影响整理结果；
        // 不能为它把已经成对完成的「磁盘 + 库」整条回滚。
      }
    }
  }

  /// 本 isolate 里正在被某一步搬入的目标（[platformPathKey]）。整理 / 搬动 /
  /// 回滚 / 撤销可以被 ctl 与库页对话框各自独立发起、互相交错；同一个目标
  /// 同时只许一步在「确认空着 → 搬进去」之间，另一步直接判占用。
  static final Set<String> _targetsInFlight = <String>{};

  /// 执行一步改名 / 搬动；成功返回 null，失败返回原因。
  ///
  /// 不覆盖语义（HBK-AUDIT-031）：`File.rename` 在 POSIX（rename(2)）与
  /// Windows（Dart 用 `MoveFileExW(MOVEFILE_REPLACE_EXISTING)`）上都会静默
  /// 覆盖已有目标，所以「先查目标空着、再 rename」中间被别人搬进来的文件会被
  /// 冲掉。本机搬动先用独占创建（O_EXCL / CREATE_NEW，原子）在目标上占一个
  /// 空占位，占到了才把源 rename 到自己的占位上；占不到 = 目标被占，整步失败。
  /// 引擎改名（做种文件）由引擎动磁盘，没法先放占位，靠 [_targetsInFlight]
  /// 与进程内其他步骤互斥（本机搬动同样登记，两条路径不会撞进同一个目标）。
  Future<String?> _move(
    VideoFilenamePlannedMove step,
    TorrentBackend? backend,
  ) async {
    final VideoFileMove move = step.move;
    // 大小写不同的同名（Windows 上是同一个文件）：改的就是它自己，不算占用。
    final bool sameEntry =
        platformPathKey(move.from) == platformPathKey(move.to);
    final String targetKey = platformPathKey(move.to);
    if (!sameEntry && !_targetsInFlight.add(targetKey)) {
      return 'target is being written by another move: ${move.to}';
    }
    try {
      // 撤销 / 回滚：源位置上必须仍是当初搬过去的那个文件。
      final VideoFileFingerprint? expected = step.sourceFingerprint;
      if (expected != null) {
        final VideoFileFingerprint? actual = await VideoFileFingerprint.of(
          move.from,
        );
        if (actual != expected) {
          return 'not the file that was moved here '
              '(expected $expected, found ${actual ?? 'nothing'}): ${move.from}';
        }
      }
      final VideoFilenameTorrentLink? torrent = step.torrent;
      if (torrent != null) {
        if (!sameEntry &&
            await FileSystemEntity.type(move.to, followLinks: false) !=
                FileSystemEntityType.notFound) {
          return 'target already exists: ${move.to}';
        }
        if (backend == null) return 'download backend is unavailable';
        try {
          final TorrentStorageResult result = await backend.renameFile(
            torrent.infoHash,
            torrent.fileIndex,
            torrent.newRelativePath,
          );
          return result.ok
              ? null
              : (result.error ?? 'backend refused the rename');
        } catch (e) {
          return '$e';
        }
      }
      if (sameEntry) return await _renameLocal(move);
      try {
        await Directory(p.dirname(move.to)).create(recursive: true);
        await File(move.to).create(exclusive: true);
      } on FileSystemException catch (e) {
        if (await FileSystemEntity.type(move.to, followLinks: false) !=
            FileSystemEntityType.notFound) {
          return 'target already exists: ${move.to}';
        }
        return _describeFsError(e, move.to);
      }
      final String? error = await _renameLocal(move);
      if (error == null) return null;
      // 没搬进去：收回自己的空占位（占位期间别人进不来，目标上只会是它）。
      try {
        await File(move.to).delete();
      } on FileSystemException catch (e) {
        return '$error; empty placeholder left behind: '
            '${_describeFsError(e, move.to)}';
      }
      return error;
    } finally {
      if (!sameEntry) _targetsInFlight.remove(targetKey);
    }
  }

  static Future<String?> _renameLocal(VideoFileMove move) async {
    try {
      await File(move.from).rename(move.to);
      return null;
    } on FileSystemException catch (e) {
      return _describeFsError(e, move.from);
    }
  }

  static String _describeFsError(FileSystemException e, String path) =>
      '${e.message}: ${e.path ?? path}'
      '${e.osError == null ? '' : ' (${e.osError!.message})'}';

  /// 读 [bookUid] 的刮削身份：绑到分集 → 剧集（作品名 + 季 + 集）；作品直接
  /// 绑这个文件且不是电视剧 → 电影；其余（未刮削、特典、只有作品）→ null。
  Future<VideoFilenameIdentity?> readIdentity(String bookUid) async {
    final List<VideoMetadataEpisodeRow> episodes = await _db
        .getVideoMetadataEpisodesByBook(bookUid);
    if (episodes.isNotEmpty) {
      final int seasonId = episodes.first.seasonId;
      final VideoMetadataSeasonRow? season = await (_db.select(
        _db.videoMetadataSeasons,
      )..where((tbl) => tbl.id.equals(seasonId))).getSingleOrNull();
      if (season == null) return null;
      final VideoMetadataWorkRow? work = await _db.getVideoMetadataWorkById(
        season.workId,
      );
      if (work == null || work.title.trim().isEmpty) return null;
      return VideoFilenameIdentity(
        title: work.title,
        year: work.year,
        seasonNumber: season.seasonNumber,
        workId: work.id,
        seasonId: season.id,
        spansMultipleSeasons: episodes.any(
          (VideoMetadataEpisodeRow e) => e.seasonId != seasonId,
        ),
        episodeNumbers: <int>[
          for (final VideoMetadataEpisodeRow e in episodes)
            if (e.seasonId == seasonId) e.episodeNumber,
        ],
      );
    }
    final VideoMetadataWorkRow? work = await _db.getVideoMetadataWorkByBook(
      bookUid,
    );
    if (work == null || work.mediaType == 'tv' || work.title.trim().isEmpty) {
      return null;
    }
    return VideoFilenameIdentity(
      title: work.title,
      year: work.year,
      workId: work.id,
    );
  }

  static bool _isDiscEntry(VideoBookRow row) => <String>[
    row.videoPath,
    ...playlistEntryPaths(row.playlistJson),
  ].any((String path) => isBlurayPlaylistPath(path) || isDvdTitlePath(path));

  /// 条目在本机的视频文件：单文件条目就是 `videoPath`；多集播放列表是各集
  /// 路径。流媒体 / 远端条目、播放列表里混着非本机集的返回空表。
  static List<String> _localFiles(VideoBookRow row) {
    final List<String> candidates = localVideoFileCandidates(
      videoPath: row.videoPath,
      playlistJson: row.playlistJson,
    );
    if (playlistEpisodeCount(row.playlistJson) >= 2) {
      final List<String> entries = playlistEntryPaths(row.playlistJson);
      // 有一集不是本机文件（混着流媒体）：搬一半等于拆散播放列表。
      if (candidates.length < entries.toSet().length) return const <String>[];
      return <String>[
        for (final String path in candidates) p.normalize(path.trim()),
      ];
    }
    if (candidates.length != 1) return const <String>[];
    if (platformPathKey(candidates.single) != platformPathKey(row.videoPath)) {
      return const <String>[];
    }
    return <String>[p.normalize(row.videoPath.trim())];
  }

  /// 条目所属的来源库根：优先它自己的来源（`sourceId`），否则取包含它的最深
  /// 来源库根；全部文件必须落在同一个根下。
  static String? _libraryRootOf(
    VideoBookRow row,
    List<String> files,
    Map<int, String> sourceRoots,
  ) {
    final String? own = row.sourceId == null ? null : sourceRoots[row.sourceId];
    final String? root =
        own != null && containingLibraryRoot(files.first, <String>[own]) != null
        ? p.normalize(own)
        : containingLibraryRoot(files.first, sourceRoots.values);
    if (root == null) return null;
    for (final String file in files) {
      if (!p.isWithin(platformPathKey(root), platformPathKey(file))) {
        return null;
      }
    }
    return root;
  }

  static Future<List<String>> _listFileNames(String dir) async {
    try {
      return <String>[
        await for (final FileSystemEntity entity in Directory(
          dir,
        ).list(followLinks: false))
          if (entity is File) p.basename(entity.path),
      ];
    } on FileSystemException {
      return const <String>[];
    }
  }

  /// 归目录时作品级 / 季级刮削 sidecar 的搬动（按 `video_sidecar_artifacts`
  /// 所有权认）。只排「作品（季）绑定的全部条目都在这一批」的；挂到该作品在
  /// 这一批里的最后一个条目上（与它同生共死：它失败回滚时这些也撤回）。
  Future<List<_ArtifactMove>> _workArtifactMoves(
    List<_Draft> drafts,
    Set<String> claimed,
  ) async {
    final Map<int, List<_Draft>> byWork = <int, List<_Draft>>{};
    for (final _Draft d in drafts) {
      final int? workId = d.identity?.workId;
      if (d.status != VideoFilenamePlanStatus.ready || workId == null) continue;
      (byWork[workId] ??= <_Draft>[]).add(d);
    }
    final List<_ArtifactMove> out = <_ArtifactMove>[];
    for (final MapEntry<int, List<_Draft>> entry in byWork.entries) {
      final List<_Draft> members = entry.value;
      final String? workDir = members.first.workDirectory;
      if (workDir == null ||
          members.any(
            (_Draft d) =>
                d.workDirectory == null ||
                platformPathKey(d.workDirectory!) != platformPathKey(workDir),
          )) {
        continue;
      }
      final String hostUid = members.last.row.bookUid;
      final List<VideoMetadataSeasonRow> seasons = await (_db.select(
        _db.videoMetadataSeasons,
      )..where((tbl) => tbl.workId.equals(entry.key))).get();
      final Map<int, Set<String>> seasonBooks = <int, Set<String>>{};
      final Set<String> workBooks = <String>{};
      final VideoMetadataWorkRow? work = await _db.getVideoMetadataWorkById(
        entry.key,
      );
      if (work?.bookUid case final String uid) workBooks.add(uid);
      for (final VideoMetadataSeasonRow season in seasons) {
        final List<VideoMetadataEpisodeRow> episodes = await (_db.select(
          _db.videoMetadataEpisodes,
        )..where((tbl) => tbl.seasonId.equals(season.id))).get();
        final Set<String> books = <String>{
          for (final VideoMetadataEpisodeRow e in episodes)
            if (e.bookUid != null) e.bookUid!,
        };
        seasonBooks[season.id] = books;
        workBooks.addAll(books);
      }
      final Map<int, int> seasonNumbers = <int, int>{
        for (final VideoMetadataSeasonRow s in seasons) s.id: s.seasonNumber,
      };
      final List<VideoSidecarArtifactRow> owned =
          await (_db.select(_db.videoSidecarArtifacts)..where(
                (tbl) =>
                    tbl.workId.equals(entry.key) |
                    tbl.seasonId.isIn(seasonNumbers.keys),
              ))
              .get();
      for (final VideoSidecarArtifactRow artifact in owned) {
        final int? seasonId = artifact.seasonId;
        final Set<String> owners = seasonId == null
            ? workBooks
            : seasonBooks[seasonId] ?? const <String>{};
        if (owners.isEmpty) continue;
        final String name = p.basename(artifact.path);
        final String targetDir =
            seasonId == null || seasonSidecarBelongsInWorkDirectory(name)
            ? workDir
            : p.join(
                workDir,
                canonicalVideoSeasonDirectoryName(seasonNumbers[seasonId]!),
              );
        final String from = p.normalize(artifact.path);
        final String to = p.join(targetDir, name);
        if (platformPathKey(from) == platformPathKey(to)) continue;
        if (!await File(from).exists()) continue;
        if (claimed.contains(platformPathKey(to)) ||
            await FileSystemEntity.type(to, followLinks: false) !=
                FileSystemEntityType.notFound) {
          continue;
        }
        claimed.add(platformPathKey(to));
        out.add(
          _ArtifactMove(
            move: VideoFileMove(from: from, to: to, isVideo: false),
            ownerBooks: owners,
            hostUid: hostUid,
          ),
        );
      }
    }
    return out;
  }

  /// 归目录时目录合集的去向（不动点迭代：一条被挡下可能让另一个合集也凑不齐）。
  Future<List<VideoFolderCollectionMove>> _folderCollectionMoves(
    List<_Draft> drafts,
    Set<String> libraryUids,
  ) async {
    final List<MediaCollectionRow> folderCollections = <MediaCollectionRow>[
      for (final MediaCollectionRow c in await _db.getAllMediaCollections())
        if (c.sourceFolderPath != null) c,
    ];
    if (folderCollections.isEmpty) return const <VideoFolderCollectionMove>[];
    final Map<int, Set<String>> membersOf = <int, Set<String>>{};
    for (final MediaCollectionItemRow item
        in await _db.getAllCollectionItems()) {
      if (item.mediaType != MediaKind.video.dbValue) continue;
      // 成员行指着已删的条目（跨端残留）：它不在本机磁盘上，不算「没跟着走」。
      if (!libraryUids.contains(item.entryKey)) continue;
      (membersOf[item.collectionId] ??= <String>{}).add(item.entryKey);
    }
    final Set<String> heldKeys = <String>{
      for (final MediaCollectionRow c in folderCollections) c.sourceFolderPath!,
    };
    while (true) {
      final Map<String, _Draft> ready = <String, _Draft>{
        for (final _Draft d in drafts)
          if (d.status == VideoFilenamePlanStatus.ready) d.row.bookUid: d,
      };
      final List<VideoFolderCollectionMove> moves =
          <VideoFolderCollectionMove>[];
      final Set<String> blocked = <String>{};
      final Map<String, int> claimedKeys = <String, int>{};
      for (final MediaCollectionRow collection in folderCollections) {
        final String key = collection.sourceFolderPath!;
        final Set<String> members = membersOf[collection.id] ?? <String>{};
        final List<_Draft> moving = <_Draft>[
          for (final String uid in members)
            if (ready[uid] case final _Draft d) d,
        ];
        if (moving.isEmpty) continue;
        final Set<String?> newKeys = <String?>{
          for (final _Draft d in moving) _newFolderKey(d, key),
        };
        // 成员按这个键没归到这个合集（合集键早已与目录脱钩）：不跟。
        if (newKeys.contains(null)) continue;
        if (newKeys.length == 1 && newKeys.single == key) continue;
        final bool whole = moving.length == members.length;
        final String? target = newKeys.length == 1 ? newKeys.single : null;
        final bool targetFree =
            target != null &&
            !heldKeys.contains(target) &&
            !claimedKeys.containsKey(target);
        if (whole && targetFree) {
          claimedKeys[target] = collection.id;
          moves.add(
            VideoFolderCollectionMove(
              collectionId: collection.id,
              collectionName: collection.name,
              fromKey: key,
              toKey: target,
              memberUids: members,
            ),
          );
        } else {
          for (final _Draft d in moving) {
            blocked.add(d.row.bookUid);
          }
        }
      }
      if (blocked.isEmpty) return moves;
      for (final _Draft d in drafts) {
        if (blocked.contains(d.row.bookUid)) {
          d.block(VideoFilenamePlanStatus.folderCollectionSplit);
        }
      }
    }
  }

  /// 条目搬完后在 [oldKey] 那种口径下的新目录键；按这个口径它本不属于
  /// [oldKey] 时返回 null。
  static String? _newFolderKey(_Draft d, String oldKey) {
    // 目录键按 `videoPath` 算（与目录分组同一口径）；多集播放列表的第一集可能
    // 本来就在规范目录里、不在搬动清单上。
    final String from = p.normalize(d.row.videoPath.trim());
    final String to =
        d.moves
            .lastWhereOrNull(
              (VideoFileMove m) =>
                  platformPathKey(m.from) == platformPathKey(from),
            )
            ?.to ??
        from;
    if (isAudioOnlyMediaPath(from)) {
      return videoAudioAlbumFolderPath(from) == oldKey
          ? videoAudioAlbumFolderPath(to)
          : null;
    }
    final String? root = d.libraryRoot;
    if (root == null) return null;
    try {
      return videoSourceFolderPath(from, root) == oldKey
          ? videoSourceFolderPath(to, root)
          : null;
    } on ArgumentError {
      return null;
    }
  }

  /// 向下载后端核对 [sources] 里哪些文件属于种子。
  Future<_TorrentScan> _scanTorrents(List<String> sources) async {
    final TorrentBackend Function()? factory = _backendFactory;
    if (factory == null) {
      return const _TorrentScan(VideoFilenameTorrentCheck.noBackend);
    }
    if (sources.isEmpty) {
      return const _TorrentScan(VideoFilenameTorrentCheck.verified);
    }
    final Set<String> wanted = <String>{
      for (final String source in sources) platformPathKey(source),
    };
    final Map<String, _LinkSeed> links = <String, _LinkSeed>{};
    final List<String> unmapped = <String>[];
    TorrentBackend? backend;
    try {
      backend = factory();
      final List<VideoDownloadPathMapping> configured =
          await _pathMappings?.call() ?? const <VideoDownloadPathMapping>[];
      for (final TorrentSnapshot torrent in await backend.listTorrents()) {
        final String remote = torrent.savePath.trim();
        if (remote.isEmpty) continue;
        final String? local = videoDownloadRemoteToLocal(
          effectiveVideoDownloadPathMappings(
            configured,
            sameMachineAnchors: <String?>[remote],
          ),
          remote,
        );
        if (local == null) {
          unmapped.add(torrent.name.isEmpty ? torrent.hash : torrent.name);
          continue;
        }
        final String root = p.normalize(p.absolute(local));
        if (!sources.any((String s) => p.isWithin(root, s))) {
          continue;
        }
        for (final TorrentFileEntry file in await backend.listFiles(
          torrent.hash,
        )) {
          final String relative = file.name.replaceAll(r'\', '/');
          final String key = platformPathKey(
            p.joinAll(<String>[root, ...p.posix.split(relative)]),
          );
          if (wanted.contains(key)) {
            links[key] = _LinkSeed(torrent.hash, file.index, relative, root);
          }
        }
      }
    } catch (e) {
      return _TorrentScan(
        VideoFilenameTorrentCheck.unverified,
        error: '$e',
        links: links,
      );
    } finally {
      backend?.close();
    }
    if (unmapped.isNotEmpty) {
      return _TorrentScan(
        VideoFilenameTorrentCheck.unverified,
        error: 'not reachable on this device: ${unmapped.join(', ')}',
        links: links,
      );
    }
    return _TorrentScan(VideoFilenameTorrentCheck.verified, links: links);
  }
}

class _Draft {
  _Draft(
    this.row,
    this.status, {
    List<VideoFileMove>? moves,
    this.identity,
    this.libraryRoot,
    this.workDirectory,
  }) : moves = moves ?? <VideoFileMove>[];

  final VideoBookRow row;
  VideoFilenamePlanStatus status;
  final List<VideoFileMove> moves;
  final VideoFilenameIdentity? identity;
  final String? libraryRoot;

  /// 归目录时的规范作品目录（`<库根>/标题 (年份)`）。
  final String? workDirectory;

  void block(VideoFilenamePlanStatus reason) {
    status = reason;
    moves.clear();
  }
}

class _ArtifactMove {
  const _ArtifactMove({
    required this.move,
    required this.ownerBooks,
    required this.hostUid,
  });

  final VideoFileMove move;

  /// 这个 sidecar 所属作品（季）绑定的全部条目：全部都要整理才搬。
  final Set<String> ownerBooks;

  /// 挂靠的条目（该作品在这一批里的最后一条）。
  final String hostUid;
}

class _LinkSeed {
  const _LinkSeed(this.infoHash, this.fileIndex, this.relativePath, this.root);

  final String infoHash;
  final int fileIndex;
  final String relativePath;

  /// 种子保存目录（本机坐标）。
  final String root;
}

class _TorrentResolution {
  const _TorrentResolution({this.link, this.outsideSaveRoot = false});

  final VideoFilenameTorrentLink? link;
  final bool outsideSaveRoot;
}

class _TorrentScan {
  const _TorrentScan(
    this.check, {
    this.error,
    this.links = const <String, _LinkSeed>{},
  });

  final VideoFilenameTorrentCheck check;
  final String? error;
  final Map<String, _LinkSeed> links;

  /// [source] 在种子里时，搬到 [target] 的引擎侧改名（种子内相对路径，可以
  /// 换目录）；[target] 在保存目录之外时标 [_TorrentResolution.outsideSaveRoot]。
  _TorrentResolution resolve(String source, String target) {
    final _LinkSeed? seed = links[platformPathKey(source)];
    if (seed == null) return const _TorrentResolution();
    if (!p.isWithin(platformPathKey(seed.root), platformPathKey(target))) {
      return const _TorrentResolution(outsideSaveRoot: true);
    }
    final String abs = p.normalize(p.absolute(target));
    final String rootAbs = p.normalize(p.absolute(seed.root));
    // 大小写只差在根上（Windows）时 `p.relative` 会绕出 `..`，按长度截取。
    final String relative =
        (p.isWithin(rootAbs, abs)
                ? p.relative(abs, from: rootAbs)
                : abs
                      .substring(rootAbs.length)
                      .replaceFirst(RegExp(r'^[\\/]+'), ''))
            .replaceAll(r'\', '/');
    return _TorrentResolution(
      link: VideoFilenameTorrentLink(
        infoHash: seed.infoHash,
        fileIndex: seed.fileIndex,
        currentRelativePath: seed.relativePath,
        newRelativePath: relative,
      ),
    );
  }
}

extension<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (int i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}
