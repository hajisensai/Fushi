/// 视频库「整理文件名」的 IO 部分（反馈 ZDYNkAP3Ln）：读刮削身份 → 排计划 →
/// 查做种联动 → 执行（失败整条回滚）→ 迁库 → 给出撤销计划。
///
/// 做种不能断：文件若属于下载后端里的种子，改名**必须走引擎**
/// （libtorrent `rename_file` / qBittorrent `renameFile`，即
/// [TorrentBackend.renameFile]）——引擎自己知道数据换了名字，继续从新名字读盘
/// 上传；直接改磁盘会让下一次校验判文件缺失、整个种子停掉。查不清文件是否在
/// 做种（后端连不上、后端保存位置映射不到本机）时，计划上标
/// [VideoFilenameTorrentCheck.unverified]，由 UI 明确告诉用户、让用户选，执行时
/// 必须显式传 `allowUnverifiedTorrents`。
///
/// 一致性：每个条目「磁盘 → 库」成对完成。磁盘任一步失败，已做的步骤逆序撤回，
/// 库一个字节不动；迁库失败同样撤回磁盘——失败态永远是「这一条什么都没变」。
/// 库迁移走 [VideoBookRepository.applyMediaFileMoves]，与下载改名 / 移动共用
/// 同一处路径列清单。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/download/video_download_path_mapping.dart';
import 'package:fushi_engine/media/video/m3u8_playlist.dart'
    show playlistEpisodeCount;
import 'package:fushi_engine/media/video/organize/video_filename_organize.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_local_files.dart'
    show localVideoFileCandidates;
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

/// 计划里的一个文件改名（附做种联动）。
class VideoFilenamePlannedMove {
  const VideoFilenamePlannedMove({required this.move, this.torrent});

  final VideoFileMove move;

  /// 非 null = 这个文件在做种，改名走引擎。
  final VideoFilenameTorrentLink? torrent;

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
  });

  final String bookUid;

  /// 库里显示的条目名（UI 列表用）。
  final String title;
  final VideoFilenamePlanStatus status;
  final List<VideoFilenamePlannedMove> moves;

  bool get isSeeding =>
      moves.any((VideoFilenamePlannedMove m) => m.torrent != null);
}

/// 一次整理的完整计划（预览给用户确认，确认后原样交给 [VideoFilenameOrganizeService.apply]）。
class VideoFilenameOrganizePlan {
  const VideoFilenameOrganizePlan({
    required this.items,
    required this.torrentCheck,
    this.torrentCheckError,
  });

  final List<VideoFilenameItemPlan> items;
  final VideoFilenameTorrentCheck torrentCheck;

  /// [VideoFilenameTorrentCheck.unverified] 的原因（后端原文）。
  final String? torrentCheckError;

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
  });

  final VideoFilenameItemPlan item;
  final bool ok;

  /// 失败原因（引擎 / 文件系统 / 库的原文）。
  final String? error;

  /// 撤回已做步骤时又失败了（极少见：此时磁盘可能停在半途，必须告诉用户）。
  final String? rollbackError;
}

/// 一次执行的结果。
class VideoFilenameOrganizeResult {
  const VideoFilenameOrganizeResult({required this.outcomes});

  final List<VideoFilenameItemOutcome> outcomes;

  int get renamedCount =>
      outcomes.where((VideoFilenameItemOutcome o) => o.ok).length;

  List<VideoFilenameItemOutcome> get failures => <VideoFilenameItemOutcome>[
    for (final VideoFilenameItemOutcome o in outcomes)
      if (!o.ok) o,
  ];

