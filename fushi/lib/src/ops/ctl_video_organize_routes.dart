import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_season_groups.dart';
import 'package:fushi_engine/media/collections/collection_section_loader.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart'
    show VideoMetadataLookup;
import 'package:fushi_engine/media/video/metadata/video_metadata_work_loader.dart'
    show lookupOfWork;
import 'package:fushi_engine/media/video/organize/video_filename_organize.dart';
import 'package:fushi_engine/media/video/organize/video_filename_organize_service.dart';
import 'package:fushi_engine/media/video/organize/video_library_listing.dart';
import 'package:fushi_engine/media/video/organize/video_placement_audit.dart';
import 'package:fushi_engine/media/video/organize/video_work_regroup.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart'
    show VideoNameInfo, parseVideoPath;
import 'package:path/path.dart' as p;

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_video_support.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 视频库整理的控制通道（所有者 2026-11-20：「AI 能干的事太少了」——合集里的
/// 「第 0 季」不是第 0 季、甚至是电影，AI 应该能自己处理，包括给媒体改名）。
///
/// 修前操作目录里的视频写操作只有「认身份 / 启动刮削」，季集挂错、电影被建成剧集、
/// 磁盘上已经叫 `Season 00/xxx - S00E01.mkv` 的文件，AI 看得见却没有任何一条操作
/// 能动。这里把界面上已有的三件事接成路由，再补一条界面上没有的：
///
/// * `GET  works/:id/detail`  —— 一部作品的季 / 集 / 本机文件明细（界面的合集详情页）；
/// * `POST files/:uid/episode` —— 手动指定 / 清除某个文件的季集（集卡菜单「手动指定
///   季集…」，同一对 `setVideoEpisodeBindingOverride` + `rebindVideoEpisodeToBook`）；
/// * `GET / POST organize`    —— 按刮削资料整理文件名 / 归到规范目录（库页「整理
///   文件名」，同一个 [VideoFilenameOrganizeService]：做种走引擎、失败整条回滚）；
/// * `POST files/:uid/move`   —— 把一个文件搬到点名的目录 / 改成点名的文件名（刮削
///   身份本身就错时用：先把电影从 `某剧/Season 00/` 搬出来，再重新识别）。同一个
///   服务的 `customTargets`，只能落在文件所属的来源库根之内。
/// * `GET  audit`              —— 摆放审计：挂在特别篇下的电影长度文件
///   （[auditVideoPlacement]，只读）；
/// * `POST regroup`            —— 把文件从一部作品里拆出来 / 并进另一部 / 另组一部
///   （[regroupVideoFiles]）。**作品单元由合集成员关系决定，不由磁盘位置决定**：
///   电影被挂成某部剧的第 0 季，修法是把它拆出来再按电影识别，不是搬文件。
/// * `GET  works/:id/sections` —— 合集详情页的分栏（第 N 季 / PV·特典）：每个文件
///   在哪一栏、为什么（手动分栏 / 手动季集 / 文件名）、绑到哪一集，外加可疑点
///   （刮削说是特别篇却在正片栏、同一栏里集号撞车）。拍板台 iR6ccUys9H。
/// * `POST sections`           —— 把一批文件钉到某一季 / PV·特典，或改回自动
///   （`video_collection_section_overrides`，跟着文件走，合并 / 重新刮削都保留）。
///
/// 发给调用方的路径一律是**相对来源库根**的（库根之外的只给文件名）；撤销要用的
/// 绝对路径不进应答，留在本进程的 [takeVideoOrganizeUndo] 里按回执号取。
List<CtlRoute> buildVideoOrganizeCtlRoutes(OpContext context) =>
    buildVideoOrganizeCtlRoutesFor(
      database: () => context.appModel.database,
      organizer: () => context.appModel.videoFilenameOrganizeService,
      // 审计要看时长；规格缓存是懒探的，缺的那几十个文件现探（服务自带并发闸门）。
      probeDurations: (List<String> paths) => Future.wait(<Future<void>>[
        for (final String path in paths)
          context.appModel.videoSpecsService.resolve(path),
      ]),
      requireVideo: () {
        if (!context.appModel.moduleVisibility.isEnabled(ModuleId.video)) {
          throw const CtlFailure.rejected('「视频」模块已关闭（设置 › 功能模块）');
        }
      },
    );

const String kVideoOrganizeCtlRoot = '/api/admin/video';

/// 可注入版本（测试用内存库 + 临时目录上的真实服务）。
List<CtlRoute> buildVideoOrganizeCtlRoutesFor({
  required FushiDatabase Function() database,
  required VideoFilenameOrganizeService Function() organizer,
  void Function()? requireVideo,
  VideoDurationProber? probeDurations,
}) {
  final _VideoOrganizeCtl ctl = _VideoOrganizeCtl(
    database,
    organizer,
    requireVideo ?? () {},
    probeDurations,
  );
  return <CtlRoute>[
    CtlRoute.get('$kVideoOrganizeCtlRoot/works/:id/detail', ctl.workDetail),
    CtlRoute.post('$kVideoOrganizeCtlRoot/files/:uid/episode', ctl.pinEpisode),
    CtlRoute.get('$kVideoOrganizeCtlRoot/organize', ctl.planOrganize),
    CtlRoute.post('$kVideoOrganizeCtlRoot/organize', ctl.applyOrganize),
    CtlRoute.post('$kVideoOrganizeCtlRoot/files/:uid/move', ctl.moveFile),
    CtlRoute.get('$kVideoOrganizeCtlRoot/audit', ctl.audit),
    CtlRoute.get('$kVideoOrganizeCtlRoot/files', ctl.libraryFiles),
    CtlRoute.post('$kVideoOrganizeCtlRoot/regroup', ctl.regroup),
    CtlRoute.get('$kVideoOrganizeCtlRoot/works/:id/sections', ctl.sections),
    CtlRoute.post('$kVideoOrganizeCtlRoot/sections', ctl.setSections),
  ];
}

// ── 撤销回执（绝对路径不进应答） ──────────────────────────────────────────

const int _kUndoLedgerCapacity = 64;
int _undoSeq = 0;
final Map<String, Map<String, Object?>> _undoLedger =
    <String, Map<String, Object?>>{};

String _stashUndo(Map<String, Object?> undo) {
  final String token = 'vo${++_undoSeq}';
  _undoLedger[token] = undo;
  while (_undoLedger.length > _kUndoLedgerCapacity) {
    _undoLedger.remove(_undoLedger.keys.first);
  }
  return token;
}

