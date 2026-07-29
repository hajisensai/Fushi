import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/anime_download_service.dart';
import 'package:hibiki/src/media/torrent/anime_download_subtitle_resolver.dart';
import 'package:hibiki/src/media/torrent/qb_torrent_backend.dart';
import 'package:hibiki/src/media/torrent/qbittorrent_client.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki/src/media/video/video_sidecar.dart'
    show listSidecarSubtitles, pickSidecar;

const String _kHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

const QbConnectionConfig _kConfig = QbConnectionConfig(
  baseUrl: 'http://127.0.0.1:8080',
  username: 'admin',
  password: 'secret',
);

/// 用 MockClient 驱动真实 [QBittorrentClient] 的 qb 假后端：
/// 模拟 `/api/v2/auth/login`（发 SID cookie）、`/torrents/info`、`/torrents/files`。
class _FakeQb {
  int infoRequests = 0;
  int filesRequests = 0;
  int factoryCalls = 0;
  String? lastInfoCategory;
  List<Map<String, dynamic>> torrents = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> files = <Map<String, dynamic>>[];

  late final MockClient mock = MockClient((http.Request request) async {
    final String path = request.url.path;
    if (path == '/api/v2/auth/login') {
      return http.Response('Ok.', 200,
          headers: <String, String>{'set-cookie': 'SID=fake123; path=/'});
    }
    if (path == '/api/v2/torrents/info') {
      infoRequests++;
      lastInfoCategory = request.url.queryParameters['category'];
      return http.Response(jsonEncode(torrents), 200);
    }
    if (path == '/api/v2/torrents/files') {
      filesRequests++;
      return http.Response(jsonEncode(files), 200);
    }
    return http.Response('not found', 404);
  });

  TorrentBackend newBackend(QbConnectionConfig config) {
    factoryCalls++;
    return QbTorrentBackend(QBittorrentClient(
      baseUrl: config.baseUrl,
      username: config.username,
      password: config.password,
      client: mock,
    ));
  }
}

Map<String, dynamic> _torrentJson({
  String hash = _kHash,
  String savePath = '',
  String contentPath = '',
  double progress = 1.0,
  String state = 'stalledUP',
  int amountLeft = 0,
}) {
  return <String, dynamic>{
    'hash': hash,
    'name': 'torrent',
    'progress': progress,
    'state': state,
    'save_path': savePath,
    'content_path': contentPath,
    'amount_left': amountLeft,
  };
}

AnimeDownloadPlan _plan({
  String id = _kHash,
  int? createdAtMs,
  List<PlanSubtitle> subtitles = const <PlanSubtitle>[],
}) {
  return AnimeDownloadPlan(
    id: id,
    createdAtMs: createdAtMs ?? DateTime.now().millisecondsSinceEpoch,
    seriesTitle: 'Show',
    torrentTitle: '[Sub] Show 01-12',
    magnet: 'magnet:?xt=urn:btih:$id',
    qbCategory: 'hibiki',
    subtitles: subtitles,
  );
}

