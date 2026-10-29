// 首页「继续」服务器条目的进程级取数状态：刷新节流、门控签名作废、强制刷新、
// 浏览器（HTTP 连接）按配置复用与关闭；以及「接下来看」的排序时刻。
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/utils/misc/dashboard_server_continue.dart';
import 'package:fushi/src/utils/misc/dashboard_server_continue_feed.dart';
import 'package:http/http.dart' as http;

import '../pages/media_server/fake_media_server_browser.dart';

class _TrackingClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();

  @override
  void close() => closed = true;
}

class _FakeConfig implements MediaServerConfig {
  _FakeConfig(this.sourceId, {this.token = 't'});

  @override
  final String sourceId;
  final String token;
  final List<http.Client?> builtWith = <http.Client?>[];

  @override
  MediaServerKind get kind => MediaServerKind.jellyfin;
  @override
  String get accountName => 'u';
  @override
  List<String> get routeUrls => const <String>['http://x'];
  @override
  String get effectiveServerUrl => 'http://x';
  @override
  MediaServerConfig withActiveRoute(String url) => this;
  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'id': sourceId,
    'token': token,
  };
  @override
  MediaServerBrowser buildBrowser({http.Client? httpClient}) {
    builtWith.add(httpClient);
    return FakeMediaServerBrowser(serverId: sourceId);
  }
}

ServerContinueCandidate _c(String id) => ServerContinueCandidate(
  source: ServerContinueSource.mediaServer,
  serverId: 's',
  serverName: 'S',
  itemId: id,
  title: id,
  recentMs: 1,
  open: (BuildContext _) async {},
);

void main() {
  group('ServerContinueFeed.load', () {
    int now = 0;
    late ServerContinueFeed feed;
    late int fetches;
    Future<List<ServerContinueCandidate>> fetch() async {
      fetches++;
      return <ServerContinueCandidate>[_c('$fetches')];
    }

    setUp(() {
      now = 1000;
      fetches = 0;
      feed = ServerContinueFeed(
        ttl: const Duration(seconds: 90),
        nowMs: () => now,
      );
    });

    test(
      'within the TTL the cached result is reused without a request',
      () async {
        await feed.load(gate: 'g', fetch: fetch);
        now += 30 * 1000;
        final List<ServerContinueCandidate> again = await feed.load(
          gate: 'g',
          fetch: fetch,
        );
        expect(fetches, 1);
        expect(again.single.itemId, '1');
        now += 61 * 1000;
        await feed.load(gate: 'g', fetch: fetch);
        expect(fetches, 2, reason: 'stale after the TTL');
      },
    );

    test('force and a changed gate both bypass the throttle', () async {
      await feed.load(gate: 'g', fetch: fetch);
      await feed.load(gate: 'g', fetch: fetch, force: true);
      expect(fetches, 2);
      await feed.load(gate: 'other', fetch: fetch);
      expect(fetches, 3);
      expect(feed.current.single.itemId, '3');
    });

    test(
      'concurrent calls are serialised: the second reuses the first',
      () async {
        final Future<List<ServerContinueCandidate>> a = feed.load(
          gate: 'g',
          fetch: fetch,
        );
        final Future<List<ServerContinueCandidate>> b = feed.load(
          gate: 'g',
          fetch: fetch,
        );
        await Future.wait(<Future<Object?>>[a, b]);
        expect(fetches, 1);
      },
    );

    test('a failed fetch does not poison later loads', () async {
      await expectLater(
        feed.load(gate: 'g', fetch: () async => throw StateError('x')),
        throwsStateError,
      );
      await feed.load(gate: 'g', fetch: fetch);
      expect(fetches, 1);
    });
  });

  group('ServerContinueFeed browsers', () {
    test('one browser + client per config; dropped configs are closed', () {
      final List<_TrackingClient> clients = <_TrackingClient>[];
      final ServerContinueFeed feed = ServerContinueFeed(
        httpClientFactory: () {
          final _TrackingClient c = _TrackingClient();
          clients.add(c);
          return c;
        },
      );
      final _FakeConfig a = _FakeConfig('a');
      final _FakeConfig b = _FakeConfig('b');
      final MediaServerBrowser a1 = feed.browserFor(a);
      final MediaServerBrowser a2 = feed.browserFor(a);
      feed.browserFor(b);
      expect(identical(a1, a2), isTrue);
      expect(clients, hasLength(2));
      expect(a.builtWith.single, same(clients[0]));

      // b 登出、a 换了令牌：两者旧连接都关掉，a 的新配置另建。
      final _FakeConfig a2cfg = _FakeConfig('a', token: 'new');
      feed.retainBrowsers(<MediaServerConfig>[a2cfg]);
      expect(clients.every((_TrackingClient c) => c.closed), isTrue);
      expect(feed.browserCount, 0);
      feed.browserFor(a2cfg);
      expect(feed.browserCount, 1);
      feed.retainBrowsers(const <MediaServerConfig>[]);
      expect(clients.last.closed, isTrue);
    });
  });

  group('nextUpSeriesRecency', () {
    MediaServerItem ep(
      String id, {
      String? series,
      String? season,
      int played = 0,
    }) => MediaServerItem(
      id: id,
      name: id,
      type: MediaServerItemType.episode,
      seriesId: series,
      seasonId: season,
      lastPlayedAtMs: played,
    );

    test(
      'uses resume items of the same series, then the season episodes',
      () async {
        final FakeMediaServerBrowser browser = FakeMediaServerBrowser();
        browser.episodes['s2|s2-season1'] = <MediaServerItem>[
          ep('s2e1', series: 's2', played: 700),
          ep('s2e2', series: 's2', played: 900),
          ep('s2e3', series: 's2'),
        ];
        final Map<String, int> recency = await nextUpSeriesRecency(
          browser: browser,
          resume: <MediaServerItem>[ep('s1e4', series: 's1', played: 500)],
          nextUp: <MediaServerItem>[
            ep('s1e5', series: 's1', season: 's1-season1'),
            ep('s2e3', series: 's2', season: 's2-season1'),
            ep('s3e1', series: 's3', season: 's3-season1'),
          ],
        );
        expect(recency, <String, int>{'s1': 500, 's2': 900});
        // s1 已由 Resume 得知，不再为它发请求；s3 问了但没有播放记录。
        expect(
          browser.requests.map((FakePageRequest r) => r.parentId).toList(),
          <String?>['s2', 's3'],
        );

        final List<ServerContinueCandidate> out = mediaServerContinueCandidates(
          serverId: 'srv',
          serverName: 'S',
          resume: const <MediaServerItem>[],
          nextUp: <MediaServerItem>[
            ep('s2e3', series: 's2', season: 's2-season1'),
            ep('s3e1', series: 's3', season: 's3-season1'),
          ],
          seriesRecentMs: recency,
          coverUrlOf: (MediaServerItem _) => null,
          open: (BuildContext _, MediaServerItem _) async {},
        );
        expect(
          out.map((ServerContinueCandidate c) => c.recentMs).toList(),
          <int>[900, 0],
        );
      },
    );

    test('a failing episode list only drops that series', () async {
      final FakeMediaServerBrowser browser = FakeMediaServerBrowser()
        ..failEpisodes = true;
      final Map<String, int> recency = await nextUpSeriesRecency(
        browser: browser,
        resume: const <MediaServerItem>[],
        nextUp: <MediaServerItem>[ep('x', series: 'sx', season: 'q')],
      );
      expect(recency, isEmpty);
    });
  });
}