/// 取走一次整理 / 搬动的撤销数据（[VideoFilenameOrganizeResult.undoPlan] 的 JSON
/// 形态）。操作描述在执行后立刻取走写进撤销载荷，所以它只需要活过一次调用。
Map<String, Object?>? takeVideoOrganizeUndo(Object? token) =>
    token is String ? _undoLedger.remove(token) : null;

/// 撤销计划 → JSON（撤销载荷，持久化在本机 `ai_agent_actions`）。
Map<String, Object?> videoOrganizePlanToJson(VideoFilenameOrganizePlan plan) =>
    <String, Object?>{
      'layout': plan.layout.name,
      'items': <Map<String, Object?>>[
        for (final VideoFilenameItemPlan item in plan.items)
          <String, Object?>{
            'bookUid': item.bookUid,
            'title': item.title,
            'libraryRoot': item.libraryRoot,
            'moves': <Map<String, Object?>>[
              for (final VideoFilenamePlannedMove m in item.moves)
                <String, Object?>{
                  'from': m.move.from,
                  'to': m.move.to,
                  'isVideo': m.move.isVideo,
                  if (m.torrent case final VideoFilenameTorrentLink t)
                    'torrent': <String, Object?>{
                      'infoHash': t.infoHash,
                      'fileIndex': t.fileIndex,
                      'current': t.currentRelativePath,
                      'next': t.newRelativePath,
                    },
                },
            ],
          },
      ],
      'collections': <Map<String, Object?>>[
        for (final VideoFolderCollectionMove m in plan.folderCollectionMoves)
          <String, Object?>{
            'id': m.collectionId,
            'name': m.collectionName,
            'from': m.fromKey,
            'to': m.toKey,
            'members': m.memberUids.toList(),
          },
      ],
    };

/// [videoOrganizePlanToJson] 的逆；形状不对返回 null。
VideoFilenameOrganizePlan? videoOrganizePlanFromJson(Object? raw) {
  if (raw is! Map) return null;
  final Object? items = raw['items'];
  if (items is! List) return null;
  final List<VideoFilenameItemPlan> parsed = <VideoFilenameItemPlan>[];
  for (final Object? item in items) {
    if (item is! Map || item['bookUid'] is! String || item['moves'] is! List) {
      return null;
    }
    final List<VideoFilenamePlannedMove> moves = <VideoFilenamePlannedMove>[];
    for (final Object? m in item['moves'] as List) {
      if (m is! Map || m['from'] is! String || m['to'] is! String) return null;
      final Object? t = m['torrent'];
      moves.add(
        VideoFilenamePlannedMove(
          move: VideoFileMove(
            from: m['from'] as String,
            to: m['to'] as String,
            isVideo: m['isVideo'] == true,
          ),
          torrent: t is Map
              ? VideoFilenameTorrentLink(
                  infoHash: '${t['infoHash']}',
                  fileIndex: (t['fileIndex'] as num).toInt(),
                  currentRelativePath: '${t['current']}',
                  newRelativePath: '${t['next']}',
                )
              : null,
        ),
      );
    }
    parsed.add(
      VideoFilenameItemPlan(
        bookUid: item['bookUid'] as String,
        title: '${item['title'] ?? ''}',
        status: VideoFilenamePlanStatus.ready,
        libraryRoot: item['libraryRoot'] as String?,
        moves: moves,
      ),
    );
  }
  final Object? collections = raw['collections'];
  return VideoFilenameOrganizePlan(
    items: parsed,
    torrentCheck: VideoFilenameTorrentCheck.verified,
    layout:
        VideoOrganizeLayout.values.asNameMap()[raw['layout']] ??
        VideoOrganizeLayout.filenameOnly,
    folderCollectionMoves: <VideoFolderCollectionMove>[
      if (collections is List)
        for (final Object? c in collections)
          if (c is Map)
            VideoFolderCollectionMove(
              collectionId: (c['id'] as num).toInt(),
              collectionName: '${c['name'] ?? ''}',
              fromKey: '${c['from']}',
              toKey: '${c['to']}',
              memberUids: <String>{
                if (c['members'] is List)
                  for (final Object? uid in c['members'] as List) '$uid',
              },
            ),
    ],
  );
}

/// 季集指定撤销用的分集行快照（只取改绑会动的四列）。
Map<String, Object?> _episodeBindingJson(VideoMetadataEpisodeRow row) =>
    <String, Object?>{
      'id': row.id,
      'bookUid': row.bookUid,
      'anidbEpisodeId': row.anidbEpisodeId,
      'anidbEpisodeNumber': row.anidbEpisodeNumber,
      'anidbMatchRating': row.anidbMatchRating,
    };

/// 把 [snapshot]（`files/:uid/episode` 应答的 `previous`）写回库：手动指定恢复成
/// 执行前（没有就清掉），动过的分集行四列恢复原值。返回 false = 当前的手动指定已
/// 不是这次执行写下的（用户之后又改过），不覆盖。
Future<bool> restoreVideoEpisodePin(
  FushiDatabase db, {
  required String bookUid,
  required Object? applied,
  required Object? snapshot,
}) async {
  final VideoEpisodeBindingOverrideRow? now = await db
      .getVideoEpisodeBindingOverride(bookUid);
  final (int, int)? current = now == null
      ? null
      : (now.seasonNumber, now.episodeNumber);
  final (int, int)? written = _pairOf(applied);
  if (current != written) return false;
  final Map<Object?, Object?> before = snapshot is Map ? snapshot : const {};
  await db.transaction(() async {
    final (int, int)? previous = _pairOf(before['override']);
    if (previous == null) {
      await db.clearVideoEpisodeBindingOverride(bookUid);
    } else {
      await db.setVideoEpisodeBindingOverride(
        bookUid,
        seasonNumber: previous.$1,
        episodeNumber: previous.$2,
      );
    }
    final Object? rows = before['episodes'];
    if (rows is! List) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final Object? row in rows) {
      if (row is! Map || row['id'] is! num) continue;
      await (db.update(
        db.videoMetadataEpisodes,
      )..where((tbl) => tbl.id.equals((row['id'] as num).toInt()))).write(
        VideoMetadataEpisodesCompanion(
          bookUid: Value<String?>(row['bookUid'] as String?),
          anidbEpisodeId: Value<int?>((row['anidbEpisodeId'] as num?)?.toInt()),
          anidbEpisodeNumber: Value<String?>(
            row['anidbEpisodeNumber'] as String?,
          ),
          anidbMatchRating: Value<String?>(row['anidbMatchRating'] as String?),
          updatedAt: Value<int>(now),
        ),
      );
    }
  });
  db.notifyVideoLibraryChanged();
  return true;
}