  /// 撤销计划：成功条目逐文件逆向（做种的仍走引擎）。没有成功条目时为 null。
  VideoFilenameOrganizePlan? get undoPlan {
    final List<VideoFilenameItemPlan> items = <VideoFilenameItemPlan>[
      for (final VideoFilenameItemOutcome o in outcomes)
        if (o.ok)
          VideoFilenameItemPlan(
            bookUid: o.item.bookUid,
            title: o.item.title,
            status: VideoFilenamePlanStatus.ready,
            moves: <VideoFilenamePlannedMove>[
              for (final VideoFilenamePlannedMove m in o.item.moves) m.inverse,
            ],
          ),
    ];
    if (items.isEmpty) return null;
    return VideoFilenameOrganizePlan(
      items: items,
      torrentCheck: VideoFilenameTorrentCheck.verified,
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
}) {
  if (!downloadsAvailable) return false;
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
  Future<VideoFilenameOrganizePlan> plan(Iterable<String> bookUids) async {
    final Map<String, VideoBookRow> rows = <String, VideoBookRow>{
      for (final VideoBookRow row in await _db.allVideoBooks())
        row.bookUid: row,
    };
    final Map<String, List<String>> dirListings = <String, List<String>>{};
    final Set<String> claimed = <String>{};
    final List<_Draft> drafts = <_Draft>[];
    for (final String uid in <String>{...bookUids}) {
      final VideoBookRow? row = rows[uid];
      if (row == null) continue;
      final String? path = _singleLocalFile(row);
      if (path == null) {
        drafts.add(_Draft(row, VideoFilenamePlanStatus.notLocalFile));
        continue;
      }
      final VideoFilenameIdentity? identity = await readIdentity(uid);
      final String? stem = identity == null
          ? null
          : canonicalVideoFileStem(identity);
      if (stem == null) {
        drafts.add(_Draft(row, VideoFilenamePlanStatus.noIdentity));
        continue;
      }
      final String dir = p.dirname(path);
      final List<String> names = dirListings[platformPathKey(dir)] ??=
          await _listFileNames(dir);
      final VideoFilenameItemDraft draft = planVideoFilenameMoves(
        videoPath: path,
        targetStem: stem,
        dirFileNames: names,
        claimedTargets: claimed,
      );
      for (final VideoFileMove move in draft.moves) {
        claimed.add(platformPathKey(move.to));
      }
      drafts.add(_Draft(row, draft.status, draft.moves));
    }

    final List<String> sources = <String>[
      for (final _Draft d in drafts)
        for (final VideoFileMove m in d.moves) m.from,
    ];
    final _TorrentScan scan = await _scanTorrents(sources);
    return VideoFilenameOrganizePlan(
      torrentCheck: scan.check,
      torrentCheckError: scan.error,
      items: <VideoFilenameItemPlan>[
        for (final _Draft d in drafts)
          VideoFilenameItemPlan(
            bookUid: d.row.bookUid,
            title: d.row.title,
            status: d.status,
            moves: <VideoFilenamePlannedMove>[
              for (final VideoFileMove m in d.moves)
                VideoFilenamePlannedMove(
                  move: m,
                  torrent: scan.linkFor(m.from, p.basename(m.to)),
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
    if (outcomes.any((VideoFilenameItemOutcome o) => o.ok)) {
      _db.notifyVideoLibraryChanged();
    }
    return VideoFilenameOrganizeResult(outcomes: outcomes);
  }

  Future<VideoFilenameItemOutcome> _applyItem(
    VideoFilenameItemPlan item,
    TorrentBackend? backend,
    VideoBookRepository repo,
  ) async {
    final List<VideoFilenamePlannedMove> done = <VideoFilenamePlannedMove>[];
    String? error;
    for (final VideoFilenamePlannedMove step in item.moves) {
      error = await _move(step, backend);
      if (error != null) break;
      done.add(step);
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
        return VideoFilenameItemOutcome(item: item, ok: true);
      } catch (e) {
        error = '$e';
      }
    }
    // 逆序撤回已做的步骤：失败态 = 这一条什么都没变。
    final List<String> rollbackErrors = <String>[];
    for (final VideoFilenamePlannedMove step in done.reversed) {
      final String? undoError = await _move(step.inverse, backend);
      if (undoError != null) rollbackErrors.add(undoError);
    }
    return VideoFilenameItemOutcome(
      item: item,
      ok: false,
      error: error,
      rollbackError: rollbackErrors.isEmpty ? null : rollbackErrors.join('; '),
    );
  }

  /// 执行一步改名；成功返回 null，失败返回原因。
  Future<String?> _move(
    VideoFilenamePlannedMove step,
    TorrentBackend? backend,
  ) async {
    final VideoFileMove move = step.move;
    // 目标已被别的文件占着就不动：引擎的 rename 与 `File.rename` 在部分平台上
    // 都会静默覆盖。大小写不同的同名（Windows 上是同一个文件）不算占用。
    if (platformPathKey(move.from) != platformPathKey(move.to) &&
        await FileSystemEntity.type(move.to, followLinks: false) !=
            FileSystemEntityType.notFound) {
      return 'target already exists: ${move.to}';
    }
    final VideoFilenameTorrentLink? torrent = step.torrent;
    if (torrent != null) {
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
    try {
      await File(move.from).rename(move.to);
      return null;
    } on FileSystemException catch (e) {
      return '${e.message}: ${e.path ?? move.from}'
          '${e.osError == null ? '' : ' (${e.osError!.message})'}';
    }
  }

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
    return VideoFilenameIdentity(title: work.title, year: work.year);
  }

  /// 单个本机文件的视频才整理：多集播放列表 / 光盘 / 流媒体一律不碰。
  static String? _singleLocalFile(VideoBookRow row) {
    if (playlistEpisodeCount(row.playlistJson) >= 2) return null;
    final List<String> candidates = localVideoFileCandidates(
      videoPath: row.videoPath,
      playlistJson: row.playlistJson,
    );
    if (candidates.length != 1) return null;
    if (platformPathKey(candidates.single) != platformPathKey(row.videoPath)) {
      return null;
    }
    return p.normalize(row.videoPath.trim());
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
            links[key] = _LinkSeed(torrent.hash, file.index, relative);
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
  _Draft(this.row, this.status, [this.moves = const <VideoFileMove>[]]);

  final VideoBookRow row;
  final VideoFilenamePlanStatus status;
  final List<VideoFileMove> moves;
}

class _LinkSeed {
  const _LinkSeed(this.infoHash, this.fileIndex, this.relativePath);

  final String infoHash;
  final int fileIndex;
  final String relativePath;
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

  /// [source] 在种子里时，换成新文件名 [newBaseName] 的引擎侧改名（只换末段，
  /// 种子内目录不变）。
  VideoFilenameTorrentLink? linkFor(String source, String newBaseName) {
    final _LinkSeed? seed = links[platformPathKey(source)];
    if (seed == null) return null;
    final String dir = p.posix.dirname(seed.relativePath);
    return VideoFilenameTorrentLink(
      infoHash: seed.infoHash,
      fileIndex: seed.fileIndex,
      currentRelativePath: seed.relativePath,
      newRelativePath: dir == '.'
          ? newBaseName
          : p.posix.join(dir, newBaseName),
    );
  }
}
