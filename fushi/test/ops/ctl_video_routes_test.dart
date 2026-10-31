import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart'
    show VideoDiscoveryCategory;
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadSubtitlePolicy;
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart'
    show VideoMetadataLookup;
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart'
    show VideoSourceScrapeWork;

import 'package:fushi/src/media/manga/ocr/google_lens_disclosure.dart';
import 'package:fushi/src/media/video/video_ocr_cli_consent.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fushi/src/ops/ctl_video_player_support.dart';

import 'package:fushi/src/ops/ctl_video_routes.dart';
import 'package:fushi/src/ops/ctl_video_support.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 路由表构建期不碰 ref；任何访问都说明构建期越界读了 app 状态。
class _NoRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('构建路由表时不应访问 ref：${invocation.memberName}');
}

Matcher _badRequest() => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
);

void main() {
  group('buildVideoCtlRoutes', () {
    final List<CtlRoute> routes = buildVideoCtlRoutes(
      OpContext(ref: _NoRef(), focusMainWindow: () async {}),
    );

    test('路径都在 /api/admin/video/ 下，method + path 不重复', () {
      expect(routes, isNotEmpty);
      final Set<String> seen = <String>{};
      for (final CtlRoute route in routes) {
        expect(route.pattern, startsWith('/api/admin/video/'));
        expect(
          seen.add('${route.method} ${route.pattern}'),
          isTrue,
          reason: '重复路由 ${route.method} ${route.pattern}',
        );
      }
    });

    test('CLI 拼出的路径都能命中对应路由（含编码过的作品 id）', () {
      CtlRoute? first(String method, String path) {
        for (final CtlRoute route in routes) {
          if (route.method == method && route.match(path) != null) return route;
        }
        return null;
      }

      final CtlRoute? candidates = first(
        'GET',
        '/api/admin/video/works/book%3Aa%20b/candidates',
      );
      expect(candidates?.pattern, '/api/admin/video/works/:id/candidates');
      expect(
        candidates!.match('/api/admin/video/works/book%3Aa%20b/candidates'),
        <String, String>{'id': 'book:a b'},
      );
      expect(
        first(
          'POST',
          '/api/admin/video/works/collection%3A7/identify',
        )?.pattern,
        '/api/admin/video/works/:id/identify',
      );
      expect(
        first('POST', '/api/admin/video/scrape/cancel')?.pattern,
        '/api/admin/video/scrape/cancel',
      );
      expect(
        first('GET', '/api/admin/video/discovery/works/vw3/resources')?.pattern,
        '/api/admin/video/discovery/works/:id/resources',
      );
      expect(
        first('POST', '/api/admin/video/discovery/acquire')?.pattern,
        '/api/admin/video/discovery/acquire',
      );
    });
  });

  group('CtlVideoWorkId', () {
    test('book / collection', () {
      final CtlVideoWorkId book = CtlVideoWorkId.parse(' book:abc:def ');
      expect(book, isA<CtlVideoBookWorkId>());
      expect((book as CtlVideoBookWorkId).bookUid, 'abc:def');
      expect(book.stableKey, 'book:abc:def');
      final CtlVideoWorkId collection = CtlVideoWorkId.parse('collection:12');
      expect((collection as CtlVideoCollectionWorkId).collectionId, 12);
      expect(collection.stableKey, 'collection:12');
    });

    test('格式不对抛 400', () {
      for (final String bad in <String>[
        '',
        'book:',
        'collection:',
        'collection:0',
        'collection:x',
        '12',
        'work:1',
      ]) {
        expect(() => CtlVideoWorkId.parse(bad), _badRequest(), reason: bad);
      }
    });
  });

  group('CtlVideoScrapeTarget', () {
    test('数字 = 来源，其余 = 作品', () {
      final CtlVideoScrapeTarget source = CtlVideoScrapeTarget.parse('3');
      expect((source as CtlVideoSourceTarget).sourceId, 3);
      final CtlVideoScrapeTarget work = CtlVideoScrapeTarget.parse('book:x');
      expect((work as CtlVideoWorkTarget).workId.stableKey, 'book:x');
      expect(() => CtlVideoScrapeTarget.parse('0'), _badRequest());
      expect(() => CtlVideoScrapeTarget.parse('-1'), _badRequest());
      expect(() => CtlVideoScrapeTarget.parse('nope'), _badRequest());
    });
  });

  group('资料源白名单', () {
    test('只收 anidb / mal / tmdb（不分大小写）', () {
      expect(parseCtlVideoProvider('AniDB'), VideoMetadataProviderKind.anidb);
      expect(parseCtlVideoProvider('mal'), VideoMetadataProviderKind.mal);
      expect(parseCtlVideoProvider(' tmdb '), VideoMetadataProviderKind.tmdb);
      for (final String retired in <String>[
        'bangumi',
        'anilist',
        'douban',
        'fanart',
        'jikan',
      ]) {
        expect(
          () => parseCtlVideoProvider(retired),
          _badRequest(),
          reason: retired,
        );
      }
    });

    test('身份查询：与候选搜索框手打的格式一致，id 必须是正整数', () {
      expect(
        ctlVideoIdentityQuery(VideoMetadataProviderKind.anidb, '17617'),
        'anidb:17617',
      );
      expect(
        ctlVideoIdentityQuery(
          VideoMetadataProviderKind.tmdb,
          ' 209867 ',
          mediaKind: VideoMetadataMediaKind.tv,
        ),
        'tmdb:tv:209867',
      );
      for (final String bad in <String>['0', '-1', 'abc', '1.5', '']) {
        expect(
          () => ctlVideoIdentityQuery(VideoMetadataProviderKind.mal, bad),
          _badRequest(),
          reason: bad,
        );
      }
      expect(
        () => ctlVideoIdentityQuery(VideoMetadataProviderKind.bangumi, '1'),
        _badRequest(),
      );
    });

    test('媒体类型', () {
      expect(parseCtlVideoMediaKind(null), isNull);
      expect(parseCtlVideoMediaKind('TV'), VideoMetadataMediaKind.tv);
      expect(parseCtlVideoMediaKind('movie'), VideoMetadataMediaKind.movie);
      expect(() => parseCtlVideoMediaKind('ova'), _badRequest());
    });
  });

  group('发现参数', () {
    test('分类', () {
      expect(parseCtlVideoDiscoveryCategory(null), isNull);
      expect(parseCtlVideoDiscoveryCategory('all'), isNull);
      expect(
        parseCtlVideoDiscoveryCategory('Anime'),
        VideoDiscoveryCategory.anime,
      );
      expect(() => parseCtlVideoDiscoveryCategory('music'), _badRequest());
    });

    test('字幕策略缺省 bestEffort', () {
      expect(
        parseCtlVideoSubtitlePolicy(null),
        VideoDownloadSubtitlePolicy.bestEffort,
      );
      expect(
        parseCtlVideoSubtitlePolicy('besteffort'),
        VideoDownloadSubtitlePolicy.bestEffort,
      );
      expect(
        parseCtlVideoSubtitlePolicy('required'),
        VideoDownloadSubtitlePolicy.required,
      );
      expect(() => parseCtlVideoSubtitlePolicy('some'), _badRequest());
    });
  });

  group('CtlVideoCandidateCache', () {
    test('带前缀的递增短 id，超出容量丢最旧的', () {
      final CtlVideoCandidateCache<String> cache =
          CtlVideoCandidateCache<String>('vw', capacity: 2);
      final String a = cache.put('a');
      final String b = cache.put('b');
      expect(a, 'vw1');
      expect(b, 'vw2');
      expect(cache[' vw1 '], 'a');
      final String c = cache.put('c');
      expect(c, 'vw3');
      expect(cache['vw1'], isNull);
      expect(cache['vw2'], 'b');
      expect(cache.length, 2);
    });
  });

  test('刮削报告 JSON 带计数与问题原文', () {
    const SourceScrapeReport report = SourceScrapeReport(
      sourceIds: <int>[1],
      totalWorks: 2,
      succeededWorks: 1,
      failedWorks: 1,
      errors: <SourceScrapeIssue>[
        SourceScrapeIssue(workTitle: 'W', message: 'boom', workKey: 'book:x'),
      ],
    );
    final Map<String, Object?> json = ctlVideoReportJson(report);
    expect(json['totalWorks'], 2);
    expect(json['failedWorks'], 1);
    expect(json['errors'], <Object?>[
      <String, Object?>{'work': 'W', 'message': 'boom', 'workId': 'book:x'},
    ]);
  });

  group('播放页路由', () {
    final List<CtlRoute> routes = buildVideoCtlRoutes(
      OpContext(ref: _NoRef(), focusMainWindow: () async {}),
    );

    CtlRoute? first(String method, String path) {
      for (final CtlRoute route in routes) {
        if (route.method == method && route.match(path) != null) return route;
      }
      return null;
    }

    test('CLI 拼出的播放页 / 待确认 / 任务 / 暂存队列路径都能命中', () {
      for (final (String method, String path) in <(String, String)>[
        ('GET', '/api/admin/video/scrape/confirmation'),
        ('POST', '/api/admin/video/scrape/confirmation'),
        ('GET', '/api/admin/video/player'),
        ('POST', '/api/admin/video/player/volume'),
        ('GET', '/api/admin/video/player/audio-tracks'),
        ('POST', '/api/admin/video/player/audio-track'),
        ('GET', '/api/admin/video/player/subtitles'),
        ('POST', '/api/admin/video/player/subtitle'),
        ('POST', '/api/admin/video/player/subtitle/import'),
        ('POST', '/api/admin/video/player/subtitle/ocr'),
        ('POST', '/api/admin/video/player/subtitle/transcribe'),
        ('POST', '/api/admin/video/player/subtitle/align'),
        ('POST', '/api/admin/video/player/clip'),
        ('POST', '/api/admin/video/player/mine'),
        ('GET', '/api/admin/video/jobs'),
        ('GET', '/api/admin/video/mine-queue'),
        ('POST', '/api/admin/video/mine-queue/commit'),
      ]) {
        expect(first(method, path)?.pattern, path, reason: '$method $path');
      }
      expect(
        first(
          'GET',
          '/api/admin/video/jobs/vj3',
        )!.match('/api/admin/video/jobs/vj3'),
        <String, String>{'id': 'vj3'},
      );
      expect(
        first('POST', '/api/admin/video/jobs/vj3/cancel')?.pattern,
        '/api/admin/video/jobs/:id/cancel',
      );
      expect(
        first(
          'POST',
          '/api/admin/video/mine-queue/12/discard',
        )!.match('/api/admin/video/mine-queue/12/discard'),
        <String, String>{'id': '12'},
      );
    });
  });

  group('刮削待确认：CLI 与 app 内确认框回答同一个待决状态', () {
    SourceLibraryRow source(int id) => SourceLibraryRow(
      id: id,
      label: 'source-$id',
      mediaKind: 'video',
      transport: 'local',
      rootPath: 'D:/source-$id',
      recursive: true,
      videoGroupingMode: 'series',
      isPrivate: false,
      configJson: null,
      mediaCount: 0,
      lastScannedAt: null,
      lastScanError: null,
      sortOrder: 0,
      createdAt: 1,
    );

    Future<SourceLibraryRow?> sourceById(int id) async => source(id);

    test('交互式批次卡在待确认 → CLI 选第 2 个候选 → 批次继续并采用它', () async {
      final _ConfirmRunner runner = _ConfirmRunner();
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(runner);
      addTearDown(controller.dispose);

      final Future<SourceScrapeReport> task = controller.scrapeSource(
        source(1),
        interactive: true,
      );
      final VideoSourceScrapeConfirmation? pending =
          await waitForCtlVideoConfirmation(
            controller,
            const Duration(seconds: 5),
          );
      expect(pending, isNotNull);
      bool finished = false;
      unawaited(task.whenComplete(() => finished = true));
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse, reason: '没人回答时批次必须停在这里');

      final Map<String, Object?> json = ctlVideoConfirmationJson(pending!);
      final String id = json['id']! as String;
      expect(id, startsWith('sc'));
      expect(ctlVideoConfirmationId(pending), id, reason: '同一项多次读到同一个 id');
      expect(json['work'], 'Ambiguous');
      expect((json['candidates']! as List<Object?>).length, 2);
      expect(json['ai'], <String, Object?>{
        'index': 2,
        'confidence': 61,
        'reason': 'year',
      });

      final Map<String, Object?> answered = await answerCtlVideoConfirmation(
        controller,
        CtlVideoConfirmationAnswer.parse(
          const CtlCall(
            method: 'POST',
            path: '/api/admin/video/scrape/confirmation',
            body: <String, Object?>{'action': 'pick', 'index': 2},
          ),
        ),
        expectedId: id,
        sourceById: sourceById,
      );
      expect(answered['answer'], 'pick');
      expect(
        (answered['picked']! as Map<String, Object?>)['identity'],
        'tmdb:2',
      );

      final SourceScrapeReport report = await task;
      expect(runner.selected, same(runner.candidates[1]));
      expect(report.succeededWorks, 1);
      expect(controller.pendingConfirmation, isNull);
    });

    test('CLI 跳过：批次继续，作品记为待确认', () async {
      final _ConfirmRunner runner = _ConfirmRunner();
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(runner);
      addTearDown(controller.dispose);
      final Future<SourceScrapeReport> task = controller.scrapeSource(
        source(1),
        interactive: true,
      );
      await waitForCtlVideoConfirmation(controller, const Duration(seconds: 5));
      await answerCtlVideoConfirmation(
        controller,
        const CtlVideoSkipConfirmation(),
        sourceById: sourceById,
      );
      final SourceScrapeReport report = await task;
      expect(runner.selected, isNull);
      expect(report.pendingConfirmations, 1);
    });

    test('CLI 手动指定身份：按 id 直取作品后当作选中候选交回', () async {
      final _ConfirmRunner runner = _ConfirmRunner();
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(runner);
      addTearDown(controller.dispose);
      final Future<SourceScrapeReport> task = controller.scrapeSource(
        source(3),
        interactive: true,
      );
      await waitForCtlVideoConfirmation(controller, const Duration(seconds: 5));
      final CtlVideoConfirmationAnswer answer =
          CtlVideoConfirmationAnswer.parse(
            const CtlCall(
              method: 'POST',
              path: '/api/admin/video/scrape/confirmation',
              body: <String, Object?>{
                'action': 'identity',
                'provider': 'anidb',
                'externalId': '777',
              },
            ),
          );
      expect((answer as CtlVideoPickIdentity).query, 'anidb:777');
      final Map<String, Object?> answered = await answerCtlVideoConfirmation(
        controller,
        answer,
        sourceById: sourceById,
      );
      expect(answered['answer'], 'identity');
      await task;
      expect(runner.manualQueries, <String>['anidb:777']);
      expect(runner.manualSourceIds, <int>[3]);
      expect(runner.selected?.lookup.externalId, '777');
      expect(runner.selected?.lookup.provider, VideoMetadataProviderKind.anidb);
    });

    test('app 内先答了：CLI 拿 409，不会把答案落到下一项', () async {
      final _ConfirmRunner runner = _ConfirmRunner();
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(runner);
      addTearDown(controller.dispose);
      final Future<SourceScrapeReport> task = controller.scrapeSource(
        source(1),
        interactive: true,
      );
      final VideoSourceScrapeConfirmation pending =
          (await waitForCtlVideoConfirmation(
            controller,
            const Duration(seconds: 5),
          ))!;
      final String id = ctlVideoConfirmationId(pending);
      // 确认框点了第 1 个（同步完成完成器，清理还在微任务里）。
      expect(controller.confirmPending(pending.candidates.first), isTrue);
      await expectLater(
        answerCtlVideoConfirmation(
          controller,
          const CtlVideoPickCandidate(2),
          expectedId: id,
          sourceById: sourceById,
        ),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 409),
        ),
      );
      await task;
      expect(runner.selected, same(runner.candidates.first));
    });

    test('id 不符 / 序号越界 / 没有待确认', () async {
      final _ConfirmRunner runner = _ConfirmRunner();
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(runner);
      addTearDown(controller.dispose);
      await expectLater(
        answerCtlVideoConfirmation(
          controller,
          const CtlVideoSkipConfirmation(),
          sourceById: sourceById,
        ),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 409),
        ),
      );
      final Future<SourceScrapeReport> task = controller.scrapeSource(
        source(1),
        interactive: true,
      );
      await waitForCtlVideoConfirmation(controller, const Duration(seconds: 5));
      await expectLater(
        answerCtlVideoConfirmation(
          controller,
          const CtlVideoPickCandidate(1),
          expectedId: 'sc999999',
          sourceById: sourceById,
        ),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 409),
        ),
      );
      await expectLater(
        answerCtlVideoConfirmation(
          controller,
          const CtlVideoPickCandidate(3),
          sourceById: sourceById,
        ),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
        ),
      );
      expect(controller.pendingConfirmation, isNotNull, reason: '错误回答不动待决状态');
      controller.skipPendingConfirmation();
      await task;
    });

    test('回答解析：未知 action / 序号 / 资料源白名单', () {
      CtlCall call(Map<String, Object?> body) => CtlCall(
        method: 'POST',
        path: '/api/admin/video/scrape/confirmation',
        body: body,
      );
      expect(
        () => CtlVideoConfirmationAnswer.parse(call(<String, Object?>{})),
        _badRequest(),
      );
      expect(
        () => CtlVideoConfirmationAnswer.parse(
          call(<String, Object?>{'action': 'maybe'}),
        ),
        _badRequest(),
      );
      expect(
        () => CtlVideoConfirmationAnswer.parse(
          call(<String, Object?>{'action': 'pick', 'index': 0}),
        ),
        _badRequest(),
      );
      expect(
        () => CtlVideoConfirmationAnswer.parse(
          call(<String, Object?>{
            'action': 'identity',
            'provider': 'bangumi',
            'externalId': '1',
          }),
        ),
        _badRequest(),
      );
      expect(
        CtlVideoConfirmationAnswer.parse(
          call(<String, Object?>{'action': 'SKIP'}),
        ),
        isA<CtlVideoSkipConfirmation>(),
      );
    });

    test('批次结束时等待返回 null（不挂住）', () async {
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(_ConfirmRunner());
      addTearDown(controller.dispose);
      expect(
        await waitForCtlVideoConfirmation(
          controller,
          const Duration(seconds: 5),
        ),
        isNull,
      );
    });
  });

  group('播放页控制的纯函数', () {
    test('遥控失败 → 状态码', () {
      int status(String code) =>
          ctlVideoRemoteFailure(VideoRemoteFailure(code, 'm')).status;
      expect(status('no_video'), 409);
      expect(status('busy'), 409);
      expect(status('not_found'), 404);
      expect(status('unsupported'), 501);
      expect(status('bad_request'), 400);
      expect(status('failed'), 422);
      expect(
        ctlVideoRemoteFailure(
          const VideoRemoteFailure('needs_confirmation', 'm'),
        ).code,
        'needs_confirmation',
      );
    });

    test('音量 / 片段区间解析', () {
      expect(parseCtlVideoVolume(30), 30);
      expect(parseCtlVideoVolume('55.5'), 55.5);
      for (final Object? bad in <Object?>[-1, 101, 'x', null]) {
        expect(() => parseCtlVideoVolume(bad), _badRequest(), reason: '$bad');
      }
      CtlCall clip(Map<String, Object?> body) =>
          CtlCall(method: 'POST', path: '/x', body: body);
      expect(
        parseCtlVideoClipRange(
          clip(<String, Object?>{'startMs': 1000, 'endMs': 2500}),
        ),
        (startMs: 1000, endMs: 2500),
      );
      expect(
        () => parseCtlVideoClipRange(
          clip(<String, Object?>{'startMs': 3000, 'endMs': 2500}),
        ),
        _badRequest(),
      );
      expect(
        () => parseCtlVideoClipRange(clip(<String, Object?>{'startMs': 1})),
        _badRequest(),
      );
    });

    test('字幕轨：序号换成持久化值，越界 404', () {
      const VideoRemoteSubtitleState state = VideoRemoteSubtitleState(
        tracks: <VideoRemoteSubtitleTrack>[
          VideoRemoteSubtitleTrack(
            source: 'embedded:0',
            label: 'JP',
            kind: VideoRemoteSubtitleKind.embedded,
            primary: true,
            secondary: false,
            ocrAvailable: false,
          ),
          VideoRemoteSubtitleTrack(
            source: 'embedded:1',
            label: 'PGS',
            kind: VideoRemoteSubtitleKind.graphic,
            primary: false,
            secondary: false,
            ocrAvailable: true,
          ),
        ],
        primarySource: 'embedded:0',
        secondarySource: 'off:',
        remote: false,
        asrAvailable: true,
        alignAvailable: true,
      );
      expect(resolveCtlVideoSubtitleSource('2', state), 'embedded:1');
      expect(resolveCtlVideoSubtitleSource(' D:/a.srt ', state), 'D:/a.srt');
      expect(
        () => resolveCtlVideoSubtitleSource('3', state),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 404),
        ),
      );
      final Map<String, Object?> json = ctlVideoSubtitleStateJson(state);
      final List<Object?> tracks = json['tracks']! as List<Object?>;
      expect((tracks[1]! as Map<String, Object?>)['kind'], 'graphic');
      expect((tracks[1]! as Map<String, Object?>)['ocr'], isTrue);
      expect((tracks[1]! as Map<String, Object?>)['index'], 2);
      expect(json['secondary'], 'off:');
    });

    test('播放状态 JSON 带音量 / 音轨 / 主副字幕', () {
      expect(ctlVideoPlayerStatusJson(null), <String, Object?>{
        'active': true,
        'ready': false,
      });
      final Map<String, Object?> json = ctlVideoPlayerStatusJson(
        const VideoPlaybackSnapshot(
          title: 'T',
          bookUid: 'b',
          positionMs: 1,
          durationMs: 2,
          playing: false,
          speed: 1.5,
          cue: null,
          volume: 40,
          audioTrackId: '3',
          subtitleSource: 'embedded:0',
          secondarySubtitleSource: 'off:',
        ),
      );
      expect(json['volume'], 40);
      expect(json['audioTrack'], '3');
      expect(json['subtitle'], 'embedded:0');
      expect(json['secondarySubtitle'], 'off:');
      expect(json['speed'], 1.5);
    });

    test('暂存队列只碰视频页暂存的卡', () {
      expect(isCtlVideoMineQueueBook('abc'), isTrue);
      expect(isCtlVideoMineQueueBook('video/stream/netflix/1'), isFalse);
      expect(isCtlVideoMineQueueBook(''), isFalse);
    });
  });

  group('OCR 一次性同意的无头答案', () {
    test('Lens 上传：没同意且没给参数 → false 不写；给了参数 → 写同一份记录', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(
        await acceptGoogleLensUploadHeadless(
          scene: GoogleLensDisclosureScene.videoFrames,
          consent: false,
        ),
        isFalse,
      );
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(kVideoGoogleLensDisclosurePreferenceKey), isNull);
      expect(
        await acceptGoogleLensUploadHeadless(
          scene: GoogleLensDisclosureScene.videoFrames,
          consent: true,
        ),
        isTrue,
      );
      expect(
        prefs.getInt(kVideoGoogleLensDisclosurePreferenceKey),
        kGoogleLensDisclosureVersion,
        reason: '与 app 披露框「同意」写的是同一个键与版本号',
      );
      expect(
        prefs.getInt(kGoogleLensDisclosurePreferenceKey),
        isNull,
        reason: '视频画面的同意不顶替漫画页面的同意',
      );
      expect(
        await acceptGoogleLensUploadHeadless(
          scene: GoogleLensDisclosureScene.videoFrames,
          consent: false,
        ),
        isTrue,
        reason: '已同意过就不再要参数',
      );
    });
  });

  group('视频页长任务', () {
    test('进度 / 取消 / 结论，结束后 done 完成', () async {
      int cancelled = 0;
      final VideoRemoteJobRegistry registry = VideoRemoteJobRegistry();
      final VideoRemoteJob job = registry.register(
        VideoRemoteJob(kind: VideoRemoteJobKind.subtitleOcr, bookUid: 'b'),
      );
      expect(job.id, 'vj1');
      expect(registry['vj1'], same(job));
      expect(registry.running(VideoRemoteJobKind.subtitleOcr), same(job));
      expect(job.cancel(), isFalse, reason: '没登记取消执行体前不可取消');
      job.onCancel = () => cancelled++;
      job.update(phase: 'recognizing', fraction: 1.5, detail: '3/4');
      Map<String, Object?> json = ctlVideoJobJson(job);
      expect(json['status'], 'running');
      expect(json['progress'], 1.0);
      expect(json['detail'], '3/4');
      expect(json['cancellable'], isTrue);
      expect(job.cancel(), isTrue);
      expect(cancelled, 1);
      job.addMessage('已取消');
      job.fail('cancelled', '已取消');
      await job.done;
      json = ctlVideoJobJson(job);
      expect(json['status'], 'cancelled');
      expect(json['errorCode'], 'cancelled');
      expect(json['messages'], <String>['已取消']);
      expect(job.cancel(), isFalse, reason: '结束后不能再取消');
      job.succeed(<String, Object?>{'x': 1});
      expect(job.status, VideoRemoteJobStatus.cancelled, reason: '结论只落一次');
      expect(registry.running(VideoRemoteJobKind.subtitleOcr), isNull);

      final VideoRemoteJob clip = registry.register(
        VideoRemoteJob(kind: VideoRemoteJobKind.clip, bookUid: 'b'),
      );
      clip.succeed(<String, Object?>{'path': 'C:/c.mp4'});
      expect(ctlVideoJobJson(clip)['result'], <String, Object?>{
        'path': 'C:/c.mp4',
      });
      expect(registry.recent.first, same(clip));
    });

    test('登记表只保留最近的已结束任务，跑着的不丢', () {
      final VideoRemoteJobRegistry registry = VideoRemoteJobRegistry(
        capacity: 2,
      );
      final VideoRemoteJob running = registry.register(
        VideoRemoteJob(kind: VideoRemoteJobKind.transcribe, bookUid: 'b'),
      );
      for (int i = 0; i < 3; i++) {
        registry
            .register(
              VideoRemoteJob(kind: VideoRemoteJobKind.clip, bookUid: 'b'),
            )
            .succeed();
      }
      expect(registry[running.id], same(running));
      expect(registry.recent.length, 2);
    });
  });
}