(int, int)? _pairOf(Object? raw) =>
    raw is Map && raw['season'] is num && raw['episode'] is num
    ? ((raw['season'] as num).toInt(), (raw['episode'] as num).toInt())
    : null;

/// 把 `POST sections` 的撤销载荷写回库：每个文件的手动分栏恢复成执行前（没有就
/// 清掉）。之后又被改过的文件（当前手动分栏已不是 [applied]）保留现状。
Future<({int reverted, int superseded})> restoreVideoCollectionSections(
  FushiDatabase db, {
  required Object? applied,
  required Object? previous,
}) async {
  final Map<Object?, Object?> before = previous is Map ? previous : const {};
  final List<String> uids = <String>[
    for (final Object? uid in before.keys)
      if (uid is String) uid,
  ];
  if (uids.isEmpty) return (reverted: 0, superseded: 0);
  final String? written = applied is String ? applied : null;
  final Map<String, String> now = await db.getVideoCollectionSectionOverrides(
    uids,
  );
  int reverted = 0;
  int superseded = 0;
  await db.transaction(() async {
    for (final String uid in uids) {
      if (now[uid] != written) {
        superseded++;
        continue;
      }
      final Object? old = before[uid];
      if (old is String && isValidCollectionSectionKey(old)) {
        await db.setVideoCollectionSectionOverrides(<String>[uid], old);
      } else {
        await db.clearVideoCollectionSectionOverrides(<String>[uid]);
      }
      reverted++;
    }
  });
  if (reverted > 0) db.notifyVideoLibraryChanged();
  return (reverted: reverted, superseded: superseded);
}

/// 分栏来源的线上名（`GET works/:id/sections` 的 `files[].source`）。
String _sectionSourceName(CollectionSectionSource source) => switch (source) {
  CollectionSectionSource.manual => 'manual',
  CollectionSectionSource.pinnedEpisode => 'pinnedEpisode',
  CollectionSectionSource.filename => 'filename',
};

/// `video.library.files` 一页的行数：默认 / 上限。
const int kVideoLibraryFilesDefaultLimit = 300;
const int kVideoLibraryFilesMaxLimit = 1000;

class _VideoOrganizeCtl {
  _VideoOrganizeCtl(
    this._database,
    this._organizer,
    this._requireVideo,
    this._probeDurations,
  );

  final FushiDatabase Function() _database;
  final VideoFilenameOrganizeService Function() _organizer;
  final void Function() _requireVideo;
  final VideoDurationProber? _probeDurations;

  FushiDatabase get _db => _database();

  // ── 路径口径 ────────────────────────────────────────────────────────────

  Future<List<String>> _libraryRoots() async => <String>[
    for (final MediaSourceRow source in await _db.getAllMediaSources())
      if (source.transport == 'local' && source.mediaKind == 'video')
        source.rootPath,
  ];

  /// 相对来源库根的路径（POSIX `/`）；不在任何库根下只给文件名。
  static String _relative(String path, List<String> roots) {
    final String? root = containingLibraryRoot(path, roots);
    if (root == null) return p.basename(path);
    return p.split(p.relative(path, from: root)).join('/');
  }

  // ── 作品明细 ────────────────────────────────────────────────────────────

  Future<List<VideoBookRow>> _membersOf(CtlVideoWorkId id) async {
    switch (id) {
      case CtlVideoBookWorkId(:final String bookUid):
        final VideoBookRow? row = await _db.getVideoBookByBookUid(bookUid);
        if (row == null) throw CtlFailure.notFound('没有这个视频：$bookUid');
        return <VideoBookRow>[row];
      case CtlVideoCollectionWorkId(:final int collectionId):
        if (await _db.getMediaCollectionById(collectionId) == null) {
          throw CtlFailure.notFound('没有这个合集：$collectionId');
        }
        final List<VideoBookRow> rows = <VideoBookRow>[];
        for (final MediaCollectionItemRow item in await _db.getCollectionItems(
          collectionId,
        )) {
          if (item.mediaType != MediaKind.video.dbValue) continue;
          final VideoBookRow? row = await _db.getVideoBookByBookUid(
            item.entryKey,
          );
          if (row != null) rows.add(row);
        }
        return rows;
    }
  }

  Future<VideoMetadataWorkRow?> _workOf(CtlVideoWorkId id) => switch (id) {
    CtlVideoBookWorkId(:final String bookUid) => _db.getVideoMetadataWorkByBook(
      bookUid,
    ),
    CtlVideoCollectionWorkId(:final int collectionId) =>
      _db.getVideoMetadataWorkByCollection(collectionId),
  };

