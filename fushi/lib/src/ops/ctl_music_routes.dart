import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/music/metadata/music_scrape_service.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/source_library_removal.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/pages/implementations/music/music_track_scrape_sections.dart'
    show MusicStoredRecording, decodeMusicStoredRecordings;

/// 音乐库：列表、刮削、手动指定录音、歌单、扫描根、播放遥控的控制通道路由（spec
/// `docs/specs/2026-10-26-ai-operations-agent-design.md` §2.2 / §8 P2）。每条路由调用
/// UI 按钮背后的同一个方法，不另写业务逻辑：
///
/// - 列表 / 搜索：曲库页同源的 `listMusicAlbums` / `listMusicArtists` /
///   `listMusicTracks` / `listMusicTracksByArtist` / `listMusicPlaylists`，搜索走
///   库页统一口径 [matchesMediaSearch]；
/// - 识别：曲目详情页「识别」/「选择匹配」的 [MusicScrapeService.scrapeTrack]
///   （`manualRecordingId` = 手选 / 手填的录音 MBID），设置页「识别整个曲库」的
///   [MusicScrapeService.scrapeLibrary]（后台跑，带进度与取消）；
/// - 扫描根：曲库页「添加文件夹」的 [addLocalFolderAsSource]（`music` 种类）与「重新扫描」
///   （逐个音乐来源 [SourceLibraryScanner.scan]）。library 域的来源路由刻意不认 music
///   （`ctl_library_routes.dart` 的 `_sourceKindVisible`），音乐扫描根只在这里管；
/// - 播放遥控：迷你播放条 / 歌词页按钮背后的 [MusicPlayerEngine] 方法（`togglePlayPause`
///   拆成 play / pause 两条好撤销）；点专辑「全部播放」/ 点曲目 = `playQueue`。
///
/// 歌单：曲库页的歌单分区只读列出（UI 没有建 / 改 / 删歌单，仓储也没有写方法），这里同样
/// 只给列表——不另写一套 UI 没有的歌单逻辑。
///
/// CLI 侧是 `fushi_cli music …`（`packages/fushi_cli/lib/src/commands/music_commands.dart`）。
List<CtlRoute> buildMusicCtlRoutes(OpContext context) => buildMusicCtlRoutesFor(
  database: () => context.appModel.database,
  musicEnabled: () =>
      context.appModel.moduleVisibility.isEnabled(ModuleId.music),
  isReadonly: () => context.appModel.isMigrationReadonly,
  player: () => EngineMusicCtlPlayer(context.appModel.musicSession.engine),
  scraper: () {
    final MusicScrapeService service = context.appModel.musicScrape;
    return MusicCtlScraper(
      scrapeTrack: service.scrapeTrack,
      scrapeLibrary: service.scrapeLibrary,
    );
  },
  removeSource: (FushiDatabase db, int id) => removeSourceLibrary(
    database: db,
    prefs: context.appModel.prefsRepo,
    sourceId: id,
  ),
);

/// 路由根。
const String kMusicCtlRoot = '/api/admin/music';