/// 交互式批次里遇到一个歧义作品（两个候选、带 AI 倾向），按回答结束；同时支持
/// 手动按 id 取作品（`searchManualCandidates`），供「手动指定身份」作答。
class _ConfirmRunner
    implements VideoSourceScrapeRunner, VideoSourceScrapeManualBinding {
  final List<VideoSourceScrapeConfirmationCandidate> candidates =
      <VideoSourceScrapeConfirmationCandidate>[
        _candidate(VideoMetadataProviderKind.anidb, '1', 'First'),
        _candidate(VideoMetadataProviderKind.tmdb, '2', 'Second'),
      ];
  VideoSourceScrapeConfirmationCandidate? selected;
  final List<String> manualQueries = <String>[];
  final List<int?> manualSourceIds = <int?>[];

  static VideoSourceScrapeConfirmationCandidate _candidate(
    VideoMetadataProviderKind provider,
    String id,
    String title,
  ) => VideoSourceScrapeConfirmationCandidate(
    lookup: VideoMetadataLookup(
      provider: provider,
      externalId: id,
      mediaKind: VideoMetadataMediaKind.tv,
    ),
    work: VideoMetadataWork(
      provider: provider,
      kind: VideoMetadataMediaKind.tv,
      title: title,
      ids: <VideoMetadataId>[VideoMetadataId(type: provider.name, value: id)],
    ),
  );

  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  }) async {
    selected = await onConfirmation!(
      VideoSourceScrapeConfirmation(
        sourceId: source.id,
        sourceLabel: source.label,
        localWorkTitle: 'Ambiguous',
        candidates: candidates,
        aiSuggestion: const VideoSourceScrapeAiSuggestion(
          candidateIndex: 1,
          confidencePercent: 61,
          reason: 'year',
        ),
      ),
    );
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 1,
      succeededWorks: selected == null ? 0 : 1,
      pendingConfirmations: selected == null ? 1 : 0,
    );
  }

  @override
  Future<List<VideoSourceScrapeConfirmationCandidate>> searchManualCandidates({
    SourceLibraryRow? source,
    required String workTitle,
    String? workStableKey,
    required String query,
    VideoMetadataProviderKind? provider,
    VideoMetadataMediaKind? mediaKind,
  }) async {
    manualQueries.add(query);
    manualSourceIds.add(source?.id);
    final List<String> parts = query.split(':');
    return <VideoSourceScrapeConfirmationCandidate>[
      _candidate(
        VideoMetadataProviderKind.values.byName(parts.first),
        parts.last,
        'Manual $workTitle',
      ),
    ];
  }

  @override
  Future<VideoMetadataWork?> fetchWorkForLookup(VideoMetadataLookup lookup) =>
      throw UnimplementedError();

  @override
  Future<SourceScrapeReport> rescrapeWorkWithLookup({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoMetadataLookup lookup,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
  }) => throw UnimplementedError();
}