  /// `video detail <workId>`：作品的类型 / 身份、各季各集与本机文件的对应。默认只列
  /// 绑了本机文件的集（一部长寿番的特别篇能有上百条）；`all=true` 列全部。
  Future<Object?> workDetail(CtlCall call) async {
    _requireVideo();
    final CtlVideoWorkId id = CtlVideoWorkId.parse(call.params['id']!);
    final bool all = call.optBool('all') == true;
    final List<VideoBookRow> members = await _membersOf(id);
    final VideoMetadataWorkRow? work = await _workOf(id);
    final List<String> roots = await _libraryRoots();
    final Map<String, VideoEpisodeBindingOverrideRow> pins = await _db
        .getVideoEpisodeBindingOverrides(
          members.map((VideoBookRow row) => row.bookUid),
        );
    final Map<String, List<String>> boundTo = <String, List<String>>{};
    final List<Map<String, Object?>> seasons = <Map<String, Object?>>[];
    VideoMetadataLookup? lookup;
    if (work != null) {
      lookup = await lookupOfWork(_db, work.id);
      for (final VideoMetadataSeasonRow season
          in await _db.getVideoMetadataSeasons(work.id)) {
        final List<VideoMetadataEpisodeRow> episodes = await _db
            .getVideoMetadataEpisodes(season.id);
        int local = 0;
        final List<Map<String, Object?>> listed = <Map<String, Object?>>[];
        for (final VideoMetadataEpisodeRow e in episodes) {
          final String? uid = e.bookUid;
          if (uid != null) {
            local++;
            (boundTo[uid] ??= <String>[]).add(
              _slot(season.seasonNumber, e.episodeNumber),
            );
          }
          if (uid == null && !all) continue;
          listed.add(<String, Object?>{
            'episode': e.episodeNumber,
            'title': e.title,
            if (e.runtimeMinutes != null) 'runtimeMinutes': e.runtimeMinutes,
            if (e.airDate != null) 'airDate': e.airDate,
            if (uid != null) 'file': uid,
          });
        }
        seasons.add(<String, Object?>{
          'season': season.seasonNumber,
          'title': season.title,
          'episodes': episodes.length,
          'localEpisodes': local,
          'listed': listed,
        });
      }
    }
    final List<Map<String, Object?>> files = <Map<String, Object?>>[];
    for (final VideoBookRow row in members) {
      final VideoFileSpecRow? spec = await _db.videoFileSpec(row.videoPath);
      final VideoEpisodeBindingOverrideRow? pin = pins[row.bookUid];
      files.add(<String, Object?>{
        'uid': row.bookUid,
        'title': row.title,
        'path': _relative(row.videoPath, roots),
        if (spec?.durationMs case final int ms)
          'durationMinutes': (ms / 60000).round(),
        'boundTo': boundTo[row.bookUid] ?? const <String>[],
        if (pin != null)
          'pinned': <String, Object?>{
            'season': pin.seasonNumber,
            'episode': pin.episodeNumber,
          },
      });
    }
    return <String, Object?>{
      'id': id.stableKey,
      'work': work == null
          ? null
          : <String, Object?>{
              'mediaType': work.mediaType,
              'title': work.title,
              'originalTitle': work.originalTitle,
              'year': work.year,
              'identity': lookup == null
                  ? null
                  : '${lookup.provider.name}:${lookup.externalId}',
            },
      'seasons': seasons,
      'files': files,
    };
  }

  static String _slot(int season, int episode) =>
      'S${season.toString().padLeft(2, '0')}'
      'E${episode.toString().padLeft(2, '0')}';

  // ── 合集分栏 ────────────────────────────────────────────────────────────

  /// `video sections <workId>`：合集详情页上每个文件在哪一栏（与界面同一个
  /// [loadCollectionSections]），分栏从哪来、绑到哪一集，以及值得核对的可疑点。只读。
  Future<Object?> sections(CtlCall call) async {
    _requireVideo();
    final CtlVideoWorkId id = CtlVideoWorkId.parse(call.params['id']!);
    final List<VideoBookRow> members = await _membersOf(id);
    final VideoMetadataWorkRow? work = switch (id) {
      // 与合集详情页同一个规范作品解析（那一页的分栏就是按它挑出本地特典的）。
      CtlVideoCollectionWorkId(:final int collectionId) =>
        await _db.resolveVideoMetadataWorkForCollection(collectionId),
      CtlVideoBookWorkId() => await _workOf(id),
    };
    final List<String> roots = await _libraryRoots();
    // 刮削认成本地特典（NCOP / 映像特典）的文件：详情页不进分栏，单列「特典」排。
    final Set<String> railExtras = <String>{
      if (work != null)
        for (final VideoMetadataExtraRow extra
            in await _db.getVideoMetadataExtras(work.id))
          if (extra.bookUid != null) extra.bookUid!,
    };
    final List<VideoBookRow> listed = <VideoBookRow>[
      for (final VideoBookRow row in members)
        if (!railExtras.contains(row.bookUid)) row,
    ];
    final Map<String, CollectionSectionResolution> resolved =
        await loadCollectionSections(_db, <String, String>{
          for (final VideoBookRow row in listed)
            row.bookUid: collectionGroupKeyForFilename(row.videoPath),
        });
    final Map<String, VideoEpisodeBindingOverrideRow> pins = await _db
        .getVideoEpisodeBindingOverrides(
          members.map((VideoBookRow row) => row.bookUid),
        );
    final Map<int, int> seasonNumberById = <int, int>{
      for (final VideoMetadataSeasonRow season
          in await _db.getAllVideoMetadataSeasons())
        season.id: season.seasonNumber,
    };
    final List<Map<String, Object?>> files = <Map<String, Object?>>[];
    final List<Map<String, Object?>> warnings = <Map<String, Object?>>[];
    // (分栏, 文件名集号) → 文件：同一栏里集号撞车多半是短篇 / 特典混进了正片。
    final Map<(String, int), List<String>> byEpisode =
        <(String, int), List<String>>{};
    for (final VideoBookRow row in listed) {
      final CollectionSectionResolution r = resolved[row.bookUid]!;
      final List<VideoMetadataEpisodeRow> bound = await _db
          .getVideoMetadataEpisodesByBook(row.bookUid);
      final List<int> boundSeasons = <int>[
        for (final VideoMetadataEpisodeRow e in bound)
          if (seasonNumberById[e.seasonId] case final int n) n,
      ];
      final VideoNameInfo info = parseVideoPath(row.videoPath);
      final VideoEpisodeBindingOverrideRow? pin = pins[row.bookUid];
      final int? section = seasonNumberOfGroupKey(r.groupKey);
      files.add(<String, Object?>{
        'uid': row.bookUid,
        'title': row.title,
        'path': _relative(row.videoPath, roots),
        'section': r.groupKey,
        'source': _sectionSourceName(r.source),
        if (r.derivedKey != r.groupKey) 'derivedSection': r.derivedKey,
        if (info.season != null) 'fileSeason': info.season,
        if (info.episode != null) 'fileEpisode': info.episode,
        'boundTo': <String>[
          for (final VideoMetadataEpisodeRow e in bound)
            if (seasonNumberById[e.seasonId] case final int n)
              _slot(n, e.episodeNumber),
        ],
        if (bound.firstOrNull?.anidbMatchRating case final String rating)
          'match': rating,
        if (pin != null)
          'pinned': <String, Object?>{
            'season': pin.seasonNumber,
            'episode': pin.episodeNumber,
          },
      });
      if (section != null &&
          r.source == CollectionSectionSource.filename &&
          boundSeasons.isNotEmpty &&
          boundSeasons.every((int n) => n == 0)) {
        warnings.add(<String, Object?>{
          'uid': row.bookUid,
          'kind': 'bound_to_special',
          'message':
              'Scraped as a special (season 0) but shown under season '
              '$section: move it with section=extras, or pin the right episode.',
        });
      }
      if (section != null && info.episode != null) {
        (byEpisode[(r.groupKey, info.episode!)] ??= <String>[]).add(
          row.bookUid,
        );
      }
    }
    for (final MapEntry<(String, int), List<String>> entry
        in byEpisode.entries) {
      if (entry.value.length < 2) continue;
      warnings.add(<String, Object?>{
        'uids': entry.value,
        'kind': 'duplicate_episode_number',
        'message':
            '${entry.value.length} files in ${entry.key.$1} are all episode '
            '${entry.key.$2} by file name: shorts / specials are probably '
            'mixed into the main episodes.',
      });
    }
    final List<CollectionSeasonSection<Map<String, Object?>>> sections =
        sortCollectionSeasonSections<Map<String, Object?>>(
          buildCollectionSeasonSections<Map<String, Object?>>(
            members: files,
            keyOf: (Map<String, Object?> f) => f['section'] as String?,
          ),
        );
    return <String, Object?>{
      'id': id.stableKey,
      // 详情页只有 ≥2 栏才出季 tab；1 栏时整页就是一张平铺列表。
      'tabs': sections.length >= 2,
      'sections': <Map<String, Object?>>[
        for (final CollectionSeasonSection<Map<String, Object?>> s in sections)
          <String, Object?>{
            'key': s.groupKey,
            if (seasonNumberOfGroupKey(s.groupKey) case final int n)
              'season': n,
            'files': <Object?>[
              for (final Map<String, Object?> f in s.items) f['uid'],
            ],
          },
      ],
      'files': files,
      'scrapedExtras': <Map<String, Object?>>[
        for (final VideoBookRow row in members)
          if (railExtras.contains(row.bookUid))
            <String, Object?>{
              'uid': row.bookUid,
              'title': row.title,
              'path': _relative(row.videoPath, roots),
            },
      ],
      'warnings': warnings,
    };
  }