/// 播放遥控面：[MusicPlayerEngine] 上迷你播放条 / 歌词页用到的那几个方法。
abstract interface class MusicCtlPlayer {
  List<MusicPlayItem> get queue;
  MusicPlayItem? get current;
  bool get isPlaying;
  Duration get position;
  Duration? get duration;
  Future<void> playQueue(
    List<MusicPlayItem> items, {
    int startIndex,
    MusicQueueContext context,
    bool shuffle,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> skipNext();
  Future<void> skipPrevious();
  Future<void> jumpTo(int index);
}

/// 生产实现：直接委托给进程级音乐会话的引擎。
class EngineMusicCtlPlayer implements MusicCtlPlayer {
  EngineMusicCtlPlayer(this.engine);

  final MusicPlayerEngine engine;

  @override
  List<MusicPlayItem> get queue => engine.queue;
  @override
  MusicPlayItem? get current => engine.current;
  @override
  bool get isPlaying => engine.isPlaying;
  @override
  Duration get position => engine.position;
  @override
  Duration? get duration => engine.duration;
  @override
  Future<void> playQueue(
    List<MusicPlayItem> items, {
    int startIndex = 0,
    MusicQueueContext context = MusicQueueContext.mixed,
    bool shuffle = false,
  }) => engine.playQueue(
    items,
    startIndex: startIndex,
    context: context,
    shuffle: shuffle,
  );
  @override
  Future<void> play() => engine.play();
  @override
  Future<void> pause() => engine.pause();
  @override
  Future<void> skipNext() => engine.skipNext();
  @override
  Future<void> skipPrevious() => engine.skipPrevious();
  @override
  Future<void> jumpTo(int index) => engine.jumpTo(index);
}

/// 识别入口：[MusicScrapeService] 的两个方法（测试注入假件，不联网）。
class MusicCtlScraper {
  const MusicCtlScraper({
    required this.scrapeTrack,
    required this.scrapeLibrary,
  });

  final Future<MusicScrapeOutcome> Function(
    String trackUid, {
    String? manualRecordingId,
  })
  scrapeTrack;
  final Future<MusicLibraryScrapeReport> Function({
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
  })
  scrapeLibrary;
}

/// 「识别整个曲库」后台任务的状态。
enum MusicScrapeJobStatus { running, done, failed, cancelled }

/// 一次「识别整个曲库」。MusicBrainz 1 req/s，整库可能跑很久，所以后台跑、按 id 查进度。
class MusicScrapeJob {
  MusicScrapeJob(this.id, this.startedAt);

  final String id;
  final int startedAt;
  MusicScrapeJobStatus status = MusicScrapeJobStatus.running;
  int done = 0;
  int total = 0;
  bool cancelRequested = false;
  int? finishedAt;
  MusicLibraryScrapeReport? report;
  String? error;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'status': status.name,
    'done': done,
    'total': total,
    'startedAt': startedAt,
    if (finishedAt != null) 'finishedAt': finishedAt,
    if (cancelRequested && status == MusicScrapeJobStatus.running)
      'cancelRequested': true,
    if (report != null)
      'report': <String, Object?>{
        'total': report!.total,
        'matched': report!.matched,
        'unmatched': report!.unmatched,
        'failed': report!.failed,
        'byMethod': report!.byMethod,
      },
    if (error != null) 'error': error,
  };
}

/// 进程内的整库识别任务登记（一次只跑一个；记住最后一个供查询）。
class MusicScrapeJobs {
  MusicScrapeJobs();

  static final MusicScrapeJobs instance = MusicScrapeJobs();

  MusicScrapeJob? last;
  int _seq = 0;

  MusicScrapeJob? get running =>
      last?.status == MusicScrapeJobStatus.running ? last : null;

