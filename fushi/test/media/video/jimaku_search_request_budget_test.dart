import 'dart:async';
import 'dart:convert';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart';
import 'package:fushi_engine/media/video/jimaku_subtitle_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// 查字幕的请求预算与连接预热。
///
/// 背景（2026-11-23 实测 jimaku.cc）：冷连接首请求 ~0.9 s、复用连接 ~0.25 s；
/// 此前带集号搜一次要串行 1 + 2N 个请求（条目搜索 + 每条目「按集列」「全表」各
/// 一次）。现在每条目只列一次全表、本地按文件名筛集号；面板打开时预热连接。
void main() {
  Map<String, Object?> file(String name) => <String, Object?>{
    'url': 'https://jimaku.cc/entry/1855/download/$name',
    'name': name,
    'size': 100,
    'last_modified': '2024-01-02T03:04:05.000Z',
  };

  VideoSubtitleSearchRequest request({int? episode}) =>
      VideoSubtitleSearchRequest(
        media: VideoMediaReference(
          providerId: 'anilist',
          mediaId: '130298',
          mediaKind: VideoMetadataMediaKind.tv,
          discoveryCategory: VideoDiscoveryCategory.anime,
          title: 'Kage no Jitsuryokusha ni Naritakute!',
          anilistId: 130298,
        ),
        episode: episode,
        languages: const <String>['ja'],
      );

  final String entries = jsonEncode(<Object?>[
    <String, Object?>{
      'id': 1855,
      'name': 'Kage no Jitsuryokusha ni Naritakute!',
      'anilist_id': 130298,
      'flags': <String, Object?>{'anime': true},
      'last_modified': '2024-01-02T03:04:05.000Z',
    },
  ]);
  // 文件名取自真实条目 1855 的形状（单集 + 整季包）。
  final String files = jsonEncode(<Object?>[
    file('[Erai-raws] Kage no Jitsuryokusha ni Naritakute! - 15.ja.srt'),
    file('[Erai-raws] Kage no Jitsuryokusha ni Naritakute! - 16.ja.srt'),
    file('[Erai-raws] Kage no Jitsuryokusha ni Naritakute! - 16v2.ja.ass'),
    file('[Erai-raws] Kage no Jitsuryokusha ni Naritakute! - 17.ja.srt'),
    file('Kage no Jitsuryokusha ni Naritakute! (01-20).zip'),
  ]);

  test('带集号：每个条目只列一次全表，本地筛出本集 + 保留整季包', () async {
    final List<Uri> calls = <Uri>[];
    final MockClient client = MockClient((http.Request req) async {
      calls.add(req.url);
      if (req.url.path == '/api/entries/search') {
        return http.Response.bytes(utf8.encode(entries), 200);
      }
      if (req.url.path == '/api/entries/1855/files') {
        return http.Response.bytes(utf8.encode(files), 200);
      }
      return http.Response('not found', 404);
    });
    final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
      client: JimakuClient(apiKey: 'k', client: client),
    );

    final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
        .search(request(episode: 16));

    expect(result.failures, isEmpty);
    expect(
      result.items.map((VideoSubtitleCandidate c) => c.fileName).toSet(),
      <String>{
        '[Erai-raws] Kage no Jitsuryokusha ni Naritakute! - 16.ja.srt',
        '[Erai-raws] Kage no Jitsuryokusha ni Naritakute! - 16v2.ja.ass',
        'Kage no Jitsuryokusha ni Naritakute! (01-20).zip',
      },
    );
    expect(calls.map((Uri u) => u.path).toList(), <String>[
      '/api/entries/search',
      '/api/entries/1855/files',
    ], reason: '条目搜索 + 一次全表；不再带 ?episode= 多打一次');
    expect(calls.last.queryParameters, isEmpty);
  });

  test('本地一条没筛中（续作连番 / 区间命名）→ 再按集问服务端，结果以服务端为准', () async {
    // 第二季条目、文件按全系列连番命名：本地解析出 13 / 14，问第 2 集一条也对不上；
    // 服务端按 anime-relations 把 14 映射成第 2 集。
    final String absolute = jsonEncode(<Object?>[
      file('[Group] Kage no Jitsuryokusha ni Naritakute! - 13.ja.srt'),
      file('[Group] Kage no Jitsuryokusha ni Naritakute! - 14.ja.srt'),
      file('Kage no Jitsuryokusha ni Naritakute! S2 (13-24).zip'),
    ]);
    final String serverEpisode2 = jsonEncode(<Object?>[
      file('[Group] Kage no Jitsuryokusha ni Naritakute! - 14.ja.srt'),
    ]);
    final List<Uri> calls = <Uri>[];
    final MockClient client = MockClient((http.Request req) async {
      calls.add(req.url);
      if (req.url.path == '/api/entries/search') {
        return http.Response.bytes(utf8.encode(entries), 200);
      }
      final bool byEpisode = req.url.queryParameters['episode'] == '2';
      return http.Response.bytes(
        utf8.encode(byEpisode ? serverEpisode2 : absolute),
        200,
      );
    });

    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await JimakuVideoSubtitleProvider(
          client: JimakuClient(apiKey: 'k', client: client),
        ).search(request(episode: 2));

    expect(result.failures, isEmpty);
    expect(
      result.items.map((VideoSubtitleCandidate c) => c.fileName).toSet(),
      <String>{
        '[Group] Kage no Jitsuryokusha ni Naritakute! - 14.ja.srt',
        'Kage no Jitsuryokusha ni Naritakute! S2 (13-24).zip',
      },
    );
    expect(calls.map((Uri u) => u.toString()).toList(), <Object>[
      startsWith('https://jimaku.cc/api/entries/search'),
      'https://jimaku.cc/api/entries/1855/files',
      'https://jimaku.cc/api/entries/1855/files?episode=2',
    ]);
  });

  test('条目里只有压缩包：本地没筛中也不多问服务端（按集筛只会把包滤掉）', () async {
    final List<Uri> calls = <Uri>[];
    final MockClient client = MockClient((http.Request req) async {
      calls.add(req.url);
      if (req.url.path == '/api/entries/search') {
        return http.Response.bytes(utf8.encode(entries), 200);
      }
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(<Object?>[
            file('Kage no Jitsuryokusha ni Naritakute! (01-20).zip'),
          ]),
        ),
        200,
      );
    });

    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await JimakuVideoSubtitleProvider(
          client: JimakuClient(apiKey: 'k', client: client),
        ).search(request(episode: 3));

    expect(result.items, hasLength(1));
    expect(calls, hasLength(2));
  });

  test('不带集号：全表原样列出', () async {
    final MockClient client = MockClient((http.Request req) async {
      if (req.url.path == '/api/entries/search') {
        return http.Response.bytes(utf8.encode(entries), 200);
      }
      return http.Response.bytes(utf8.encode(files), 200);
    });
    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await JimakuVideoSubtitleProvider(
          client: JimakuClient(apiKey: 'k', client: client),
        ).search(request());

    expect(result.items, hasLength(5));
  });

  group('连接预热', () {
    test('HEAD 站点根、不带 key（不走 /api，不吃配额）', () async {
      final List<http.BaseRequest> calls = <http.BaseRequest>[];
      final MockClient client = MockClient((http.Request req) async {
        calls.add(req);
        return http.Response('', 200);
      });
      final VideoSubtitleRegistry registry =
          VideoSubtitleRegistry(<VideoSubtitleProvider>[
            JimakuVideoSubtitleProvider(
              client: JimakuClient(apiKey: 'secret', client: client),
            ),
          ]);

      await registry.warmUpConnections();

      expect(calls, hasLength(1));
      expect(calls.single.method, 'HEAD');
      expect(calls.single.url.toString(), 'https://jimaku.cc/');
      expect(calls.single.headers.containsKey('Authorization'), isFalse);
    });

    test('预热还在握手时，正式请求等它完成再发（复用同一条连接）', () async {
      final Completer<void> handshake = Completer<void>();
      final List<String> order = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        if (req.method == 'HEAD') {
          order.add('head-start');
          await handshake.future;
          order.add('head-done');
          return http.Response('', 200);
        }
        order.add('get ${req.url.path}');
        return http.Response.bytes(utf8.encode(entries), 200);
      });
      final JimakuClient jimaku = JimakuClient(apiKey: 'k', client: client);

      final Future<void> warm = jimaku.warmUpConnection();
      final Future<List<JimakuEntry>> search = jimaku.searchByAnilistId(130298);
      await Future<void>.delayed(Duration.zero);
      expect(order, <String>['head-start'], reason: '握手没完，正式请求不能另开连接');

      handshake.complete();
      await warm;
      expect(await search, hasLength(1));
      expect(order, <String>[
        'head-start',
        'head-done',
        'get /api/entries/search',
      ]);
    });

    test('上一次预热结束后可以再预热（在途标记按完成清空）', () async {
      int heads = 0;
      final MockClient client = MockClient((http.Request req) async {
        if (req.method == 'HEAD') heads++;
        return http.Response('', 200);
      });
      final JimakuClient jimaku = JimakuClient(apiKey: 'k', client: client);

      final Future<void> first = jimaku.warmUpConnection();
      expect(
        identical(jimaku.warmUpConnection(), first),
        isTrue,
        reason: '在途时合并成一次',
      );
      await first;
      await Future<void>.delayed(Duration.zero);
      await jimaku.warmUpConnection();
      expect(heads, 2);
    });

    test('预热失败只留诊断，不影响之后的正式请求', () async {
      final MockClient client = MockClient((http.Request req) async {
        if (req.method == 'HEAD') throw http.ClientException('offline');
        return http.Response.bytes(utf8.encode(entries), 200);
      });
      final JimakuClient jimaku = JimakuClient(apiKey: 'k', client: client);

      await jimaku.warmUpConnection();
      expect(await jimaku.searchByAnilistId(130298), hasLength(1));
    });
  });
}