  /// `video section <bookUid...> --extras | --season N | --auto`：把一批文件钉到
  /// 某一季 / PV·特典栏，或清掉手动分栏（回到手动季集指定 → 文件名）。与集卡菜单
  /// 「移到分栏…」同一张表。
  Future<Object?> setSections(CtlCall call) async {
    _requireVideo();
    final List<String> uids = call.stringList('items').toSet().toList();
    if (uids.isEmpty) {
      throw const CtlFailure.badRequest('需要 items（视频文件 uid 列表）');
    }
    final String section = call.requireString('section');
    final String? key;
    switch (section) {
      case 'auto':
        key = null;
      case 'extras':
        key = kCollectionExtrasGroupKey;
      case 'season':
        final int? season = call.optInt('season');
        if (season == null || season < 1) {
          throw const CtlFailure.badRequest(
            'section=season 需要 season（≥1 的整数）；特别篇用 section=extras',
          );
        }
        key = 's$season';
      default:
        throw CtlFailure.badRequest(
          'section 只能是 season / extras / auto：$section',
        );
    }
    final List<VideoBookRow> rows = <VideoBookRow>[];
    final List<String> missing = <String>[];
    for (final String uid in uids) {
      final VideoBookRow? row = await _db.getVideoBookByBookUid(uid);
      row == null ? missing.add(uid) : rows.add(row);
    }
    if (missing.isNotEmpty) {
      throw CtlFailure.notFound('没有这些视频：${missing.join(', ')}');
    }
    final Map<String, String> before = await _db
        .getVideoCollectionSectionOverrides(uids);
    if (key == null) {
      await _db.clearVideoCollectionSectionOverrides(uids);
    } else {
      await _db.setVideoCollectionSectionOverrides(uids, key);
    }
    _db.notifyVideoLibraryChanged();
    final Map<String, CollectionSectionResolution> after =
        await loadCollectionSections(_db, <String, String>{
          for (final VideoBookRow row in rows)
            row.bookUid: collectionGroupKeyForFilename(row.videoPath),
        });
    return <String, Object?>{
      'applied': key,
      'items': <Map<String, Object?>>[
        for (final VideoBookRow row in rows)
          <String, Object?>{
            'uid': row.bookUid,
            'section': after[row.bookUid]!.groupKey,
            'source': _sectionSourceName(after[row.bookUid]!.source),
          },
      ],
      'previous': <String, Object?>{
        for (final String uid in uids) uid: before[uid],
      },
    };
  }

  // ── 手动指定季集 ────────────────────────────────────────────────────────

  /// 文件所在的作品行：已绑到分集 → 那一集的作品；否则按它所在的合集找。
  Future<VideoMetadataWorkRow?> _workOfFile(
    String bookUid,
    List<VideoMetadataEpisodeRow> bound,
  ) async {
    if (bound.isNotEmpty) {
      for (final VideoMetadataSeasonRow season
          in await _db.getAllVideoMetadataSeasons()) {
        if (season.id == bound.first.seasonId) {
          return _db.getVideoMetadataWorkById(season.workId);
        }
      }
    }
    for (final MediaCollectionItemRow item
        in await _db.getAllCollectionItems()) {
      if (item.mediaType != MediaKind.video.dbValue ||
          item.entryKey != bookUid) {
        continue;
      }
      final VideoMetadataWorkRow? work = await _db
          .getVideoMetadataWorkByCollection(item.collectionId);
      if (work != null) return work;
    }
    return null;
  }

