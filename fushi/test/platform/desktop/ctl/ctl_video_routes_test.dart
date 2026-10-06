import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart'
    show VideoDiscoveryCategory;
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadSubtitlePolicy;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataMediaKind, VideoMetadataProviderKind;
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart'
    show SourceScrapeIssue, SourceScrapeReport;

import 'package:fushi/src/platform/desktop/ctl/ctl_video_routes.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_video_support.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';

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
      DesktopCtlContext(ref: _NoRef(), focusMainWindow: () async {}),
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
}
