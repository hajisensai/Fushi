import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/public_trackers.dart';
import 'package:fushi/src/media/torrent/public_video_index_client.dart';
import 'package:fushi/src/media/torrent/public_video_index_provider.dart';
import 'package:fushi/src/media/torrent/search_query_script.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';

const String _hashA = 'aabbccddeeff00112233445566778899aabbccdd';
const String _hashB = '00112233445566778899aabbccddeeff00112233';

VideoResourceSearchRequest _request({
  VideoDiscoveryCategory? category,
  int limit = 50,
}) => VideoResourceSearchRequest(
  query: 'Inception',
  media: category == null
      ? null
      : VideoMediaReference(
          providerId: 'tmdb',
          mediaId: '27205',
          mediaKind: VideoMetadataMediaKind.movie,
          discoveryCategory: category,
          title: 'Inception',
        ),
  limit: limit,
);

void main() {
  group('normalizePublicVideoIndexInfoHash', () {
    test('accepts v1 (40) and v2 (64) hex, case-insensitively', () {
      expect(normalizePublicVideoIndexInfoHash(_hashA.toUpperCase()), _hashA);
      expect(normalizePublicVideoIndexInfoHash('a' * 64), 'a' * 64);
    });

    test('rejects anything that is not a torrent hash', () {
      // identityKey 就是 infoHash：放进一个歪 hash 不报错，只会让同一个种子在两家
      // 源里各算一条。所以「拒绝」是这层唯一有意义的行为。
      expect(normalizePublicVideoIndexInfoHash(''), '');
      expect(normalizePublicVideoIndexInfoHash('a' * 39), '');
      expect(normalizePublicVideoIndexInfoHash('a' * 41), '');
      expect(normalizePublicVideoIndexInfoHash('z' * 40), '');
    });
  });

  test('buildPublicVideoIndexMagnet carries the shared public trackers', () {
    final String magnet = buildPublicVideoIndexMagnet(
      infoHash: _hashA,
      displayName: 'Some Show S01E01',
    );
    expect(magnet, startsWith('magnet:?xt=urn:btih:$_hashA'));
    expect(magnet, contains('dn=Some+Show+S01E01'));
    for (final String tracker in kPublicTrackers) {
      expect(magnet, contains(Uri.encodeQueryComponent(tracker)));
    }
    expect('&tr='.allMatches(magnet), hasLength(kPublicTrackers.length));
  });

  test('kPublicTrackers 每条都是合法 announce URL 且互不重复', () {
    // 打错一个字符的 tracker 不会报错，只会安静地永远连不上；重复一条则让每个
    // 种子对同一个 host 多打一轮 announce。两种都要等用户抱怨才可能被发现。
    //
    // 形状判据走原始字符串正则，不用 `Uri.hasPort`：后者问的是「端口是否非本
    // 协议默认值」，`https://host:443/announce` 明明写了端口也返回 false。
    final RegExp announceUrl = RegExp(
      r'^(?:udp|https?)://[A-Za-z0-9.-]+:\d{1,5}/announce$',
    );
    expect(kPublicTrackers.toSet(), hasLength(kPublicTrackers.length));
    for (final String tracker in kPublicTrackers) {
      expect(
        announceUrl.hasMatch(tracker),
        isTrue,
        reason: '不是 <scheme>://<host>:<port>/announce 形状：$tracker',
      );
    }
  });

  group('ApibayClient', () {
    test('drops the sentinel no-results row', () async {
      final ApibayClient client = ApibayClient(
        client: MockClient(
          (http.Request request) async => http.Response(
            jsonEncode(<Map<String, Object?>>[
              <String, Object?>{
                'id': '0',
                'name': 'No results returned',
                'info_hash': '0' * 40,
              },
            ]),
            200,
          ),
        ),
      );
      expect(await client.search('nothing', categories: <int>[207]), isEmpty);
    });

    test('deduplicates across the per-category requests', () async {
      final List<Uri> calls = <Uri>[];
      final ApibayClient client = ApibayClient(
        client: MockClient((http.Request request) async {
          calls.add(request.url);
          return http.Response(
            jsonEncode(<Map<String, Object?>>[
              <String, Object?>{
                'id': '42',
                'name': 'Inception 2010 1080p BluRay',
                'info_hash': _hashA.toUpperCase(),
                'seeders': '120',
                'leechers': '4',
                'size': '8589934592',
                'added': '1700000000',
              },
            ]),
            200,
          );
        }),
      );
      final List<PublicVideoIndexTorrent> results = await client.search(
        'inception',
        categories: kApibayMovieCategories,
      );
      // 两个分类各打一次，同一个种子只留一条。
      expect(calls, hasLength(kApibayMovieCategories.length));
      expect(results, hasLength(1));
      expect(results.single.infoHash, _hashA);
      expect(results.single.resolution, '1080p');
      expect(results.single.magnet, contains('urn:btih:$_hashA'));
      expect(results.single.sizeBytes, 8589934592);
      expect(
        results.single.publishedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000, isUtc: true),
      );
    });

    test('throws on a non-200 instead of reporting an empty result', () async {
      final ApibayClient client = ApibayClient(
        client: MockClient(
          (http.Request request) async => http.Response('nope', 503),
        ),
      );
      await expectLater(
        client.search('inception', categories: <int>[207]),
        throwsA(isA<http.ClientException>()),
      );
    });
  });

  group('KnabenClient', () {
    test('parses hits and keeps the server-provided magnet', () async {
      late Map<String, Object?> body;
      final KnabenClient client = KnabenClient(
        client: MockClient((http.Request request) async {
          body = jsonDecode(request.body) as Map<String, Object?>;
          return http.Response(
            jsonEncode(<String, Object?>{
              'hits': <Map<String, Object?>>[
                <String, Object?>{
                  'title': 'Inception 2010 2160p WEB-DL',
                  'hash': _hashB,
                  'magnetUrl':
                      'magnet:?xt=urn:btih:$_hashB&tr=udp://x:80/announce',
                  'seeders': 9,
                  'peers': 1,
                  'bytes': 1234,
                  'grabs': 7,
                  'date': '2024-01-02T03:04:05Z',
                  'details': 'https://knaben.org/x',
                },
                <String, Object?>{'title': 'broken', 'hash': 'zz'},
              ],
            }),
            200,
          );
        }),
      );
      final List<PublicVideoIndexTorrent> results = await client.search(
        'inception',
        categories: <int>[kKnabenMovieCategory],
      );
      expect(results, hasLength(1));
      expect(results.single.magnet, startsWith('magnet:?xt=urn:btih:$_hashB'));
      expect(results.single.completed, 7);
      expect(results.single.detailsUrl, 'https://knaben.org/x');
      // search_type 必须是精确匹配档；score 档会把 query 当权重提示。
      expect(body['search_type'], '100%');
      expect(body['hide_xxx'], isTrue);
      expect(body['categories'], <int>[kKnabenMovieCategory]);
    });

    test('synthesizes a magnet when the API omits magnetUrl', () async {
      final KnabenClient client = KnabenClient(
        client: MockClient(
          (http.Request request) async => http.Response(
            jsonEncode(<String, Object?>{
              'hits': <Map<String, Object?>>[
                <String, Object?>{'title': 'X', 'hash': _hashB},
              ],
            }),
            200,
          ),
        ),
      );
      final List<PublicVideoIndexTorrent> results = await client.search(
        'x',
        categories: <int>[kKnabenTvCategory],
      );
      expect(
        results.single.magnet,
        buildPublicVideoIndexMagnet(infoHash: _hashB, displayName: 'X'),
      );
    });
  });

  group('public index providers', () {
    test('BUG-1985 书写系统判据：有拉丁词或纯 ASCII 才算可表达', () {
      // 能表达：有拉丁词。混排不该被拦——apibay 对它并不退化（有拉丁词可匹配），
      // 最坏是结果少，不是结果错。旧判据「含一个汉字就整条拦」把这些全误杀了。
      for (final String q in <String>[
        'Fate/stay night 劇場版',
        'Kimetsu no Yaiba 鬼滅',
        'Silo',
        'Re:Zero',
      ]) {
        expect(isLatinScriptExpressible(q), isTrue, reason: '$q 有拉丁词，能表达');
      }
      // 能表达：整条纯 ASCII。按「有没有拉丁词」单条判会把这类合法标题误杀。
      for (final String q in <String>['2012', '300', '9']) {
        expect(isLatinScriptExpressible(q), isTrue, reason: '$q 是纯 ASCII 标题');
      }
      // 不能表达：没有拉丁词、也不是纯 ASCII。
      for (final String q in <String>[
        '薬屋のひとりごと 第2期', // 注意含 ASCII '2'——旧的「有字母数字」判据放它过去了
        'ﾎﾟｹﾓﾝ', // 半角片假名：旧的 CJK 区段枚举漏掉了它
        '오징어 게임', // 韩文
        'Ведьмак', // 西里尔：旧判据把它当「非拉丁 = 不可搜」，方向对但理由错
        'ตำนานสมเด็จพระนเรศวร', // 泰文
      ]) {
        expect(isLatinScriptExpressible(q), isFalse, reason: '$q 没有拉丁词可匹配');
      }
      expect(isLatinScriptExpressible('   '), isFalse);
    });

    test('BUG-1985 混排查询原样透传，不因含一个汉字就整条拦（走 provider 判据）', () {
      // 这条必须打 publicVideoIndexSearchQuery，不能只测共享原语——否则判据换了
      // 而 provider 没跟着换，测试照样绿（变异实测抓到过这一次空转）。
      for (final String q in <String>[
        'Fate/stay night 劇場版',
        'Kimetsu no Yaiba 鬼滅',
        '2012',
      ]) {
        expect(
          publicVideoIndexSearchQuery(
            VideoResourceSearchRequest(query: q),
          ),
          q,
          reason: '$q 有拉丁词可匹配，apibay 对它并不退化；'
              '含一个汉字就整条拦是过度拦截，实现范围大于实测证据范围',
        );
      }
      // 反向：没有拉丁词、也不是纯 ASCII，且拿不到媒体身份 → 表达不了。
      for (final String q in <String>['薬屋のひとりごと 第2期', 'ﾎﾟｹﾓﾝ', '오징어 게임']) {
        expect(
          publicVideoIndexSearchQuery(
            VideoResourceSearchRequest(query: q),
          ),
          isNull,
          reason: '$q 没有拉丁词，送进去只会拿回热门榜',
        );
      }
    });

    test('BUG-1985 全角 ASCII 折半角：第２期 与 第2期 必须归一', () {
      expect(foldFullWidthAscii('第２期'), '第2期');
      expect(foldFullWidthAscii('ＦＡＴＥ'), 'FATE');
      expect(foldFullWidthAscii('a　b'), 'a b');
      // 不折就会让「这条查询等于媒体自己的标题吗」因为用户从别处粘来全角数字而失配。
      final VideoResourceSearchRequest request = VideoResourceSearchRequest(
        query: '薬屋のひとりごと 第２期',
        media: VideoMediaReference(
          providerId: 'tmdb',
          mediaId: '209867',
          mediaKind: VideoMetadataMediaKind.tv,
          discoveryCategory: VideoDiscoveryCategory.tv,
          title: '药屋少女的呢喃 第2季',
          originalTitle: '薬屋のひとりごと 第2期',
          aliases: const <String>['Kusuriya no Hitorigoto Season 2'],
        ),
      );
      expect(publicVideoIndexSearchQuery(request),
          'Kusuriya no Hitorigoto Season 2',
          reason: '全角数字不折，isKnownTitle 就失配，别名降级白做');
    });

    test('BUG-1985 CJK 标题命中媒体身份时改用可信拉丁别名', () {
      final VideoResourceSearchRequest request = VideoResourceSearchRequest(
        query: '薬屋のひとりごと 第2期',
        media: VideoMediaReference(
          providerId: 'tmdb',
          mediaId: '209867',
          mediaKind: VideoMetadataMediaKind.tv,
          discoveryCategory: VideoDiscoveryCategory.tv,
          title: '药屋少女的呢喃 第2季',
          originalTitle: '薬屋のひとりごと 第2期',
          aliases: const <String>[
            'Kusuriya no Hitorigoto Season 2',
            'The Apothecary Diaries Season 2',
          ],
        ),
      );

      expect(
        publicVideoIndexSearchQuery(request),
        'Kusuriya no Hitorigoto Season 2',
      );
    });

    test('BUG-1985 apibay 传输层收到拉丁别名而不是原始 CJK', () async {
      final List<String> queries = <String>[];
      final ApibayVideoResourceProvider provider = ApibayVideoResourceProvider(
        client: ApibayClient(
          client: MockClient((http.Request request) async {
            queries.add(request.url.queryParameters['q']!);
            return http.Response('[]', 200);
          }),
        ),
      );
      final ProviderBatchResult<VideoResourceCandidate> result = await provider
          .search(
            VideoResourceSearchRequest(
              query: '薬屋のひとりごと 第2期',
              media: VideoMediaReference(
                providerId: 'tmdb',
                mediaId: '209867',
                mediaKind: VideoMetadataMediaKind.tv,
                discoveryCategory: VideoDiscoveryCategory.tv,
                title: '药屋少女的呢喃 第2季',
                originalTitle: '薬屋のひとりごと 第2期',
                aliases: const <String>['Kusuriya no Hitorigoto Season 2'],
              ),
            ),
          );

      expect(
        queries,
        List<String>.filled(
          kApibayTvCategories.length,
          'Kusuriya no Hitorigoto Season 2',
        ),
      );
      expect(result.failures, isEmpty);
      expect(result.successfulProviderCount, 1);
    });

    test('BUG-1985 手输的无别名 CJK 查询不发送给公共索引器', () async {
      int calls = 0;
      final ApibayVideoResourceProvider provider = ApibayVideoResourceProvider(
        client: ApibayClient(
          client: MockClient((http.Request request) async {
            calls++;
            return http.Response('[]', 200);
          }),
        ),
      );
      final ProviderBatchResult<VideoResourceCandidate> result = await provider
          .search(
            VideoResourceSearchRequest(
              query: '薬屋のひとりごと 第2期',
              media: VideoMediaReference(
                providerId: 'tmdb',
                mediaId: '194766',
                mediaKind: VideoMetadataMediaKind.tv,
                discoveryCategory: VideoDiscoveryCategory.tv,
                title: 'Silo',
                aliases: const <String>['Silo'],
              ),
            ),
          );

      expect(calls, 0, reason: 'apibay 会把 CJK 当空查询返回热门榜，必须在传输前拦住');
      expect(result.items, isEmpty);
      // 「表达不了」是未参与，不是失败。表达成 failure 会让订阅 / 下载流水线
      // 每一轮定时任务都 throw（那两条路径重建 media 时结构上拿不到别名），
      // 也会让 UI 弹「加载失败 + 重试」——而重试永远不可能成功。
      expect(result.failures, isEmpty,
          reason: 'unsupported 不得表达成 provider failure');
      expect(result.successfulProviderCount, 0);
      expect(result.hasNoActiveProvider, isTrue,
          reason: '要落进既有的第三态，让聚合层与 UI 拿到「这家没参与」而不是「炸了」');
      expect(result.isTotalFailure, isFalse);
    });

    test('BUG-1985 Knaben 不走拉丁词门：它是硬标题过滤，CJK 返回的是真的 0 条', () async {
      final List<String> queries = <String>[];
      final KnabenVideoResourceProvider provider = KnabenVideoResourceProvider(
        client: KnabenClient(
          client: MockClient((http.Request request) async {
            queries.add(
              (jsonDecode(request.body) as Map<String, Object?>)['query']!
                  as String,
            );
            return http.Response('{"hits":[]}', 200);
          }),
        ),
      );
      final ProviderBatchResult<VideoResourceCandidate> result = await provider
          .search(
            VideoResourceSearchRequest(
              query: '薬屋のひとりごと 第2期',
              media: VideoMediaReference(
                providerId: 'tmdb',
                mediaId: '194766',
                mediaKind: VideoMetadataMediaKind.tv,
                discoveryCategory: VideoDiscoveryCategory.tv,
                title: 'Silo',
                aliases: const <String>['Silo'],
              ),
            ),
          );

      expect(queries, <String>['薬屋のひとりごと 第2期'],
          reason: 'Knaben 的 search_type:100% 是硬标题过滤，对 CJK 返回正确的 0 条；'
              '把它一起拦掉是纯功能删除，删的正是它相对 apibay 的价值');
      expect(result.failures, isEmpty);
    });

    test('apibay only serves movie and tv, never anime', () {
      final ApibayVideoResourceProvider provider = ApibayVideoResourceProvider(
        client: ApibayClient(),
      );
      expect(provider.categories, <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.movie,
        VideoDiscoveryCategory.tv,
      });
      expect(
        provider.categories.contains(VideoDiscoveryCategory.anime),
        isFalse,
      );
      provider.close();
    });

    test('knaben only serves movie and tv, never anime', () {
      final KnabenVideoResourceProvider provider = KnabenVideoResourceProvider(
        client: KnabenClient(),
      );
      expect(provider.categories, <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.movie,
        VideoDiscoveryCategory.tv,
      });
      expect(
        provider.categories.contains(VideoDiscoveryCategory.anime),
        isFalse,
      );
      provider.close();
    });

    test('a tv request uses the tv categories', () async {
      late Uri seen;
      final ApibayVideoResourceProvider provider = ApibayVideoResourceProvider(
        client: ApibayClient(
          client: MockClient((http.Request request) async {
            seen = request.url;
            return http.Response('[]', 200);
          }),
        ),
      );
      await provider.search(_request(category: VideoDiscoveryCategory.tv));
      expect(seen.queryParameters['cat'], kApibayTvCategories.last.toString());
    });

    test(
      'a transport failure becomes a failure, not an empty result',
      () async {
        final ApibayVideoResourceProvider provider =
            ApibayVideoResourceProvider(
              client: ApibayClient(
                client: MockClient(
                  (http.Request request) async => http.Response('boom', 500),
                ),
              ),
            );
        final ProviderBatchResult<VideoResourceCandidate> result =
            await provider.search(
              _request(category: VideoDiscoveryCategory.movie),
            );
        expect(result.failures, hasLength(1));
        expect(result.successfulProviderCount, 0);
        // 「零来源」与「来源答了但没有匹配」必须可区分（PR#896 的空态判据）。
        expect(result.hasNoActiveProvider, isFalse);
      },
    );

    test('resolve hands out the magnet and refuses foreign candidates', () {
      final PublicVideoIndexCandidate mine = PublicVideoIndexCandidate(
        torrent: PublicVideoIndexTorrent(
          title: 'X',
          infoHash: _hashA,
          magnet: buildPublicVideoIndexMagnet(
            infoHash: _hashA,
            displayName: 'X',
          ),
          seeders: 1,
          leechers: 0,
          sizeBytes: 1,
        ),
        providerId: kApibayResourceProviderId,
        providerInstanceId: 'apibay.org',
        providerPriority: 200,
      );
      final TorrentAddPayload payload = resolvePublicVideoIndexCandidate(
        mine,
        kApibayResourceProviderId,
      );
      expect(payload, isA<TorrentMagnetPayload>());
      expect((payload as TorrentMagnetPayload).torrentId, _hashA);
      expect(
        () => resolvePublicVideoIndexCandidate(mine, kKnabenResourceProviderId),
        throwsA(isA<ExternalProviderFailure>()),
      );
    });
  });
}