void main() {
  group('resolveVideoAbsolutePaths', () {
    test('join savePath 并过滤视频扩展名', () {
      const TorrentSnapshot info = TorrentSnapshot(
        hash: _kHash,
        name: 'torrent',
        progress: 1,
        state: 'stalledUP',
        savePath: '/dl',
        contentPath: '/dl/Show',
        amountLeft: 0,
      );
      final List<String> videos =
          resolveVideoAbsolutePaths(info, const <TorrentFileEntry>[
        TorrentFileEntry(
            name: 'Show/Show - 01.mkv', size: 1, progress: 1, index: 0),
        TorrentFileEntry(
            name: 'Show/Show - 02.MP4', size: 1, progress: 1, index: 1),
        TorrentFileEntry(
            name: 'Show/readme.txt', size: 1, progress: 1, index: 2),
      ]);
      expect(videos, <String>[
        p.join('/dl', 'Show/Show - 01.mkv'),
        p.join('/dl', 'Show/Show - 02.MP4'),
      ]);
    });

    test('files 为空退化用 contentPath 单文件；非视频扩展则空', () {
      const TorrentSnapshot single = TorrentSnapshot(
        hash: _kHash,
        name: 'torrent',
        progress: 1,
        state: 'stalledUP',
        savePath: '/dl',
        contentPath: '/dl/movie.mkv',
        amountLeft: 0,
      );
      expect(resolveVideoAbsolutePaths(single, const <TorrentFileEntry>[]),
          <String>['/dl/movie.mkv']);

      const TorrentSnapshot nonVideo = TorrentSnapshot(
        hash: _kHash,
        name: 'torrent',
        progress: 1,
        state: 'stalledUP',
        savePath: '/dl',
        contentPath: '/dl/archive.zip',
        amountLeft: 0,
      );
      expect(resolveVideoAbsolutePaths(nonVideo, const <TorrentFileEntry>[]),
          isEmpty);
    });
  });

  group('pairSubtitlesToVideos', () {
    const PlanSubtitle ep1Ja = PlanSubtitle(
        episode: 1,
        fileName: 's01.ja.srt',
        stagedPath: '/s/1.srt',
        language: 'ja');
    const PlanSubtitle ep1Zh = PlanSubtitle(
        episode: 1,
        fileName: 's01.zh.srt',
        stagedPath: '/s/1zh.srt',
        language: 'zh');
    const PlanSubtitle ep2 =
        PlanSubtitle(episode: 2, fileName: 's02.srt', stagedPath: '/s/2.srt');
    const PlanSubtitle noEp =
        PlanSubtitle(fileName: 'movie.ass', stagedPath: '/s/m.ass');

    test('规则①：集号相等配对；同集多字幕取第一个', () {
      final Map<String, PlanSubtitle> pairs = pairSubtitlesToVideos(
        <String>['/v/Show - 01.mkv', '/v/Show - 02.mkv', '/v/Show - 03.mkv'],
        <PlanSubtitle>[ep1Ja, ep1Zh, ep2],
      );
      expect(pairs['/v/Show - 01.mkv'], same(ep1Ja));
      expect(pairs['/v/Show - 02.mkv'], same(ep2));
      expect(pairs.containsKey('/v/Show - 03.mkv'), isFalse);
    });

    test('规则②：恰好 1v1 且任一方集号缺失直接配对', () {
      expect(
        pairSubtitlesToVideos(<String>['/v/Movie.mkv'], <PlanSubtitle>[noEp]),
        <String, PlanSubtitle>{'/v/Movie.mkv': noEp},
      );
      // 视频无集号、字幕有集号：也直接配对。
      expect(
        pairSubtitlesToVideos(<String>['/v/Movie.mkv'], <PlanSubtitle>[ep1Ja]),
        <String, PlanSubtitle>{'/v/Movie.mkv': ep1Ja},
      );
      // 视频有集号、字幕无集号：也直接配对。
      expect(
        pairSubtitlesToVideos(
            <String>['/v/Show - 01.mkv'], <PlanSubtitle>[noEp]),
        <String, PlanSubtitle>{'/v/Show - 01.mkv': noEp},
      );
    });

    test('规则③：其余不配', () {
      // 1v1 双方都有集号但不等 → 不配。
      expect(
        pairSubtitlesToVideos(
            <String>['/v/Show - 01.mkv'], <PlanSubtitle>[ep2]),
        isEmpty,
      );
      // 多视频 + 无集号字幕 → 不配。
      expect(
        pairSubtitlesToVideos(<String>['/v/Show - 01.mkv', '/v/Show - 02.mkv'],
            <PlanSubtitle>[noEp]),
        isEmpty,
      );
      expect(pairSubtitlesToVideos(const <String>[], <PlanSubtitle>[ep1Ja]),
          isEmpty);
      expect(
          pairSubtitlesToVideos(
              <String>['/v/Show - 01.mkv'], const <PlanSubtitle>[]),
          isEmpty);
    });
  });

  group('sidecarPathFor', () {
    test('带语言：<视频目录>/<视频名去扩展>.<lang>.<字幕扩展>', () {
      const PlanSubtitle sub = PlanSubtitle(
          episode: 1,
          fileName: 'Show 01.ASS',
          stagedPath: '/s/x.ass',
          language: 'ja');
      expect(
        sidecarPathFor(p.join('/dl', 'Show', 'Show - 01.mkv'), sub),
        p.join('/dl', 'Show', 'Show - 01.ja.ass'),
      );
    });

    test('language null 省略 lang 段；字幕无扩展退化 .srt', () {
      const PlanSubtitle sub =
          PlanSubtitle(fileName: 'Show 01.srt', stagedPath: '/s/x.srt');
      expect(
        sidecarPathFor(p.join('/dl', 'Show - 01.mkv'), sub),
        p.join('/dl', 'Show - 01.srt'),
      );
      const PlanSubtitle noExt =
          PlanSubtitle(fileName: 'noext', stagedPath: '/s/noext');
      expect(
        sidecarPathFor(p.join('/dl', 'Show - 01.mkv'), noExt),
        p.join('/dl', 'Show - 01.srt'),
      );
    });
  });

  group('AnimeDownloadService.tick', () {
    late Directory tempDir;
    late AnimeDownloadPlanStore store;
    late _FakeQb qb;
    late List<(AnimeDownloadPlan, List<String>)> importCalls;
    late List<(AnimeDownloadPlan, List<String>)> bookImportCalls;
    Future<AnimeDownloadImportOutcome?> Function(
        AnimeDownloadPlan, List<String>)? importerOverride;
    Future<int?> Function(AnimeDownloadPlan, List<String>)?
        bookImporterOverride;
    late List<(AnimeDownloadPlan, List<String>)> subtitleResolverCalls;
    Future<ResolvedPlanSubtitles> Function(AnimeDownloadPlan, List<String>)?
        subtitleResolverOverride;

    AnimeDownloadService buildService({
      QbConnectionConfig? Function()? config,
      bool withSubtitleResolver = true,
    }) {
      return AnimeDownloadService(
        store: store,
        configProvider: config ?? () => _kConfig,
        subtitleResolver: !withSubtitleResolver
            ? null
            : (AnimeDownloadPlan plan, List<String> videos) async {
                subtitleResolverCalls.add((plan, videos));
                final Future<ResolvedPlanSubtitles> Function(
                        AnimeDownloadPlan, List<String>)? override =
                    subtitleResolverOverride;
                if (override != null) return override(plan, videos);
                return const ResolvedPlanSubtitles.failed('not stubbed');
              },
        importer: (AnimeDownloadPlan plan, List<String> videos) async {
          importCalls.add((plan, videos));
          if (importerOverride != null) return importerOverride!(plan, videos);
          return const AnimeDownloadImportOutcome(collectionId: 42);
        },
        bookImporter: (AnimeDownloadPlan plan, List<String> books) async {
          bookImportCalls.add((plan, books));
          if (bookImporterOverride != null) {
            return bookImporterOverride!(plan, books);
          }
          return books.length;
        },
        backendFactory: qb.newBackend,
        interval: const Duration(hours: 1),
      );
    }

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('anime_dl_service_test');
      store = AnimeDownloadPlanStore(
        baseDir: Directory(p.join(tempDir.path, 'anime_downloads')),
      );
      qb = _FakeQb();
      importCalls = <(AnimeDownloadPlan, List<String>)>[];
      bookImportCalls = <(AnimeDownloadPlan, List<String>)>[];
      subtitleResolverCalls = <(AnimeDownloadPlan, List<String>)>[];
      importerOverride = null;
      bookImporterOverride = null;
      subtitleResolverOverride = null;
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('未配置（null 或显式 qb 空 baseUrl）不动作', () async {
      // 注：默认 auto 在桌面 = 内置引擎 = 已配置（开箱即用）；"未配置"现指
      // null 或显式选了外接 qb 但没填地址。
      await store.save(_plan());
      await buildService(config: () => null).tick();
      await buildService(
          config: () => const QbConnectionConfig(
              backend: QbConnectionConfig.backendQbittorrent)).tick();
      expect(qb.factoryCalls, 0);
      expect(importCalls, isEmpty);
    });

    test('无 downloading 计划不建连接', () async {
      await store
          .save(_plan().copyWith(status: AnimeDownloadPlan.statusImported));
      await buildService().tick();
      expect(qb.factoryCalls, 0);
    });

    test('列种子按 config.category 过滤', () async {
      await store.save(_plan());
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(state: 'downloading', progress: 0.1, amountLeft: 5),
      ];
      await buildService().tick();
      expect(qb.lastInfoCategory, 'hibiki');
    });

    test('种子未完成不导入，计划保持 downloading', () async {
      await store.save(_plan());
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(state: 'downloading', progress: 0.5, amountLeft: 100),
      ];
      await buildService().tick();
      expect(importCalls, isEmpty);
      expect(qb.filesRequests, 0);
      expect((await store.loadAll()).single.status,
          AnimeDownloadPlan.statusDownloading);
    });

    // ========================================================================
    // BUG-1206：字幕改成「下载完成时按包内真实文件名补取」
    // ========================================================================

    /// 造一个「完成的整季包」场景：savePath 下 12 个真实视频文件（01-12）。
    (String, List<Map<String, dynamic>>) completedSeasonPack() {
      final String savePath = p.join(tempDir.path, 'downloads');
      Directory(p.join(savePath, 'Show')).createSync(recursive: true);
      return (
        savePath,
        <Map<String, dynamic>>[
          for (int ep = 1; ep <= 12; ep++)
            <String, dynamic>{
              'name': 'Show/[Grp] Show - ${ep.toString().padLeft(2, '0')} '
                  '[1080p].mkv',
              'size': 10,
              'progress': 1.0,
            },
        ],
      );
    }

    test('BUG-1206 pending 计划：完成时才补取，resolver 拿到的是包内真实视频路径', () async {
      final (String savePath, List<Map<String, dynamic>> files) =
          completedSeasonPack();
      await store.save(_plan().copyWith(
        jimakuEntryId: 7,
        subtitleStatus: AnimeDownloadPlan.subtitlePending,
      ));
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(savePath: savePath, contentPath: p.join(savePath, 'Show')),
      ];
      qb.files = files;

      final Directory subsDir = store.subsDirFor(_kHash)
        ..createSync(recursive: true);
      subtitleResolverOverride =
          (AnimeDownloadPlan plan, List<String> videos) async {
        final String staged = p.join(subsDir.path, 'Show - 03.ja.srt');
        File(staged).writeAsStringSync('cue');
        return ResolvedPlanSubtitles.ok(<PlanSubtitle>[
          PlanSubtitle(
              episode: 3,
              fileName: 'Show - 03.ja.srt',
              stagedPath: staged,
              language: 'ja'),
        ]);
      };

      await buildService().tick();

      // ① 补取真的发生在完成之后，且喂进去的是**包内真实文件**的绝对路径。
      expect(subtitleResolverCalls, hasLength(1));
      final (AnimeDownloadPlan calledPlan, List<String> videos) =
          subtitleResolverCalls.single;
      expect(calledPlan.jimakuEntryId, 7);
      expect(videos, hasLength(12));
      expect(
        videos.map(p.basename),
        contains('[Grp] Show - 03 [1080p].mkv'),
      );
      // ② 反查结果真的贴成了第 3 集的 sidecar（不是第 1 集，也不是全都贴）。
      expect(
        File(p.join(savePath, 'Show', '[Grp] Show - 03 [1080p].ja.srt'))
            .existsSync(),
        isTrue,
      );
      expect(
        File(p.join(savePath, 'Show', '[Grp] Show - 01 [1080p].ja.srt'))
            .existsSync(),
        isFalse,
      );
      // ③ 计划落成 resolved 并带上真配好的字幕。
      final AnimeDownloadPlan saved = (await store.loadAll()).single;
      expect(saved.subtitleStatus, AnimeDownloadPlan.subtitleResolved);
      expect(saved.subtitles.single.episode, 3);
      expect(saved.status, AnimeDownloadPlan.statusImported);
    });

    test('BUG-1206 反查一条都不配 → 落 unavailable + 原因，视频照常入库', () async {
      final (String savePath, List<Map<String, dynamic>> files) =
          completedSeasonPack();
      await store.save(_plan().copyWith(
        jimakuEntryId: 7,
        jimakuEntryName: 'Wrong Season Entry',
        subtitleStatus: AnimeDownloadPlan.subtitlePending,
      ));
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(savePath: savePath, contentPath: p.join(savePath, 'Show')),
      ];
      qb.files = files;
      subtitleResolverOverride = (_, __) async =>
          const ResolvedPlanSubtitles.failed(
              'no jimaku file matches the pack episodes');

      await buildService().tick();

      final AnimeDownloadPlan saved = (await store.loadAll()).single;
      expect(saved.subtitleStatus, AnimeDownloadPlan.subtitleUnavailable);
      expect(saved.subtitleNote, 'no jimaku file matches the pack episodes',
          reason: '不能静默：原因要落进计划，任务行才显示得出来');
      expect(saved.subtitles, isEmpty);
      // 字幕没配上不该把整个下载判失败——视频还是要进库。
      expect(saved.status, AnimeDownloadPlan.statusImported);
      expect(importCalls, hasLength(1));
    });

    test('BUG-1206 老计划（选种时已下好字幕）不重取、不覆盖', () async {
      final (String savePath, List<Map<String, dynamic>> files) =
          completedSeasonPack();
      final Directory subsDir = store.subsDirFor(_kHash)
        ..createSync(recursive: true);
      final String staged = p.join(subsDir.path, 'legacy 05.srt');
      File(staged).writeAsStringSync('legacy cue');
      // 老计划反序列化后 subtitleStatus = resolved（decode 的兼容分支）。
      await store.save(_plan(subtitles: <PlanSubtitle>[
        PlanSubtitle(episode: 5, fileName: 'legacy 05.srt', stagedPath: staged),
      ]).copyWith(subtitleStatus: AnimeDownloadPlan.subtitleResolved));
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(savePath: savePath, contentPath: p.join(savePath, 'Show')),
      ];
      qb.files = files;

      await buildService().tick();

      expect(subtitleResolverCalls, isEmpty, reason: '老计划的字幕是既有数据，绝不能重取或覆盖');
      expect(
        File(p.join(savePath, 'Show', '[Grp] Show - 05 [1080p].srt'))
            .readAsStringSync(),
        'legacy cue',
      );
      expect((await store.loadAll()).single.subtitles.single.fileName,
          'legacy 05.srt');
    });

    test('BUG-1206 没接 resolver 时 pending 计划落 unavailable，不静默', () async {
      final (String savePath, List<Map<String, dynamic>> files) =
          completedSeasonPack();
      await store.save(_plan().copyWith(
        jimakuEntryId: 7,
        subtitleStatus: AnimeDownloadPlan.subtitlePending,
      ));
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(savePath: savePath, contentPath: p.join(savePath, 'Show')),
      ];
      qb.files = files;

      await buildService(withSubtitleResolver: false).tick();

      final AnimeDownloadPlan saved = (await store.loadAll()).single;
      expect(saved.subtitleStatus, AnimeDownloadPlan.subtitleUnavailable);
      expect(saved.subtitleNote, isNotEmpty);
    });

    test('完成 → sidecar 落位 + importer 收到视频列表 + 计划标 imported', () async {
      // 暂存字幕。
      final Directory subsDir = store.subsDirFor(_kHash)
        ..createSync(recursive: true);
      final String staged = p.join(subsDir.path, 'Show 01.ja.srt');
      File(staged).writeAsStringSync('subtitle content');

      final String savePath = p.join(tempDir.path, 'downloads');
      Directory(savePath).createSync(recursive: true);

      await store.save(_plan(subtitles: <PlanSubtitle>[
        PlanSubtitle(
            episode: 1,
            fileName: 'Show 01.ja.srt',
            stagedPath: staged,
            language: 'ja'),
      ]));
      // 种子 hash 用大写：验证与计划 id 的比对是大小写不敏感的。
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(
          hash: _kHash.toUpperCase(),
          savePath: savePath,
          contentPath: p.join(savePath, 'Show'),
        ),
      ];
      qb.files = <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Show/Show - 01.mkv',
          'size': 10,
          'progress': 1.0,
          'index': 0,
        },
        <String, dynamic>{
          'name': 'Show/info.nfo',
          'size': 1,
          'progress': 1.0,
          'index': 1,
        },
      ];

      await buildService().tick();

      final String expectedVideo = p.join(savePath, 'Show/Show - 01.mkv');
      expect(importCalls, hasLength(1));
      expect(importCalls.single.$2, <String>[expectedVideo]);

      final String sidecar = sidecarPathFor(
          expectedVideo,
          PlanSubtitle(
              episode: 1,
              fileName: 'Show 01.ja.srt',
              stagedPath: staged,
              language: 'ja'));
      expect(File(sidecar).existsSync(), isTrue);
      expect(File(sidecar).readAsStringSync(), 'subtitle content');

      final AnimeDownloadPlan saved = (await store.loadAll()).single;
      expect(saved.status, AnimeDownloadPlan.statusImported);
      expect(saved.collectionId, 42);
    });

    test('sidecar 已存在同名文件不覆盖', () async {
      final Directory subsDir = store.subsDirFor(_kHash)
        ..createSync(recursive: true);
      final String staged = p.join(subsDir.path, 'Show 01.ja.srt');
      File(staged).writeAsStringSync('new content');

      final String savePath = p.join(tempDir.path, 'downloads');
      final String video = p.join(savePath, 'Show - 01.mkv');
      const PlanSubtitle sub = PlanSubtitle(
          episode: 1,
          fileName: 'Show 01.ja.srt',
          stagedPath: '',
          language: 'ja');
      final String sidecar = sidecarPathFor(video, sub);
      File(sidecar).createSync(recursive: true);
      File(sidecar).writeAsStringSync('user edited');

      await store.save(_plan(subtitles: <PlanSubtitle>[
        PlanSubtitle(
            episode: 1,
            fileName: 'Show 01.ja.srt',
            stagedPath: staged,
            language: 'ja'),
      ]));
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(savePath: savePath, contentPath: video),
      ];
      qb.files = <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Show - 01.mkv',
          'size': 10,
          'progress': 1.0,
          'index': 0,
        },
      ];

      await buildService().tick();
      expect(File(sidecar).readAsStringSync(), 'user edited');
      expect((await store.loadAll()).single.status,
          AnimeDownloadPlan.statusImported);
    });

    // BUG-1189 跟进：去重键必须**语言无关**。本 PR 让 detectSubtitleLanguage 认出
    // Netflix 的 `ja[cc]` 之后，同一集的目标名从 `x.srt` 变成 `x.ja.srt`，老档就挡不
    // 住写入了 —— 重下一次多一份字幕，且 pickSidecar 把带语言标记的排在前面，默认
    // 选中还会从老档悄悄切到 `.ja` 档。用户看得见，且随重下次数累积。
    test('🔴 同一集重下不产生第二份字幕：老 x.srt 挡住新的 x.ja.srt', () async {
      final Directory subsDir = store.subsDirFor(_kHash)
        ..createSync(recursive: true);
      final String staged = p.join(subsDir.path, 'Show 01.ja.srt');
      File(staged).writeAsStringSync('new content');

      final String savePath = p.join(tempDir.path, 'downloads');
      final String video = p.join(savePath, 'Show - 01.mkv');

      // 上一次下载留下的**无语言段**老档（这就是本 PR 之前所有已下字幕的样子）。
      final String legacySidecar = p.join(savePath, 'Show - 01.srt');
      File(legacySidecar).createSync(recursive: true);
      File(legacySidecar).writeAsStringSync('legacy subtitle');

      // 本轮要落位的是带语言段的新名字 —— 与老档不同名，旧的「同名跳过」拦不住。
      const PlanSubtitle sub = PlanSubtitle(
          episode: 1,
          fileName: 'Show 01.ja.srt',
          stagedPath: '',
          language: 'ja');
      final String langSidecar = sidecarPathFor(video, sub);
      expect(langSidecar, isNot(legacySidecar),
          reason: '前提：两者不同名，否则这条用例证明不了语言无关去重');

      await store.save(_plan(subtitles: <PlanSubtitle>[
        PlanSubtitle(
            episode: 1,
            fileName: 'Show 01.ja.srt',
            stagedPath: staged,
            language: 'ja'),
      ]));
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(savePath: savePath, contentPath: video),
      ];
      qb.files = <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Show - 01.mkv',
          'size': 10,
          'progress': 1.0,
          'index': 0,
        },
      ];

      await buildService().tick();

      expect(File(langSidecar).existsSync(), isFalse,
          reason: '该集已有 sidecar，不得再写第二份');
      expect(File(legacySidecar).readAsStringSync(), 'legacy subtitle',
          reason: '老档可能是用户手放/手改的，绝不覆盖或删除');

      // 默认选中的确定答案：目录里始终只有一份 sidecar，所以「默认选中悄悄切档」
      // 这件事根本不会发生 —— pickSidecar 无论学习语言是什么都只能挑到老档。
      final List<String> dirFiles = Directory(savePath)
          .listSync()
          .whereType<File>()
          .map((File f) => p.basename(f.path))
          .toList();
      expect(
        listSidecarSubtitles('Show - 01', dirFiles),
        <String>['Show - 01.srt'],
        reason: '同一集有且只有一份 sidecar',
      );
      expect(
          pickSidecar('Show - 01', dirFiles, langCode: 'ja'), 'Show - 01.srt');
    });

    test('该集本来没有任何 sidecar 时照常落位（去重不得误伤首次下载）', () async {
      final Directory subsDir = store.subsDirFor(_kHash)
        ..createSync(recursive: true);
      final String staged = p.join(subsDir.path, 'Show 01.ja.srt');
      File(staged).writeAsStringSync('fresh content');

      final String savePath = p.join(tempDir.path, 'downloads');
      final String video = p.join(savePath, 'Show - 01.mkv');
      // 同目录里放一集**别的**视频的 sidecar：去重是按集（stem）判的，
      // 不能因为目录里有任何字幕就整体不落位。
      Directory(savePath).createSync(recursive: true);
      File(p.join(savePath, 'Show - 02.srt')).writeAsStringSync('other ep');

      await store.save(_plan(subtitles: <PlanSubtitle>[
        PlanSubtitle(
            episode: 1,
            fileName: 'Show 01.ja.srt',
            stagedPath: staged,
            language: 'ja'),
      ]));
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(savePath: savePath, contentPath: video),
      ];
      qb.files = <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Show - 01.mkv',
          'size': 10,
          'progress': 1.0,
          'index': 0,
        },
      ];

      await buildService().tick();

      expect(File(p.join(savePath, 'Show - 01.ja.srt')).readAsStringSync(),
          'fresh content',
          reason: '本集无 sidecar → 必须正常落位；别集的字幕不该挡住它');
    });

    test('importer 抛异常 → 计划标 failed 不重试', () async {
      importerOverride = (AnimeDownloadPlan plan, List<String> videos) async {
        throw StateError('db exploded');
      };
      await store.save(_plan());
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(contentPath: '/dl/movie.mkv', savePath: '/dl'),
      ];

      final AnimeDownloadService service = buildService();
      await service.tick();
      final AnimeDownloadPlan saved = (await store.loadAll()).single;
      expect(saved.status, AnimeDownloadPlan.statusFailed);
      expect(saved.failReason, contains('db exploded'));

      // failed 后下轮不再触碰：无 downloading 计划 → 不建连接。
      final int factoryCallsBefore = qb.factoryCalls;
      await service.tick();
      expect(qb.factoryCalls, factoryCallsBefore);
      expect(importCalls, hasLength(1));
    });

    test('importer 返回 null → 计划标 failed', () async {
      importerOverride =
          (AnimeDownloadPlan plan, List<String> videos) async => null;
      await store.save(_plan());
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(contentPath: '/dl/movie.mkv', savePath: '/dl'),
      ];
      await buildService().tick();
      final AnimeDownloadPlan saved = (await store.loadAll()).single;
      expect(saved.status, AnimeDownloadPlan.statusFailed);
      expect(saved.failReason, 'import failed');
    });

    test('种子丢失：超 48h 标 failed(torrent missing)，未超跳过等下轮', () async {
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      await store.save(_plan(id: 'b' * 40, createdAtMs: nowMs - 1000));
      await store.save(_plan(
        id: 'c' * 40,
        createdAtMs: nowMs - const Duration(hours: 49).inMilliseconds,
      ));
      qb.torrents = <Map<String, dynamic>>[]; // qb 列表为空 = 都被删了。

      await buildService().tick();
      final List<AnimeDownloadPlan> plans = await store.loadAll();
      final AnimeDownloadPlan fresh =
          plans.singleWhere((AnimeDownloadPlan e) => e.id == 'b' * 40);
      final AnimeDownloadPlan stale =
          plans.singleWhere((AnimeDownloadPlan e) => e.id == 'c' * 40);
      expect(fresh.status, AnimeDownloadPlan.statusDownloading);
      expect(stale.status, AnimeDownloadPlan.statusFailed);
      expect(stale.failReason, 'torrent missing');
      expect(importCalls, isEmpty);
    });

    test('防重入：上一 tick 未完成时再 tick 直接跳过，完成后可再 tick', () async {
      final Completer<AnimeDownloadImportOutcome?> gate =
          Completer<AnimeDownloadImportOutcome?>();
      importerOverride =
          (AnimeDownloadPlan plan, List<String> videos) => gate.future;

      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      await store.save(_plan()); // 会走到 importer 并卡在 gate 上。
      await store.save(
          _plan(id: 'd' * 40, createdAtMs: nowMs)); // 种子缺席，保持 downloading。
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(contentPath: '/dl/movie.mkv', savePath: '/dl'),
      ];

      final AnimeDownloadService service = buildService();
      final Future<void> first = service.tick();
      // 等第一 tick 建好连接并卡在 importer 的 gate 上。
      while (qb.factoryCalls == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // 第一 tick 未完成（gate 未放行）：再 tick 应立即返回、不建第二个连接。
      await service.tick();
      expect(qb.factoryCalls, 1);

      gate.complete(const AnimeDownloadImportOutcome(collectionId: 7));
      await first;
      expect(importCalls, hasLength(1));
      expect(qb.infoRequests, 1);

      // 第一 tick 收尾后标志复位：还有 downloading 计划（种子缺席那条），可再 tick。
      await service.tick();
      expect(qb.factoryCalls, 2);
    });

    test('start 立即 tick 一次；stop 停止', () async {
      await store.save(_plan());
      qb.torrents = <Map<String, dynamic>>[
        _torrentJson(state: 'downloading', progress: 0.5, amountLeft: 100),
      ];
      final AnimeDownloadService service = buildService();
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(qb.factoryCalls, 1);
      service.stop();
    });

    group('importNow（边下边播提前入库）', () {
      test('元数据未就绪（files 空）→ false 且计划状态不动', () async {
        await store.save(_plan());
        qb.torrents = <Map<String, dynamic>>[
          _torrentJson(state: 'downloading', progress: 0.05, amountLeft: 900),
        ];
        qb.files = <Map<String, dynamic>>[]; // 磁力刚添加，元数据未解析。
        final bool ok = await buildService().importNow(_kHash);
        expect(ok, isFalse);
        expect(importCalls, isEmpty);
        expect((await store.loadAll()).single.status,
            AnimeDownloadPlan.statusDownloading);
      });

      test('未完成但文件已解析 → 提前入库后继续跟踪进度，完成时不重复导入', () async {
        final String savePath = p.join(tempDir.path, 'downloads');
        Directory(savePath).createSync(recursive: true);
        await store.save(_plan());
        qb.torrents = <Map<String, dynamic>>[
          _torrentJson(
              state: 'downloading',
              progress: 0.2,
              amountLeft: 800,
              savePath: savePath),
        ];
        qb.files = <Map<String, dynamic>>[
          <String, dynamic>{'name': 'Show 01.mkv', 'size': 1, 'progress': 0.5},
        ];
        final AnimeDownloadService service = buildService();
        expect(await service.importNow(_kHash), isTrue);
        expect(importCalls, hasLength(1));
        expect(importCalls.single.$2.single, p.join(savePath, 'Show 01.mkv'));
        AnimeDownloadPlan saved = (await store.loadAll()).single;
        expect(saved.status, AnimeDownloadPlan.statusDownloading);
        expect(saved.importedEarly, isTrue);
        expect(saved.collectionId, 42);
        expect(service.downloadProgress.value[_kHash], 0.2);

        // 提前入库不是下载完成：后续 tick 继续刷新真实进度，且不重复导入。
        qb.torrents = <Map<String, dynamic>>[
          _torrentJson(
              state: 'downloading',
              progress: 0.55,
              amountLeft: 450,
              savePath: savePath),
        ];
        await service.tick();
        expect(importCalls, hasLength(1));
        expect(service.downloadProgress.value[_kHash], 0.55);
        expect((await store.loadAll()).single.status,
            AnimeDownloadPlan.statusDownloading);

        // 真正完成后才转 imported；提前入库的视频仍不重复导入。
        qb.torrents = <Map<String, dynamic>>[
          _torrentJson(
              state: 'stalledUP',
              progress: 1,
              amountLeft: 0,
              savePath: savePath),
        ];
        await service.tick();
        saved = (await store.loadAll()).single;
        expect(saved.status, AnimeDownloadPlan.statusImported);
        expect(saved.importedEarly, isTrue);
        expect(saved.collectionId, 42);
        expect(importCalls, hasLength(1));
      });

      test('计划不存在 / 种子不在列表 → false', () async {
        expect(await buildService().importNow('nosuch'), isFalse);
        await store.save(_plan());
        qb.torrents = <Map<String, dynamic>>[]; // 种子不在 qb。
        expect(await buildService().importNow(_kHash), isFalse);
        expect((await store.loadAll()).single.status,
            AnimeDownloadPlan.statusDownloading);
      });
    });

    group('内容分流（书/视频/自动）', () {
      AnimeDownloadPlan bookPlan({String id = _kHash, String? kind}) =>
          AnimeDownloadPlan(
            id: id,
            createdAtMs: DateTime.now().millisecondsSinceEpoch,
            seriesTitle: 'A Book',
            torrentTitle: 'A Book.epub',
            magnet: 'magnet:?xt=urn:btih:$id',
            qbCategory: 'hibiki',
            contentKind: kind ?? AnimeDownloadPlan.kindBook,
          );

      test('book 计划：epub 走书库回调、不碰视频入库、标 imported', () async {
        await store.save(bookPlan());
        qb.torrents = <Map<String, dynamic>>[
          _torrentJson(savePath: '/dl', contentPath: '/dl/A Book.epub'),
        ];
        qb.files = <Map<String, dynamic>>[
          <String, dynamic>{'name': 'A Book.epub', 'size': 9, 'progress': 1.0},
        ];
        await buildService().tick();
        expect(importCalls, isEmpty); // 视频入库未触发
        expect(bookImportCalls, hasLength(1));
        expect(
            bookImportCalls.single.$2, <String>[p.join('/dl', 'A Book.epub')]);
        final AnimeDownloadPlan saved = (await store.loadAll()).single;
        expect(saved.status, AnimeDownloadPlan.statusImported);
        expect(saved.collectionId, isNull); // 书无合集
      });

      test('auto 计划：视频→视频库、epub→书库，两者都调', () async {
        final String savePath = p.join(tempDir.path, 'dl');
        Directory(savePath).createSync(recursive: true);
        await store.save(bookPlan(kind: AnimeDownloadPlan.kindAuto));
        qb.torrents = <Map<String, dynamic>>[
          _torrentJson(savePath: savePath, contentPath: savePath),
        ];
        qb.files = <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'Show - 01.mkv',
            'size': 9,
            'progress': 1.0
          },
          <String, dynamic>{'name': 'Bonus.epub', 'size': 9, 'progress': 1.0},
          <String, dynamic>{'name': 'readme.txt', 'size': 1, 'progress': 1.0},
        ];
        await buildService().tick();
        expect(importCalls, hasLength(1));
        expect(
            importCalls.single.$2, <String>[p.join(savePath, 'Show - 01.mkv')]);
        expect(bookImportCalls, hasLength(1));
        expect(bookImportCalls.single.$2,
            <String>[p.join(savePath, 'Bonus.epub')]);
        expect((await store.loadAll()).single.status,
            AnimeDownloadPlan.statusImported);
      });

      test('book 计划书库回调返回 0 → 标 failed', () async {
        bookImporterOverride =
            (AnimeDownloadPlan plan, List<String> books) async => 0;
        await store.save(bookPlan());
        qb.torrents = <Map<String, dynamic>>[
          _torrentJson(savePath: '/dl', contentPath: '/dl/A Book.epub'),
        ];
        qb.files = <Map<String, dynamic>>[
          <String, dynamic>{'name': 'A Book.epub', 'size': 9, 'progress': 1.0},
        ];
        await buildService().tick();
        expect((await store.loadAll()).single.status,
            AnimeDownloadPlan.statusFailed);
      });
    });

    group('resolveBookAbsolutePaths', () {
      test('过滤 epub；files 空退化 contentPath', () {
        const TorrentSnapshot info = TorrentSnapshot(
          hash: _kHash,
          name: 't',
          progress: 1,
          state: 'stalledUP',
          savePath: '/dl',
          contentPath: '/dl/x.epub',
          amountLeft: 0,
        );
        expect(
          resolveBookAbsolutePaths(info, const <TorrentFileEntry>[
            TorrentFileEntry(name: 'a.epub', size: 1, progress: 1, index: 0),
            TorrentFileEntry(name: 'b.mkv', size: 1, progress: 1, index: 1),
          ]),
          <String>[p.join('/dl', 'a.epub')],
        );
        expect(resolveBookAbsolutePaths(info, const <TorrentFileEntry>[]),
            <String>['/dl/x.epub']);
      });
    });
  });
}