  /// `video pin <bookUid> --season N --episode M` / `--clear`：集卡菜单「手动指定
  /// 季集…」。指定后立刻改绑到那一集，之后的刮削不再改它；清除只去掉指定，当前绑定
  /// 留到下次刮削重新自动链接（与界面同一语义）。
  Future<Object?> pinEpisode(CtlCall call) async {
    _requireVideo();
    final String bookUid = call.params['uid']!;
    if (await _db.getVideoBookByBookUid(bookUid) == null) {
      throw CtlFailure.notFound('没有这个视频：$bookUid');
    }
    final VideoEpisodeBindingOverrideRow? existing = await _db
        .getVideoEpisodeBindingOverride(bookUid);
    final List<VideoMetadataEpisodeRow> bound = await _db
        .getVideoMetadataEpisodesByBook(bookUid);
    final Map<String, Object?> previous = <String, Object?>{
      'override': existing == null
          ? null
          : <String, Object?>{
              'season': existing.seasonNumber,
              'episode': existing.episodeNumber,
            },
      'episodes': <Map<String, Object?>>[
        for (final VideoMetadataEpisodeRow row in bound)
          _episodeBindingJson(row),
      ],
    };
    if (call.optBool('clear') == true) {
      if (existing == null) {
        throw const CtlFailure.conflict('这个文件没有手动指定的季集');
      }
      await _db.clearVideoEpisodeBindingOverride(bookUid);
      _db.notifyVideoLibraryChanged();
      return <String, Object?>{
        'uid': bookUid,
        'cleared': true,
        'applied': null,
        'previous': previous,
      };
    }
    final int? season = call.optInt('season');
    final int? episode = call.optInt('episode');
    if (season == null || episode == null || season < 0 || episode < 0) {
      throw const CtlFailure.badRequest(
        '需要 season 与 episode（非负整数），或 clear=true',
      );
    }
    final VideoMetadataWorkRow? work = await _workOfFile(bookUid, bound);
    if (work == null) {
      throw const CtlFailure.conflict('这个文件所在的作品还没有刮出季集，先识别作品（video identify）');
    }
    final VideoMetadataSeasonRow? targetSeason =
        (await _db.getVideoMetadataSeasons(work.id))
            .where((VideoMetadataSeasonRow s) => s.seasonNumber == season)
            .firstOrNull;
    final VideoMetadataEpisodeRow? target = targetSeason == null
        ? null
        : (await _db.getVideoMetadataEpisodes(targetSeason.id))
              .where((VideoMetadataEpisodeRow e) => e.episodeNumber == episode)
              .firstOrNull;
    if (target == null) {
      throw CtlFailure.notFound(
        '《${work.title}》没有 ${_slot(season, episode)} 这一集（video detail --all 看全部集）',
      );
    }
    // 目标集原先的绑定也要进快照：改绑会把它指到这个文件上。
    if (!bound.any((VideoMetadataEpisodeRow row) => row.id == target.id)) {
      (previous['episodes']! as List<Map<String, Object?>>).add(
        _episodeBindingJson(target),
      );
    }
    // ifFree=true（库管家自动路径必带）：目标集已绑着另一个本机文件就拒绝，不悄悄
    // 把那个文件挤成未绑定。
    final String? occupant = target.bookUid;
    if (call.optBool('ifFree') == true &&
        occupant != null &&
        occupant != bookUid &&
        await _db.getVideoBookByBookUid(occupant) != null) {
      throw CtlFailure(
        409,
        kVideoEpisodeOccupiedCode,
        '${_slot(season, episode)} 已绑着另一个本机文件（$occupant），没有改绑',
      );
    }
    // 指定与改绑同一个事务：不留「有指定、没改绑」的半成品。
    await _db.transaction(() async {
      await _db.setVideoEpisodeBindingOverride(
        bookUid,
        seasonNumber: season,
        episodeNumber: episode,
      );
      await _db.rebindVideoEpisodeToBook(
        workId: work.id,
        bookUid: bookUid,
        seasonNumber: season,
        episodeNumber: episode,
      );
    });
    _db.notifyVideoLibraryChanged();
    return <String, Object?>{
      'uid': bookUid,
      'work': work.title,
      'episodeTitle': target.title,
      'applied': <String, Object?>{'season': season, 'episode': episode},
      'previous': previous,
    };
  }

  // ── 摆放审计 / 拆并作品 ─────────────────────────────────────────────────

  /// `video audit`：全库里挂在特别篇（第 0 季）下的电影长度文件。只读。
  Future<Object?> audit(CtlCall call) async {
    _requireVideo();
    final VideoPlacementAudit audit = await auditVideoPlacement(
      _db,
      // probe=false：只用已有的时长缓存（库管家预估 / 预览不该触发全库探测）。
      probe: call.optBool('probe') == false ? null : _probeDurations,
    );
    final List<String> roots = await _libraryRoots();
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    for (final VideoPlacementFinding f in audit.findings) {
      final VideoBookRow? row = await _db.getVideoBookByBookUid(f.bookUid);
      out.add(<String, Object?>{
        ...f.toJson(),
        if (row != null) 'path': _relative(row.videoPath, roots),
      });
    }
    return <String, Object?>{
      'findings': out,
      if (call.optBool('detail') == true)
        'works': <Map<String, Object?>>[
          for (final VideoPlacementReview r in audit.reviews)
            <String, Object?>{
              'work': r.workId,
              'title': r.title,
              if (r.originalTitle != null) 'originalTitle': r.originalTitle,
              if (r.year != null) 'year': r.year,
              if (r.baselineMinutes != null)
                'episodeMinutes': r.baselineMinutes,
              'seasons': <String, int>{
                for (final MapEntry<int, int> e in r.regularSeasons.entries)
                  '${e.key}': e.value,
              },
              'localRegularFiles': r.regularLocalFiles,
              if (r.occupiedRegular.isNotEmpty)
                'occupied': <String, List<int>>{
                  for (final MapEntry<int, List<int>> e
                      in r.occupiedRegular.entries)
                    '${e.key}': e.value,
                },
              'files': <Map<String, Object?>>[
                for (final VideoPlacementReviewFile f in r.files)
                  <String, Object?>{
                    'uid': f.bookUid,
                    'title': f.title,
                    'path': _relative(f.videoPath, roots),
                    if (f.minutes != null) 'minutes': f.minutes,
                    if (f.slot != null) 'boundTo': f.slot,
                    if (f.episodeTitle != null) 'episodeTitle': f.episodeTitle,
                    if (f.episodeMinutes != null)
                      'episodeMinutes': f.episodeMinutes,
                  },
              ],
            },
        ],
      // 只绑在第 0 季但探不出时长的文件：没法判断，不等于没问题。
      if (audit.unknownDuration > 0) 'unknownDuration': audit.unknownDuration,
    };
  }

