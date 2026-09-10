import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/jimaku_subtitle_provider.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/sync/remote_subtitle_search_handlers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 浏览器扩展「查字幕」桥（`/api/subtitle/search` + `/fetch` 的共享 handler）契约：
/// - 来源清单只有一个真相源（[VideoSubtitleRegistry]）：扩展与 app 内「找字幕」看到
///   同一批来源，不再是「扩展只有 Jimaku」；
/// - 部分来源挂了不吞：另一些答出来的照样出结果，挂了的进 `failures`；
/// - fetch 响应与 /api/subtitle/parse 同形（format+cues），扩展 InstallTrack 零改动；
/// - 旧端点 `/api/subtitle/jimaku/*`（滞留旧版扩展仍在打）限定 Jimaku 一家，handle
///   串与错误码逐字不变。
void main() {
  // 解码走 [decodeTextBytes]，它会试一次平台字符集检测插件（桌面无实现 →
  // MissingPluginException → 降级）。没有 binding 时那次 invokeMethod 抛的是
  // 「Binding has not yet been initialized」，会被桥的 catch 吞成 download-failed。
  TestWidgetsFlutterBinding.ensureInitialized();

  const String srt = '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n';

  MockClient jimakuMock({
    required Map<String, List<Map<String, dynamic>>> entriesByAnimeParam,
    List<Map<String, dynamic>> files = const <Map<String, dynamic>>[],
    List<Uri>? seenUris,
  }) {
    return MockClient((http.Request request) async {
      seenUris?.add(request.url);
      final String path = request.url.path;
      if (path.endsWith('/entries/search')) {
        final String animeParam = request.url.queryParameters['anime'] ?? '';
        return http.Response(
          jsonEncode(entriesByAnimeParam[animeParam] ?? <Object>[]),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      if (path.contains('/entries/') && path.endsWith('/files')) {
        return http.Response(
          jsonEncode(files),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      if (path.endsWith('/download.srt')) {
        return http.Response.bytes(utf8.encode(srt), 200);
      }
      return http.Response('not found', 404);
    });
  }

  JimakuVideoSubtitleProvider jimakuProvider({
    required Map<String, List<Map<String, dynamic>>> entriesByAnimeParam,
    List<Map<String, dynamic>> files = const <Map<String, dynamic>>[],
    List<Uri>? seenUris,
  }) {
    return JimakuVideoSubtitleProvider(
      client: JimakuClient(
        apiKey: 'k',
        client: jimakuMock(
          entriesByAnimeParam: entriesByAnimeParam,
          files: files,
          seenUris: seenUris,
        ),
      ),
    );
  }

  const List<Map<String, dynamic>> jimakuFiles = <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'ep01.ja.srt',
      'url': 'https://jimaku.cc/dl/download.srt',
      'size': 100,
    },
  ];

  Future<VideoSubtitleRegistry?> Function() registryOf(
    List<VideoSubtitleProvider> providers,
  ) =>
      () async => providers.isEmpty ? null : VideoSubtitleRegistry(providers);

  group('buildRemoteSubtitleSearchResponse', () {
    test('一个来源都没配 → no-provider（旧 jimaku 端点仍回 no-api-key）', () async {
      final Map<String, dynamic> generic =
          await buildRemoteSubtitleSearchResponse(
        <String, dynamic>{'query': 'x'},
        registryProvider: registryOf(<VideoSubtitleProvider>[]),
        rememberCandidate: (_, __) => fail('不应记录候选'),
      );
      expect(generic['ok'], isFalse);
      expect(generic['error'], 'no-provider');

      // 旧端点的错误码是扩展文案的分支键，不能因为改了实现就换掉。
      final Map<String, dynamic> legacy =
          await buildRemoteSubtitleSearchResponse(
        <String, dynamic>{'query': 'x'},
        registryProvider: registryOf(<VideoSubtitleProvider>[
          _FakeProvider(id: 'ajatt'),
        ]),
        rememberCandidate: (_, __) => fail('不应记录候选'),
        restrictToProviderIds: kJimakuOnlyProviderIds,
      );
      expect(legacy['error'], 'no-api-key');
    });

    test('query 与 anilistId 都缺 → missing-query', () async {
      final Map<String, dynamic> res = await buildRemoteSubtitleSearchResponse(
        <String, dynamic>{},
        registryProvider: registryOf(<VideoSubtitleProvider>[
          _FakeProvider(id: 'ajatt'),
        ]),
        rememberCandidate: (_, __) {},
      );
      expect(res['error'], 'missing-query');
    });

    test('多来源扇出：每条候选带 provider，按 provider 优先级排序', () async {
      final _FakeProvider ajatt = _FakeProvider(
        id: 'ajatt',
        priority: 150,
        items: <VideoSubtitleCandidate>[
          _FakeCandidate(
            providerId: 'ajatt',
            remoteId: 'anime_tv/k-on!.html:ep01.srt',
            fileName: 'ep01.srt',
            language: 'ja',
            providerPriority: 150,
            collectionLabel: 'K-ON!',
          ),
        ],
      );
      final _FakeProvider openSubtitles = _FakeProvider(
        id: 'opensubtitles',
        priority: 120,
        items: <VideoSubtitleCandidate>[
          _FakeCandidate(
            providerId: 'opensubtitles',
            remoteId: '99',
            fileName: 'K-ON.S01E01.srt',
            language: 'en',
            providerPriority: 120,
            releaseName: 'K-ON! WEB-DL',
            aiTranslated: true,
          ),
        ],
      );
      final Map<String, VideoSubtitleCandidate> remembered =
          <String, VideoSubtitleCandidate>{};
      final Map<String, dynamic> res = await buildRemoteSubtitleSearchResponse(
        <String, dynamic>{'query': 'K-ON!', 'episode': 1},
        registryProvider:
            registryOf(<VideoSubtitleProvider>[ajatt, openSubtitles]),
        rememberCandidate: (String handle, VideoSubtitleCandidate c) =>
            remembered[handle] = c,
      );
      expect(res['ok'], isTrue);
      final List<dynamic> candidates = res['candidates'] as List<dynamic>;
      expect(candidates, hasLength(2));
      expect(
        candidates
            .map((dynamic c) => (c as Map<String, dynamic>)['provider'])
            .toList(),
        <String>['opensubtitles', 'ajatt'],
        reason: 'priority 小的先出（registry 的排序，不该在桥里再排一遍）',
      );
      final Map<String, dynamic> first =
          candidates.first as Map<String, dynamic>;
      expect(first['handle'], 'opensubtitles:99');
      expect(first['entryName'], 'K-ON! WEB-DL');
      expect(first['aiTranslated'], isTrue, reason: '机翻档必须能在扩展里标出来');
      expect(remembered.keys, containsAll(<String>['opensubtitles:99']));
      // 两家都拿到了同一份请求（集数透传）。
      expect(ajatt.searches.single.effectiveEpisode, 1);
      expect(openSubtitles.searches.single.effectiveEpisode, 1);
    });

    test('一家挂了、另一家答了 → 照常出结果，挂的那家进 failures', () async {
      final Map<String, dynamic> res = await buildRemoteSubtitleSearchResponse(
        <String, dynamic>{'query': 'x'},
        registryProvider: registryOf(<VideoSubtitleProvider>[
          _FakeProvider(
            id: 'ajatt',
            items: <VideoSubtitleCandidate>[
              _FakeCandidate(
                providerId: 'ajatt',
                remoteId: 'a:ep01.srt',
                fileName: 'ep01.srt',
                language: 'ja',
                providerPriority: 150,
              ),
            ],
          ),
          _FakeProvider(
            id: 'opensubtitles',
            failure: const ExternalProviderFailure(
              providerId: 'opensubtitles',
              operation: 'search',
              kind: ExternalProviderFailureKind.rateLimited,
              message: 'rate limited',
              statusCode: 429,
            ),
          ),
        ]),
        rememberCandidate: (_, __) {},
      );
      expect(res['ok'], isTrue);
      expect(res['candidates'], hasLength(1));
      final List<dynamic> failures = res['failures'] as List<dynamic>;
      expect(failures, hasLength(1));
      final Map<String, dynamic> failure =
          failures.first as Map<String, dynamic>;
      expect(failure['provider'], 'opensubtitles');
      expect(failure['error'], 'rate-limited');
      expect(failure['status'], 429);
    });

    test('全灭时报「用户能动手修」的那条：鉴权优先于泛泛的不可用', () async {
      final Map<String, dynamic> res = await buildRemoteSubtitleSearchResponse(
        <String, dynamic>{'query': 'x'},
        registryProvider: registryOf(<VideoSubtitleProvider>[
          _FakeProvider(
            id: 'ajatt',
            failure: const ExternalProviderFailure(
              providerId: 'ajatt',
              operation: 'search',
              kind: ExternalProviderFailureKind.unavailable,
              message: 'site down',
            ),
          ),
          _FakeProvider(
            id: 'jimaku',
            failure: const ExternalProviderFailure(
              providerId: 'jimaku',
              operation: 'search',
              kind: ExternalProviderFailureKind.unauthorized,
              message: 'bad key',
              statusCode: 401,
            ),
          ),
        ]),
        rememberCandidate: (_, __) {},
      );
      expect(res['ok'], isFalse);
      expect(res['error'], 'unauthorized');
      expect(res['status'], 401);
      expect(res['failures'], hasLength(2));
    });

    test('候选超上限 → 截断并标 truncated', () async {
      final Map<String, dynamic> res = await buildRemoteSubtitleSearchResponse(
        <String, dynamic>{'query': 'x'},
        registryProvider: registryOf(<VideoSubtitleProvider>[
          _FakeProvider(
            id: 'ajatt',
            items: <VideoSubtitleCandidate>[
              for (int i = 0; i < kRemoteSubtitleSearchMaxCandidates + 5; i++)
                _FakeCandidate(
                  providerId: 'ajatt',
                  remoteId: 'a:ep$i.srt',
                  fileName: 'ep$i.srt',
                  language: 'ja',
                  providerPriority: 150,
                ),
            ],
          ),
        ]),
        rememberCandidate: (_, __) {},
      );
      expect(res['ok'], isTrue);
      expect(
        res['candidates'],
        hasLength(kRemoteSubtitleSearchMaxCandidates),
      );
      expect(res['truncated'], isTrue);
    });
  });

  group('旧 /api/subtitle/jimaku/* 端点（滞留旧版扩展仍在打）', () {
    test('只搜 Jimaku，别家一个请求都不发；handle 串与旧实现逐字节相同', () async {
      final _FakeProvider ajatt = _FakeProvider(
        id: 'ajatt',
        items: <VideoSubtitleCandidate>[
          _FakeCandidate(
            providerId: 'ajatt',
            remoteId: 'a:ep01.srt',
            fileName: 'ep01.srt',
            language: 'ja',
            providerPriority: 150,
          ),
        ],
      );
      final Map<String, VideoSubtitleCandidate> remembered =
          <String, VideoSubtitleCandidate>{};
      final Map<String, dynamic> res = await buildRemoteSubtitleSearchResponse(
        <String, dynamic>{'query': '日剧タイトル'},
        registryProvider: registryOf(<VideoSubtitleProvider>[
          ajatt,
          jimakuProvider(
            entriesByAnimeParam: <String, List<Map<String, dynamic>>>{
              '': <Map<String, dynamic>>[],
              'false': <Map<String, dynamic>>[
                <String, dynamic>{'id': 7, 'name': '日剧タイトル'},
              ],
            },
            files: jimakuFiles,
          ),
        ]),
        rememberCandidate: (String handle, VideoSubtitleCandidate c) =>
            remembered[handle] = c,
        restrictToProviderIds: kJimakuOnlyProviderIds,
      );
      expect(res['ok'], isTrue);
      final List<dynamic> candidates = res['candidates'] as List<dynamic>;
      expect(candidates, hasLength(1));
      final Map<String, dynamic> first =
          candidates.first as Map<String, dynamic>;
      expect(first['handle'], 'jimaku:7:ep01.ja.srt');
      expect(first['provider'], 'jimaku');
      expect(first['entryName'], '日剧タイトル');
      expect(remembered, contains('jimaku:7:ep01.ja.srt'));
      expect(ajatt.searches, isEmpty, reason: '旧端点是 Jimaku 专用，不得顺手扇出别家');
    });

    test('anime 缺省时空结果自动 anime=false 补搜（真人剧否则永远 0 结果）', () async {
      final List<Uri> seen = <Uri>[];
      await buildRemoteSubtitleSearchResponse(
        <String, dynamic>{'query': '日剧タイトル'},
        registryProvider: registryOf(<VideoSubtitleProvider>[
          jimakuProvider(
            entriesByAnimeParam: <String, List<Map<String, dynamic>>>{
              '': <Map<String, dynamic>>[],
              'false': <Map<String, dynamic>>[
                <String, dynamic>{'id': 7, 'name': '日剧タイトル'},
              ],
            },
            files: jimakuFiles,
            seenUris: seen,
          ),
        ]),
        rememberCandidate: (_, __) {},
        restrictToProviderIds: kJimakuOnlyProviderIds,
      );
      expect(
        seen.any((Uri u) => u.queryParameters['anime'] == 'false'),
        isTrue,
      );
    });

    test('body 里的 anime=false 一路透传到 Jimaku 查询参数，不再二次补搜', () async {
      final List<Uri> seen = <Uri>[];
      final Map<String, dynamic> res = await buildRemoteSubtitleSearchResponse(
        <String, dynamic>{'query': 'x', 'anime': false},
        registryProvider: registryOf(<VideoSubtitleProvider>[
          jimakuProvider(
            entriesByAnimeParam: <String, List<Map<String, dynamic>>>{
              'false': <Map<String, dynamic>>[],
            },
            seenUris: seen,
          ),
        ]),
        rememberCandidate: (_, __) {},
        restrictToProviderIds: kJimakuOnlyProviderIds,
      );
      expect(res['ok'], isTrue);
      expect(res['candidates'], isEmpty);
      final List<Uri> searches =
          seen.where((Uri u) => u.path.endsWith('/entries/search')).toList();
      expect(searches, hasLength(1), reason: '调用方已显式指定 anime，空结果不再补搜');
      expect(searches.single.queryParameters['anime'], 'false');
    });

    test('限定 Jimaku 时不给别家的 handle 放行（旧端点不得代下 OpenSubtitles 配额）', () async {
      final VideoSubtitleCandidate foreign = _FakeCandidate(
        providerId: 'opensubtitles',
        remoteId: '99',
        fileName: 'x.srt',
        language: 'en',
        providerPriority: 120,
      );
      final Map<String, dynamic> res = await buildRemoteSubtitleFetchResponse(
        <String, dynamic>{'handle': 'opensubtitles:99'},
        registryProvider: registryOf(<VideoSubtitleProvider>[
          jimakuProvider(entriesByAnimeParam: const {}),
          _FakeProvider(id: 'opensubtitles'),
        ]),
        resolveCandidate: (_) => foreign,
        restrictToProviderIds: kJimakuOnlyProviderIds,
      );
      expect(res['ok'], isFalse);
      expect(res['error'], 'unknown-handle');
    });
  });

  group('buildRemoteSubtitleFetchResponse', () {
    test('未知 handle → unknown-handle（缓存过期/app 重启后扩展重搜即可恢复）', () async {
      final Map<String, dynamic> res = await buildRemoteSubtitleFetchResponse(
        <String, dynamic>{'handle': 'jimaku:1:gone.srt'},
        registryProvider: registryOf(<VideoSubtitleProvider>[
          _FakeProvider(id: 'ajatt'),
        ]),
        resolveCandidate: (_) => null,
      );
      expect(res['ok'], isFalse);
      expect(res['error'], 'unknown-handle');
    });

    test('下载 + 解析：响应与 /api/subtitle/parse 同形（format+cues）', () async {
      final VideoSubtitleCandidate candidate = _FakeCandidate(
        providerId: 'ajatt',
        remoteId: 'anime_tv/k-on!.html:ep01.ja.srt',
        fileName: 'ep01.ja.srt',
        language: 'ja',
        providerPriority: 150,
      );
      final Map<String, dynamic> res = await buildRemoteSubtitleFetchResponse(
        <String, dynamic>{'handle': candidate.identityKey},
        registryProvider: registryOf(<VideoSubtitleProvider>[
          _FakeProvider(id: 'ajatt', downloadBody: srt),
        ]),
        resolveCandidate: (_) => candidate,
      );
      expect(res['ok'], isTrue);
      expect(res['filename'], 'ep01.ja.srt');
      expect(res['language'], 'ja');
      expect(res['provider'], 'ajatt');
      expect(res['format'], 'srt');
      final List<dynamic> cues = res['cues'] as List<dynamic>;
      expect(cues, hasLength(1));
      final Map<String, dynamic> cue = cues.first as Map<String, dynamic>;
      expect(cue['text'], 'こんにちは');
      expect(cue['startMs'], 1000);
      expect(cue['endMs'], 2000);
    });

    test('非 UTF-8 档不整条挂掉：字节照样过解码 + 解析出时间轴', () async {
      // 「1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n」的 Shift-JIS 字节。
      // 桌面三端没有字符集检测插件（见 fushi_audio 的 decodeTextBytes 说明），
      // 正文会降级成 U+FFFD——但**整条链路必须照样跑完**：时间轴是 ASCII，cue 出得来。
      // 这里钉的是桥的契约（不因非 UTF-8 就回 download-failed），不是解码器的准确率。
      final Uint8List shiftJis = Uint8List.fromList(<int>[
        ...ascii.encode('1\n00:00:01,000 --> 00:00:02,000\n'),
        0x82,
        0xb1,
        0x82,
        0xf1,
        0x82,
        0xc9,
        0x82,
        0xbf,
        0x82,
        0xcd,
        0x0a,
      ]);
      final VideoSubtitleCandidate candidate = _FakeCandidate(
        providerId: 'jimaku',
        remoteId: '7:ep01.ja.srt',
        fileName: 'ep01.ja.srt',
        language: 'ja',
        providerPriority: 100,
      );
      final Map<String, dynamic> res = await buildRemoteSubtitleFetchResponse(
        <String, dynamic>{'handle': candidate.identityKey},
        registryProvider: registryOf(<VideoSubtitleProvider>[
          _FakeProvider(id: 'jimaku', downloadBytes: shiftJis),
        ]),
        resolveCandidate: (_) => candidate,
        restrictToProviderIds: kJimakuOnlyProviderIds,
      );
      expect(res['ok'], isTrue);
      expect(res['format'], 'srt');
      final List<dynamic> cues = res['cues'] as List<dynamic>;
      final Map<String, dynamic> cue = cues.single as Map<String, dynamic>;
      expect(cue['startMs'], 1000);
      expect(cue['endMs'], 2000);
      expect((cue['text'] as String).isNotEmpty, isTrue);
    });

    test('下载失败按 kind 翻成扩展文案键（配额耗尽 → rate-limited）', () async {
      final VideoSubtitleCandidate candidate = _FakeCandidate(
        providerId: 'opensubtitles',
        remoteId: '99',
        fileName: 'x.srt',
        language: 'en',
        providerPriority: 120,
      );
      final Map<String, dynamic> res = await buildRemoteSubtitleFetchResponse(
        <String, dynamic>{'handle': candidate.identityKey},
        registryProvider: registryOf(<VideoSubtitleProvider>[
          _FakeProvider(
            id: 'opensubtitles',
            failure: const ExternalProviderFailure(
              providerId: 'opensubtitles',
              operation: 'download',
              kind: ExternalProviderFailureKind.quotaExceeded,
              message: 'quota exceeded',
              statusCode: 406,
            ),
          ),
        ]),
        resolveCandidate: (_) => candidate,
      );
      expect(res['ok'], isFalse);
      expect(res['error'], 'rate-limited');
      expect(res['status'], 406);
    });
  });
}

class _FakeCandidate extends VideoSubtitleCandidate {
  _FakeCandidate({
    required super.providerId,
    required super.remoteId,
    required super.fileName,
    required super.language,
    required super.providerPriority,
    super.releaseName,
    super.collectionLabel,
    super.aiTranslated,
  });
}

/// 只用来钉桥的行为：provider 本身的检索逻辑各有各的测试，这里只关心「registry 扇出
/// 什么、桥怎么翻译成 wire」。
class _FakeProvider implements VideoSubtitleProvider {
  _FakeProvider({
    required this.id,
    this.priority = 100,
    this.items = const <VideoSubtitleCandidate>[],
    this.failure,
    this.downloadBody,
    this.downloadBytes,
  });

  @override
  final String id;

  @override
  final int priority;

  final List<VideoSubtitleCandidate> items;
  final ExternalProviderFailure? failure;
  final String? downloadBody;
  final Uint8List? downloadBytes;
  final List<VideoSubtitleSearchRequest> searches =
      <VideoSubtitleSearchRequest>[];

  @override
  bool get allowsFreeProbeDownload => true;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    searches.add(request);
    final ExternalProviderFailure? f = failure;
    if (f != null) {
      return ProviderBatchResult<VideoSubtitleCandidate>.failure(f);
    }
    return ProviderBatchResult<VideoSubtitleCandidate>.success(items);
  }

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async {
    final ExternalProviderFailure? f = failure;
    if (f != null) throw f;
    return VideoSubtitleDownload(
      bytes:
          downloadBytes ?? Uint8List.fromList(utf8.encode(downloadBody ?? '')),
      fileName: candidate.fileName,
      language: candidate.language,
    );
  }

  @override
  void close() {}
}