  MusicScrapeJob start(int now) =>
      last = MusicScrapeJob('music-scrape-$now-${++_seq}', now);
}

/// 路由表本体：数据库、模块门、播放器、识别入口、来源移除按回调注入，测试不必起
/// [OpContext]。
List<CtlRoute> buildMusicCtlRoutesFor({
  required FushiDatabase Function() database,
  required bool Function() musicEnabled,
  required MusicCtlPlayer Function() player,
  required MusicCtlScraper Function() scraper,
  required Future<void> Function(FushiDatabase db, int sourceId) removeSource,
  bool Function()? isReadonly,
  MusicScrapeJobs? jobs,
  int Function()? clock,
}) {
  final MusicScrapeJobs registry = jobs ?? MusicScrapeJobs.instance;
  int now() => (clock ?? () => DateTime.now().millisecondsSinceEpoch)();

  void requireMusic() {
    if (!musicEnabled()) {
      throw const CtlFailure.rejected('音乐模块已在设置里关闭（music）');
    }
  }

  void requireWritable() {
    requireMusic();
    if (isReadonly?.call() ?? false) {
      throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
    }
  }

  Future<MusicLibrarySnapshot> snapshot() async {
    requireMusic();
    return MusicLibrarySnapshot.load(database());
  }

  Future<MusicTrackRow> requireTrack(CtlCall call) async {
    final String uid = call.params['uid'] ?? '';
    final MusicTrackRow? track = await database().getMusicTrack(uid);
    if (track == null || track.deletedAt != null) {
      throw CtlFailure.notFound('曲库里没有曲目 $uid（见 music tracks）');
    }
    return track;
  }

  Map<String, Object?> playerJson() {
    final MusicCtlPlayer p = player();
    final MusicPlayItem? item = p.current;
    final List<MusicPlayItem> queue = p.queue;
    return <String, Object?>{
      'active': item != null,
      'playing': p.isPlaying,
      if (item != null) ...<String, Object?>{
        'track': _playItemJson(item),
        'index': _indexOf(queue, item),
        'positionMs': p.position.inMilliseconds,
        if (p.duration != null) 'durationMs': p.duration!.inMilliseconds,
      },
      'queue': <String>[for (final MusicPlayItem q in queue) q.trackUid],
    };
  }

  Future<List<MusicSourceRowJson>> musicSources() async => <MusicSourceRowJson>[
    for (final MediaSourceRow row in await database().getMediaSourcesByKind(
      SourceLibraryKind.music.dbValue,
    ))
      _sourceJson(row),
  ];

  return <CtlRoute>[
    // ── 曲库列表 / 搜索 ─────────────────────────────────────────────────
    CtlRoute.get('$kMusicCtlRoot/albums', (CtlCall call) async {
      final MusicLibrarySnapshot snap = await snapshot();
      final String query = call.optString('search') ?? '';
      final List<MusicAlbumRow> hits = <MusicAlbumRow>[
        for (final MusicAlbumRow a in snap.albums)
          if (matchesMediaSearch(
            query: query,
            titles: <String>[a.title, ?a.albumArtistCredit, ?a.catalogNo],
          ))
            a,
      ];
      return <String, Object?>{
        'albums': <Object?>[
          for (final MusicAlbumRow a in _limit(hits, call))
            _albumJson(a, snap.tracksOfAlbum(a.albumUid).length),
        ],
        'total': hits.length,
      };
    }),
    CtlRoute.get('$kMusicCtlRoot/albums/:uid', (CtlCall call) async {
      final MusicLibrarySnapshot snap = await snapshot();
      final String uid = call.params['uid'] ?? '';
      final MusicAlbumRow? album = snap.albumByUid[uid];
      if (album == null) throw CtlFailure.notFound('曲库里没有专辑 $uid');
      final List<MusicTrackRow> tracks = snap.tracksOfAlbum(uid);
      return <String, Object?>{
        ..._albumJson(album, tracks.length),
        'tracks': <Object?>[
          for (final MusicTrackRow t in tracks) _trackJson(t),
        ],
      };
    }),
    CtlRoute.get('$kMusicCtlRoot/artists', (CtlCall call) async {
      final MusicLibrarySnapshot snap = await snapshot();
      final String query = call.optString('search') ?? '';
      final List<MusicArtistRow> hits = <MusicArtistRow>[
        for (final MusicArtistRow a in snap.artists)
          if (matchesMediaSearch(
            query: query,
            titles: <String>[a.name, ?a.sortName],
          ))
            a,
      ];
      return <String, Object?>{
        'artists': <Object?>[
          for (final MusicArtistRow a in _limit(hits, call))
            <String, Object?>{
              'uid': a.artistUid,
              'name': a.name,
              if (a.kind != null) 'kind': a.kind,
            },
        ],
        'total': hits.length,
      };
    }),
    CtlRoute.get('$kMusicCtlRoot/tracks', (CtlCall call) async {
      final MusicLibrarySnapshot snap = await snapshot();
      final String query = call.optString('search') ?? '';
      final String? albumUid = call.optString('album');
      final String? artistUid = call.optString('artist');
      final List<MusicTrackRow> source = artistUid != null
          ? await database().listMusicTracksByArtist(artistUid)
          : (albumUid != null ? snap.tracksOfAlbum(albumUid) : snap.tracks);
      final List<MusicTrackRow> hits = <MusicTrackRow>[
        for (final MusicTrackRow t in source)
          if ((albumUid == null || t.albumUid == albumUid) &&
              matchesMediaSearch(
                query: query,
                titles: <String>[
                  t.title,
                  ?t.artistCredit,
                  ?snap.albumByUid[t.albumUid]?.title,
                ],
              ))
            t,
      ];
      return <String, Object?>{
        'tracks': <Object?>[
          for (final MusicTrackRow t in _limit(hits, call))
            _trackJson(t, album: snap.albumByUid[t.albumUid]),
        ],
        'total': hits.length,
      };
    }),
    CtlRoute.get('$kMusicCtlRoot/tracks/:uid', (CtlCall call) async {
      requireMusic();
      final MusicTrackRow track = await requireTrack(call);
      final FushiDatabase db = database();
      final MusicAlbumRow? album = track.albumUid == null
          ? null
          : await db.getMusicAlbum(track.albumUid!);
      final MusicScrapeMetaRow? meta = await db.getMusicScrapeMeta(
        track.trackUid,
      );
      return <String, Object?>{
        ..._trackJson(track, album: album),
        'path': track.path,
        'identification': meta == null
            ? <String, Object?>{'status': 'none'}
            : _identificationJson(meta),
      };
    }),
    CtlRoute.get('$kMusicCtlRoot/playlists', (CtlCall call) async {
      final MusicLibrarySnapshot snap = await snapshot();
      return <String, Object?>{
        'playlists': <Object?>[
          for (final MusicPlaylistRow p in snap.playlists)
            <String, Object?>{
              'uid': p.playlistUid,
              'name': p.name,
              'smart': p.rulesJson != null,
            },
        ],
      };
    }),

    // ── 识别（刮削）────────────────────────────────────────────────────
    CtlRoute.post('$kMusicCtlRoot/tracks/:uid/scrape', (CtlCall call) async {
      requireWritable();
      final MusicTrackRow track = await requireTrack(call);
      final String? manual = call.optString('recordingId')?.trim();
      if (manual != null && !_mbid.hasMatch(manual)) {
        throw CtlFailure.badRequest('recordingId 不是 MusicBrainz 录音 id：$manual');
      }
      final MusicScrapeOutcome outcome = await scraper().scrapeTrack(
        track.trackUid,
        manualRecordingId: (manual?.isEmpty ?? true) ? null : manual,
      );
      final MusicScrapeMetaRow? meta = await database().getMusicScrapeMeta(
        track.trackUid,
      );
      return <String, Object?>{
        'uid': track.trackUid,
        'status': outcome.status,
        if (outcome.error != null) 'error': '${outcome.error}',
        'identification': meta == null
            ? <String, Object?>{'status': 'none'}
            : _identificationJson(meta),
      };
    }),
    CtlRoute.get('$kMusicCtlRoot/scrape', (CtlCall call) async {
      requireMusic();
      final MusicScrapeJob? job = registry.last;
      return job == null
          ? const <String, Object?>{'active': false}
          : <String, Object?>{
              'active': job.status == MusicScrapeJobStatus.running,
              ...job.toJson(),
            };
    }),
    CtlRoute.post('$kMusicCtlRoot/scrape', (CtlCall call) async {
      requireWritable();
      final MusicScrapeJob? running = registry.running;
      if (running != null) {
        throw CtlFailure.conflict('已有整库识别在跑（任务 ${running.id}）');
      }
      final MusicCtlScraper s = scraper();
      final MusicScrapeJob job = registry.start(now());
      // 后台跑：MusicScrapeService 自己串行、遵守 1 req/s；这里只记进度与结局。
      () async {
        try {
          job.report = await s.scrapeLibrary(
            onProgress: (int done, int total) {
              job
                ..done = done
                ..total = total;
            },
            cancelled: () => job.cancelRequested,
          );
          job
            ..total = job.report!.total
            ..status = job.cancelRequested
                ? MusicScrapeJobStatus.cancelled
                : MusicScrapeJobStatus.done;
        } on Object catch (e) {
          job
            ..error = '$e'
            ..status = MusicScrapeJobStatus.failed;
        } finally {
          job.finishedAt = now();
        }
      }();
      return <String, Object?>{'taskId': job.id, ...job.toJson()};
    }),
    CtlRoute.post('$kMusicCtlRoot/scrape/cancel', (CtlCall call) async {
      requireMusic();
      final MusicScrapeJob? job = registry.running;
      if (job == null) throw const CtlFailure.notFound('没有正在跑的整库识别');
      job.cancelRequested = true;
      return <String, Object?>{'taskId': job.id, ...job.toJson()};
    }),

    // ── 扫描根 ─────────────────────────────────────────────────────────
    CtlRoute.get('$kMusicCtlRoot/sources', (CtlCall call) async {
      requireMusic();
      return <String, Object?>{'sources': await musicSources()};
    }),
    CtlRoute.post('$kMusicCtlRoot/sources', (CtlCall call) async {
      requireWritable();
      final String path = call.requireString('path');
      if (!File(path).isAbsolute) {
        throw CtlFailure.badRequest('路径必须是绝对路径：$path');
      }
      if (!Directory(path).existsSync()) {
        throw CtlFailure.notFound('目录不存在：$path');
      }
      final FushiDatabase db = database();
      // 曲库页「添加文件夹」同一函数（登记后立即扫描）。
      final AddLocalFolderResult result = await addLocalFolderAsSource(
        db: db,
        mediaKind: SourceLibraryKind.music.dbValue,
        path: path,
      );
      return <String, Object?>{
        'added': result.outcome == AddLocalFolderOutcome.added,
        if (result.sourceId != null) 'id': result.sourceId,
        'path': result.rootPath,
        'tracks': (await db.listMusicTracks()).length,
      };
    }),
    CtlRoute.delete('$kMusicCtlRoot/sources/:id', (CtlCall call) async {
      if (call.optBool('confirm') != true) {
        throw const CtlFailure.badRequest('移除扫描根需要 confirm: true（CLI 用 --yes）');
      }
      requireWritable();
      final int? id = int.tryParse(call.params['id'] ?? '');
      final FushiDatabase db = database();
      final MediaSourceRow? row = id == null
          ? null
          : await db.getMediaSourceById(id);
      if (row == null || row.mediaKind != SourceLibraryKind.music.dbValue) {
        throw CtlFailure.notFound('没有 id=${call.params['id']} 的音乐扫描根');
      }
      // 曲目行不挂来源外键，只删来源会留下曲库里的孤儿曲目：先按扫描器「文件已不在」
      // 同一方法把这个根下的曲目软删，再走来源页「移除来源」同一函数。磁盘文件不动。
      final int removed = await db.softDeleteMissingMusicTracks(
        sourceId: row.id,
        seenTrackUids: const <String>{},
        deletedAt: now(),
      );
      await removeSource(db, row.id);
      return <String, Object?>{
        'deleted': true,
        'id': row.id,
        'path': row.rootPath,
        'tracksRemoved': removed,
      };
    }),
    CtlRoute.post('$kMusicCtlRoot/scan', (CtlCall call) async {
      requireWritable();
      final FushiDatabase db = database();
      final int? only = call.optInt('source');
      final List<MediaSourceRow> targets = <MediaSourceRow>[
        for (final MediaSourceRow row in await db.getMediaSourcesByKind(
          SourceLibraryKind.music.dbValue,
        ))
          if (only == null || row.id == only) row,
      ];
      if (only != null && targets.isEmpty) {
        throw CtlFailure.notFound('没有 id=$only 的音乐扫描根');
      }
      // 曲库页「重新扫描」：逐个音乐来源扫（扫描器自己吞异常并写回 lastScanError）。
      final SourceLibraryScanner scanner = SourceLibraryScanner(db);
      final List<Map<String, Object?>> results = <Map<String, Object?>>[];
      for (final MediaSourceRow row in targets) {
        final SourceScanSummary summary = await scanner.scan(row);
        results.add(<String, Object?>{
          'id': row.id,
          'path': row.rootPath,
          'ok': summary.succeeded,
          if (summary.error != null) 'error': summary.error,
        });
      }
      return <String, Object?>{
        if (results.any((Map<String, Object?> r) => r['ok'] == false))
          'ok': false,
        'results': results,
        'tracks': (await db.listMusicTracks()).length,
      };
    }),

    // ── 播放遥控 ───────────────────────────────────────────────────────
    CtlRoute.get('$kMusicCtlRoot/player', (CtlCall call) async {
      requireMusic();
      return playerJson();
    }),
    CtlRoute.post('$kMusicCtlRoot/player/play', (CtlCall call) async {
      requireMusic();
      final MusicCtlPlayer p = player();
      final String? albumUid = call.optString('album');
      final List<String> trackUids = call.stringList('tracks');
      if (albumUid != null && trackUids.isNotEmpty) {
        throw const CtlFailure.badRequest('album 与 tracks 只能给一个');
      }
      if (albumUid == null && trackUids.isEmpty) {
        // 迷你播放条的播放键：续播当前队列。
        if (p.current == null) {
          throw const CtlFailure.conflict('没有可续播的队列：给 album 或 tracks');
        }
        await p.play();
        return playerJson();
      }
      final MusicLibrarySnapshot snap = await snapshot();
      final List<MusicPlayItem> items;
      final MusicQueueContext queueContext;
      if (albumUid != null) {
        final MusicAlbumRow? album = snap.albumByUid[albumUid];
        if (album == null) throw CtlFailure.notFound('曲库里没有专辑 $albumUid');
        // 专辑页「全部播放」/「随机播放」。
        items = <MusicPlayItem>[
          for (final MusicTrackRow t in snap.tracksOfAlbum(albumUid))
            musicPlayItemOf(t, album: album),
        ];
        queueContext = MusicQueueContext.album;
      } else {
        // 曲目列表点一首 = 以该列表为队列从这首开始播。
        final Map<String, MusicTrackRow> byUid = <String, MusicTrackRow>{
          for (final MusicTrackRow t in snap.tracks) t.trackUid: t,
        };
        items = <MusicPlayItem>[
          for (final String uid in trackUids)
            if (byUid[uid] case final MusicTrackRow t)
              musicPlayItemOf(t, album: snap.albumByUid[t.albumUid])
            else
              throw CtlFailure.notFound('曲库里没有曲目 $uid'),
        ];
        queueContext = MusicQueueContext.mixed;
      }
      if (items.isEmpty) throw const CtlFailure.conflict('专辑里没有曲目');
      final int index = call.optInt('index') ?? 0;
      if (index < 0 || index >= items.length) {
        throw CtlFailure.badRequest('index 越界：$index（共 ${items.length} 首）');
      }
      await p.playQueue(
        items,
        startIndex: index,
        context: queueContext,
        shuffle: call.optBool('shuffle') ?? false,
      );
      return playerJson();
    }),
    CtlRoute.post('$kMusicCtlRoot/player/pause', (CtlCall call) async {
      requireMusic();
      final MusicCtlPlayer p = player();
      if (p.current == null) throw const CtlFailure.conflict('没有在放音乐');
      await p.pause();
      return playerJson();
    }),
    CtlRoute.post('$kMusicCtlRoot/player/next', (CtlCall call) async {
      requireMusic();
      final MusicCtlPlayer p = player();
      if (p.current == null) throw const CtlFailure.conflict('没有在放音乐');
      await p.skipNext();
      return playerJson();
    }),
    CtlRoute.post('$kMusicCtlRoot/player/previous', (CtlCall call) async {
      requireMusic();
      final MusicCtlPlayer p = player();
      if (p.current == null) throw const CtlFailure.conflict('没有在放音乐');
      await p.skipPrevious();
      return playerJson();
    }),
    CtlRoute.post('$kMusicCtlRoot/player/jump', (CtlCall call) async {
      requireMusic();
      final MusicCtlPlayer p = player();
      final int? index = call.optInt('index');
      if (index == null) throw const CtlFailure.badRequest('index 缺失');
      if (index < 0 || index >= p.queue.length) {
        throw CtlFailure.badRequest('index 越界：$index（队列 ${p.queue.length} 首）');
      }
      // 队列面板点一首。
      await p.jumpTo(index);
      return playerJson();
    }),
  ];
}

/// 来源行的线上形状（与 `library sources` 同字段）。
typedef MusicSourceRowJson = Map<String, Object?>;

final RegExp _mbid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

int _indexOf(List<MusicPlayItem> queue, MusicPlayItem item) {
  final int same = queue.indexOf(item);
  return same >= 0
      ? same
      : queue.indexWhere((MusicPlayItem q) => q.trackUid == item.trackUid);
}

List<T> _limit<T>(List<T> rows, CtlCall call) {
  final int? limit = call.optInt('limit');
  if (limit == null) return rows;
  if (limit <= 0) throw CtlFailure.badRequest('limit 必须是正整数：$limit');
  return rows.length <= limit ? rows : rows.sublist(0, limit);
}

Map<String, Object?> _albumJson(MusicAlbumRow a, int trackCount) =>
    <String, Object?>{
      'uid': a.albumUid,
      'title': a.title,
      if (a.albumArtistCredit != null) 'artist': a.albumArtistCredit,
      if (a.releaseDate != null) 'date': a.releaseDate,
      if (a.catalogNo != null) 'catalogNo': a.catalogNo,
      'tracks': trackCount,
      if (a.discUid != null) 'disc': true,
    };

Map<String, Object?> _trackJson(MusicTrackRow t, {MusicAlbumRow? album}) =>
    <String, Object?>{
      'uid': t.trackUid,
      'title': t.title,
      if (t.artistCredit != null) 'artist': t.artistCredit,
      if (t.albumUid != null) 'albumUid': t.albumUid,
      if (album != null) 'album': album.title,
      if (t.discNo != null) 'disc': t.discNo,
      if (t.trackNo != null) 'no': t.trackNo,
      if (t.durationMs != null) 'durationMs': t.durationMs,
      if (t.mbRecordingId != null) 'recordingId': t.mbRecordingId,
    };

Map<String, Object?> _playItemJson(MusicPlayItem item) => <String, Object?>{
  'uid': item.trackUid,
  'title': item.title,
  if (item.artist != null) 'artist': item.artist,
  if (item.album != null) 'album': item.album,
};

Map<String, Object?> _identificationJson(MusicScrapeMetaRow meta) =>
    <String, Object?>{
      'status': meta.status,
      if (meta.method != null) 'method': meta.method,
      if (meta.mbRecordingId != null) 'recordingId': meta.mbRecordingId,
      if (meta.confidence != null) 'confidence': meta.confidence,
      if (meta.title != null) 'title': meta.title,
      if (meta.artistCredit != null) 'artist': meta.artistCredit,
      if (meta.albumTitle != null) 'album': meta.albumTitle,
      'scrapedAt': meta.scrapedAt,
      // 曲目页「选择匹配」列出的候选：recordingId 交回 scrape 即手动指定。
      'candidates': <Object?>[
        for (final MusicStoredRecording c in decodeMusicStoredRecordings(
          meta.candidatesJson,
        ))
          <String, Object?>{
            'recordingId': c.id,
            'title': c.title,
            if (c.artist != null) 'artist': c.artist,
            if (c.release != null) 'release': c.release,
            if (c.date != null) 'date': c.date,
          },
      ],
    };

MusicSourceRowJson _sourceJson(MediaSourceRow row) => <String, Object?>{
  'id': row.id,
  'label': row.label,
  'transport': row.transport,
  'path': row.rootPath,
  if (row.lastScannedAt != null)
    'lastScannedAt': row.lastScannedAt!.millisecondsSinceEpoch,
  if (row.lastScanError != null) 'lastScanError': row.lastScanError,
};