  /// `video files`：全库「文件 → 作品 → 季集 → 时长 → 目录」联表，一次看全。列式
  /// 输出（一行一个文件，省掉每行重复的键名）；筛选都是「与」。
  Future<Object?> libraryFiles(CtlCall call) async {
    _requireVideo();
    final int limit = (call.optInt('limit') ?? kVideoLibraryFilesDefaultLimit)
        .clamp(1, kVideoLibraryFilesMaxLimit);
    final int offset = call.optInt('offset') ?? 0;
    if (offset < 0) throw CtlFailure.badRequest('offset 不能是负数');
    final int? season = call.optInt('season');
    final int? minMinutes = call.optInt('minMinutes');
    final bool unbound = call.optBool('unbound') == true;
    final String? work = call.optString('work');
    final String? type = call.optString('type');
    final String? q = call.optString('q')?.toLowerCase();
    final List<String> roots = await _libraryRoots();
    final List<(VideoLibraryFile, String)> matched =
        <(VideoLibraryFile, String)>[];
    for (final VideoLibraryFile f in await listVideoLibraryFiles(_db)) {
      if (work != null && f.workId != work) continue;
      if (unbound && !f.isUnbound) continue;
      if (season != null && !f.slots.any(((int, int) s) => s.$1 == season)) {
        continue;
      }
      if (minMinutes != null && (f.minutes ?? -1) < minMinutes) continue;
      if (type != null && (f.mediaType ?? 'unidentified') != type) continue;
      final String path = _relative(f.videoPath, roots);
      if (q != null &&
          !path.toLowerCase().contains(q) &&
          !(f.workTitle ?? '').toLowerCase().contains(q)) {
        continue;
      }
      matched.add((f, path));
    }
    final List<(VideoLibraryFile, String)> page = matched
        .skip(offset)
        .take(limit)
        .toList();
    // 作品信息按作品给一次，行里只带作品 id。
    final Map<String, Map<String, Object?>> works =
        <String, Map<String, Object?>>{};
    for (final (VideoLibraryFile f, String _) in page) {
      works.putIfAbsent(
        f.workId,
        () => <String, Object?>{
          if (f.workTitle != null) 'title': f.workTitle,
          'type': f.mediaType ?? 'unidentified',
        },
      );
    }
    return <String, Object?>{
      'total': matched.length,
      'offset': offset,
      if (offset + page.length < matched.length)
        'nextOffset': offset + page.length,
      'works': works,
      'columns': const <String>['uid', 'work', 'boundTo', 'minutes', 'path'],
      'rows': <List<Object?>>[
        for (final (VideoLibraryFile f, String path) in page)
          <Object?>[
            f.bookUid,
            f.workId,
            <String>[
              for (final (int s, int e) in f.slots) _slotLabel(s, e),
            ].join(','),
            f.minutes,
            path,
          ],
      ],
    };
  }

  static String _slotLabel(int season, int episode) =>
      'S${season.toString().padLeft(2, '0')}'
      'E${episode.toString().padLeft(2, '0')}';

  /// `video regroup <bookUid...> --to standalone | new --name <名> | collection:<id>`。
  Future<Object?> regroup(CtlCall call) async {
    _requireVideo();
    final String to = call.requireString('to');
    final VideoRegroupTarget target;
    if (to == 'standalone') {
      target = const VideoRegroupStandalone();
    } else if (to == 'new') {
      target = VideoRegroupNewWork(call.requireString('name'));
    } else {
      final CtlVideoWorkId id = CtlVideoWorkId.parse(to);
      if (id is! CtlVideoCollectionWorkId) {
        throw const CtlFailure.badRequest(
          'to 只能是 standalone、new（配 name）或 collection:<id>',
        );
      }
      target = VideoRegroupExistingWork(id.collectionId);
    }
    final VideoRegroupResult result;
    try {
      result = await regroupVideoFiles(
        _db,
        bookUids: call.stringList('items'),
        target: target,
      );
    } on VideoRegroupRejected catch (e) {
      throw switch (e.code) {
        'unknown_file' ||
        'unknown_collection' => CtlFailure.notFound(e.message),
        'would_empty_work' => CtlFailure.conflict(e.message),
        _ => CtlFailure.badRequest(e.message),
      };
    }
    return <String, Object?>{
      'moved': result.moved,
      'skipped': result.skipped,
      if (result.targetCollectionId case final int id)
        'target': 'collection:$id',
      if (result.createdTarget) 'created': true,
      if (result.undo != null) 'previous': result.undo,
    };
  }

  // ── 整理文件名 / 搬动 ───────────────────────────────────────────────────

  Future<List<String>> _organizeTargets(CtlCall call) async {
    final List<String> items = call.stringList('items');
    final String? work = call.optString('work');
    if (items.isEmpty == (work == null)) {
      throw const CtlFailure.badRequest('给 items（视频 uid 列表）或 work（作品 id），二选一');
    }
    if (work == null) return items;
    return <String>[
      for (final VideoBookRow row in await _membersOf(
        CtlVideoWorkId.parse(work),
      ))
        row.bookUid,
    ];
  }

  static VideoOrganizeLayout _layout(CtlCall call) {
    final String raw = call.optString('layout') ?? 'filename';
    return switch (raw) {
      'filename' => VideoOrganizeLayout.filenameOnly,
      'directories' => VideoOrganizeLayout.directories,
      _ => throw CtlFailure.badRequest(
        'layout 只能是 filename 或 directories：$raw',
      ),
    };
  }

  Map<String, Object?> _planJson(
    VideoFilenameOrganizePlan plan,
    List<String> roots,
  ) => <String, Object?>{
    'layout': plan.layout == VideoOrganizeLayout.directories
        ? 'directories'
        : 'filename',
    'torrentCheck': plan.torrentCheck.name,
    if (plan.torrentCheckError != null)
      'torrentCheckError': plan.torrentCheckError,
    'ready': plan.ready.length,
    'items': <Map<String, Object?>>[
      for (final VideoFilenameItemPlan item in plan.items)
        <String, Object?>{
          'uid': item.bookUid,
          'title': item.title,
          'status': item.status.name,
          if (item.isSeeding) 'seeding': true,
          'moves': <Map<String, Object?>>[
            for (final VideoFilenamePlannedMove m in item.moves)
              <String, Object?>{
                'from': _relative(m.move.from, roots),
                'to': _relative(m.move.to, roots),
                if (!m.move.isVideo) 'sidecar': true,
              },
          ],
        },
    ],
  };

  /// `video organize --plan`：只读预览（库页整理对话框的清单）。
  Future<Object?> planOrganize(CtlCall call) async {
    _requireVideo();
    final VideoFilenameOrganizePlan plan = await _organizer().plan(
      await _organizeTargets(call),
      layout: _layout(call),
    );
    return _planJson(plan, await _libraryRoots());
  }

  /// `video organize`：执行。说不清文件是否在做种时要 `allowUnverifiedTorrents`
  /// （界面上那句「仍然改名」）。
  Future<Object?> applyOrganize(CtlCall call) async {
    _requireVideo();
    final VideoFilenameOrganizeService service = _organizer();
    final VideoFilenameOrganizePlan plan = await service.plan(
      await _organizeTargets(call),
      layout: _layout(call),
    );
    return _apply(service, plan, call);
  }

  /// `video move <bookUid> --dir <相对目录> --name <文件名>`：点名落点。
  Future<Object?> moveFile(CtlCall call) async {
    _requireVideo();
    final String bookUid = call.params['uid']!;
    if (await _db.getVideoBookByBookUid(bookUid) == null) {
      throw CtlFailure.notFound('没有这个视频：$bookUid');
    }
    final String? directory = call.optString('directory');
    final String? name = call.optString('name');
    final VideoFilenameCustomTarget target = VideoFilenameCustomTarget(
      directorySegments: directory == null
          ? null
          : <String>[
              for (final String segment in directory.split(RegExp(r'[\\/]')))
                if (segment.isNotEmpty) segment,
            ],
      stem: name,
    );
    final String? invalid = invalidVideoCustomTargetReason(target);
    if (invalid != null) {
      throw CtlFailure.badRequest(
        'directory（相对来源库根，如 "君の名は。 (2016)"）与 name（不含扩展名）'
        '至少给一个，且每一段都得是合法文件名：$invalid',
      );
    }
    final VideoFilenameOrganizeService service = _organizer();
    final VideoFilenameOrganizePlan plan = await service.plan(
      <String>[bookUid],
      customTargets: <String, VideoFilenameCustomTarget>{bookUid: target},
    );
    final VideoFilenameItemPlan? item = plan.items.firstOrNull;
    if (item == null || item.status != VideoFilenamePlanStatus.ready) {
      throw CtlFailure.conflict(
        '搬不了：${item?.status.name ?? VideoFilenamePlanStatus.notLocalFile.name}'
        '（unchanged = 已经在那里；conflict = 目标名被占；outsideLibraryRoot = 文件'
        '不在任何本机视频来源下；folderCollectionSplit = 会拆开一个目录合集；'
        'torrentOutsideSaveRoot = 在做种，搬不出种子的保存目录）',
      );
    }
    return _apply(service, plan, call);
  }

  Future<Map<String, Object?>> _apply(
    VideoFilenameOrganizeService service,
    VideoFilenameOrganizePlan plan,
    CtlCall call,
  ) async {
    final List<String> roots = await _libraryRoots();
    if (plan.ready.isEmpty) {
      return <String, Object?>{..._planJson(plan, roots), 'renamed': 0};
    }
    final VideoFilenameOrganizeResult result;
    try {
      result = await service.apply(
        plan,
        allowUnverifiedTorrents:
            call.optBool('allowUnverifiedTorrents') == true,
      );
    } on VideoFilenameUnverifiedTorrentsException {
      throw CtlFailure.conflict(
        '无法确认这些文件是否在做种（${plan.torrentCheckError ?? '下载后端连不上'}）：'
        '直接改磁盘可能让种子停掉。确认仍要改名再带 allowUnverifiedTorrents=true',
      );
    }
    final VideoFilenameOrganizePlan? undo = result.undoPlan;
    return <String, Object?>{
      'renamed': result.renamedCount,
      'failed': result.failures.length,
      'items': <Map<String, Object?>>[
        for (final VideoFilenameItemOutcome o in result.outcomes)
          <String, Object?>{
            'uid': o.item.bookUid,
            'title': o.item.title,
            'ok': o.ok,
            if (o.error != null) 'error': _scrub(o.error!, roots),
            if (o.rollbackError != null)
              'rollbackError': _scrub(o.rollbackError!, roots),
            'moves': <Map<String, Object?>>[
              for (final VideoFilenamePlannedMove m in o.item.moves)
                <String, Object?>{
                  'from': _relative(m.move.from, roots),
                  'to': _relative(m.move.to, roots),
                  if (!m.move.isVideo) 'sidecar': true,
                },
            ],
          },
      ],
      'skipped': <Map<String, Object?>>[
        for (final VideoFilenameItemPlan item in plan.items)
          if (item.status != VideoFilenamePlanStatus.ready)
            <String, Object?>{
              'uid': item.bookUid,
              'title': item.title,
              'status': item.status.name,
            },
      ],
      if (result.collectionErrors.isNotEmpty)
        'collectionErrors': result.collectionErrors,
      if (undo != null) 'undoToken': _stashUndo(videoOrganizePlanToJson(undo)),
    };
  }

  /// 错误原文里的库根绝对前缀换成 `<library>`（文件系统报错会带完整路径）。
  static String _scrub(String message, List<String> roots) {
    String out = message;
    for (final String root in roots) {
      final String normalized = p.normalize(root);
      if (normalized.isEmpty) continue;
      out = out.replaceAll(normalized, '<library>');
      out = out.replaceAll(normalized.replaceAll(r'\', '/'), '<library>');
    }
    return out;
  }
}

/// 按撤销计划把文件搬回去（操作描述的撤销闭包用）。返回 (成功条数, 失败原因)。
Future<({int reverted, List<String> errors})> revertVideoOrganize(
  VideoFilenameOrganizeService service,
  VideoFilenameOrganizePlan undoPlan,
) async {
  // 目标（= 当初的原位置）被别的文件占了、或搬过去的文件已不在：服务逐条判失败、
  // 不覆盖，这里只汇总。
  final VideoFilenameOrganizeResult result = await service.apply(
    undoPlan,
    allowUnverifiedTorrents: true,
  );
  return (
    reverted: result.renamedCount,
    errors: <String>[
      for (final VideoFilenameItemOutcome o in result.failures)
        '${o.item.title}: ${p.basename(o.error ?? 'failed')}',
      ...result.collectionErrors,
    ],
  );
}

/// 撤销前的快检：撤销计划里每个视频本体是否还在「搬过去的位置」。一个都不在 =
/// 用户之后自己又挪过，整次撤销算已被处理。
Future<bool> videoOrganizeUndoStillApplies(
  VideoFilenameOrganizePlan undoPlan,
) async {
  for (final VideoFilenameItemPlan item in undoPlan.items) {
    for (final VideoFilenamePlannedMove m in item.moves) {
      if (m.move.isVideo && await File(m.move.from).exists()) return true;
    }
  }
  return false;
}
