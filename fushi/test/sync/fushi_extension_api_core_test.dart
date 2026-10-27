import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/media/video/browser_video_study_bridge.dart'
    show BrowserVideoSample;
import 'package:fushi/src/sync/fushi_api_server.dart';
import 'package:fushi/src/sync/fushi_extension_api_core.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';

/// [FushiExtensionApiCore] 契约：与 HTTP 无关的扩展端点核心。HTTP 外壳
/// （`fushi_api_server_extension_endpoints_test.dart` 等）与 app 内浏览器（进程内直接调）
/// 共用它，所以缺字段 / 未注入的状态码与文案必须与旧 HTTP 端点逐字一致。
void main() {
  // fetch 解码走 decodeTextBytes，会试平台字符集检测插件，需要 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('/api/subtitle/parse', () {
    test('正常 → 200 + cues', () async {
      final FushiExtensionApiResponse res = await FushiExtensionApiCore()
          .handle('/api/subtitle/parse', <String, dynamic>{
            'filename': 'a.srt',
            'content': '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n',
          });
      expect(res.ok, isTrue);
      expect(res.status, 200);
      expect(res.text, isNull);
      final List<dynamic> cues = res.json!['cues'] as List<dynamic>;
      expect(cues, hasLength(1));
    });

    test('缺字段 → 400 Missing filename/content', () async {
      final FushiExtensionApiResponse res = await FushiExtensionApiCore()
          .handle('/api/subtitle/parse', <String, dynamic>{
            'filename': 'a.srt',
          });
      expect(res.ok, isFalse);
      expect(res.status, 400);
      expect(res.text, 'Missing filename/content');
      expect(res.json, isNull);
    });
  });

  group('/api/youtube/captions', () {
    test('走注入的 resolver，preferLang 缺省 ja', () async {
      final List<(String, String)> calls = <(String, String)>[];
      final FushiExtensionApiCore core = FushiExtensionApiCore(
        youtubeCaptionsResolver:
            (String idOrUrl, {required String preferLang}) async {
              calls.add((idOrUrl, preferLang));
              return <String, dynamic>{'tracks': <Object>[]};
            },
      );
      final FushiExtensionApiResponse res = await core.handle(
        '/api/youtube/captions',
        <String, dynamic>{'videoId': 'abc123'},
      );
      expect(res.ok, isTrue);
      expect(res.json, <String, dynamic>{'tracks': <Object>[]});
      expect(calls.single, ('abc123', 'ja'));

      await core.handle('/api/youtube/captions', <String, dynamic>{
        'url': 'https://youtu.be/x',
        'preferLang': 'en',
      });
      expect(calls.last, ('https://youtu.be/x', 'en'));

      await core.handle('/api/youtube/captions', <String, dynamic>{
        'videoId': 'y',
        'preferLang': '',
      });
      expect(calls.last, ('y', 'ja'), reason: '空串 preferLang 回落 ja');
    });

    test('缺 videoId/url → 400 Missing videoId，不调 resolver', () async {
      final FushiExtensionApiCore core = FushiExtensionApiCore(
        youtubeCaptionsResolver:
            (String idOrUrl, {required String preferLang}) async =>
                fail('不应调用'),
      );
      final FushiExtensionApiResponse res = await core.handle(
        '/api/youtube/captions',
        <String, dynamic>{},
      );
      expect(res.status, 400);
      expect(res.text, 'Missing videoId');
    });
  });

  group('/api/extension/study', () {
    final Map<String, dynamic> good = <String, dynamic>{
      'mediaKind': 'video',
      'mediaKey': 'web:yt-abc123',
      'title': 't',
      'positionMs': 1000,
      'playing': true,
    };

    test('sink 未注入 → 404 Study sink off', () async {
      final FushiExtensionApiResponse res = await FushiExtensionApiCore()
          .handle('/api/extension/study', good);
      expect(res.status, 404);
      expect(res.text, 'Study sink off');
    });

    test('体不合法 → 400，不触发 sink', () async {
      int called = 0;
      final FushiExtensionApiResponse res = await FushiExtensionApiCore(
        onExtensionStudy: (BrowserVideoSample _) => called++,
      ).handle('/api/extension/study', <String, dynamic>{'mediaKey': 1});
      expect(res.status, 400);
      expect(res.text, 'Invalid study sample');
      expect(called, 0);
    });

    test('合法 → 200 {ok:true}，sink 收到样本', () async {
      BrowserVideoSample? got;
      final FushiExtensionApiResponse res = await FushiExtensionApiCore(
        onExtensionStudy: (BrowserVideoSample s) => got = s,
      ).handle('/api/extension/study', good);
      expect(res.ok, isTrue);
      expect(res.json, <String, dynamic>{'ok': true});
      expect(got!.mediaKey, 'web:yt-abc123');
      expect(got!.positionMs, 1000);
    });
  });

  group('/api/extension/popup-size', () {
    test('sink 收到原始尺寸', () async {
      final List<(double, double)> got = <(double, double)>[];
      final FushiExtensionApiCore core = FushiExtensionApiCore(
        onExtensionPopupSize: (double w, double h) => got.add((w, h)),
      );
      final FushiExtensionApiResponse res = await core.handle(
        '/api/extension/popup-size',
        <String, dynamic>{'maxWidth': 520, 'maxHeight': 640.5},
      );
      expect(res.json, <String, dynamic>{'ok': true});
      expect(got.single, (520.0, 640.5));

      final FushiExtensionApiResponse bad = await core.handle(
        '/api/extension/popup-size',
        <String, dynamic>{'maxWidth': '520'},
      );
      expect(bad.status, 400);
      expect(bad.text, 'Missing maxWidth/maxHeight');
      expect(got, hasLength(1));
    });

    test('未注入 → 404 Popup size sink off', () async {
      final FushiExtensionApiResponse res = await FushiExtensionApiCore()
          .handle('/api/extension/popup-size', <String, dynamic>{
            'maxWidth': 1,
            'maxHeight': 1,
          });
      expect(res.status, 404);
      expect(res.text, 'Popup size sink off');
    });
  });

  test('/api/extension/fonts 未注入 → 404 Not Found', () async {
    final FushiExtensionApiCore core = FushiExtensionApiCore();
    expect(core.unavailableResponse('/api/extension/fonts')!.status, 404);
    final FushiExtensionApiResponse res = await core.handle(
      '/api/extension/fonts',
      <String, dynamic>{},
    );
    expect(res.status, 404);
    expect(res.text, 'Not Found');
  });

  test('未知路径 → 404 Unknown endpoint；paths 含全部 9 条', () async {
    final FushiExtensionApiResponse res = await FushiExtensionApiCore().handle(
      '/api/nope',
      <String, dynamic>{},
    );
    expect(res.status, 404);
    expect(res.text, 'Unknown endpoint');
    expect(FushiExtensionApiCore.paths, hasLength(9));
    expect(
      FushiExtensionApiCore.paths,
      containsAll(<String>[
        '/api/subtitle/jimaku/search',
        '/api/subtitle/jimaku/fetch',
      ]),
    );
  });

  group('在线字幕 search → fetch', () {
    const String srt = '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n';
    final _FakeProvider provider = _FakeProvider(
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
      downloadBody: srt,
    );
    Future<VideoSubtitleRegistry?> registry() async =>
        VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]);

    test('同一实例：search 暂存的候选 fetch 能取回；clear 后 unknown-handle', () async {
      final FushiExtensionApiCore core = FushiExtensionApiCore(
        subtitleRegistryProvider: registry,
      );
      final FushiExtensionApiResponse search = await core.handle(
        '/api/subtitle/search',
        <String, dynamic>{'query': 'x'},
      );
      expect(search.json!['ok'], isTrue);
      final String handle =
          ((search.json!['candidates'] as List<dynamic>).single
                  as Map<String, dynamic>)['handle']
              as String;

      final FushiExtensionApiResponse fetch = await core.handle(
        '/api/subtitle/fetch',
        <String, dynamic>{'handle': handle},
      );
      expect(fetch.json!['ok'], isTrue);
      expect(fetch.json!['provider'], 'ajatt');
      expect(fetch.json!['cues'] as List<dynamic>, hasLength(1));

      // 另一个实例没有这份候选缓存。
      final FushiExtensionApiResponse other = await FushiExtensionApiCore(
        subtitleRegistryProvider: registry,
      ).handle('/api/subtitle/fetch', <String, dynamic>{'handle': handle});
      expect(other.json!['error'], 'unknown-handle');

      core.clearSubtitleCandidates();
      final FushiExtensionApiResponse cleared = await core.handle(
        '/api/subtitle/fetch',
        <String, dynamic>{'handle': handle},
      );
      expect(cleared.status, 200);
      expect(cleared.json, <String, dynamic>{
        'ok': false,
        'error': 'unknown-handle',
      });
    });

    test('HTTP 服务停服只清自建核心的候选；注入的共享核心（app 内浏览器也在用）不清', () async {
      Future<String> searchHandle(FushiExtensionApiCore core) async {
        final FushiExtensionApiResponse search = await core.handle(
          '/api/subtitle/search',
          <String, dynamic>{'query': 'x'},
        );
        return ((search.json!['candidates'] as List<dynamic>).single
                as Map<String, dynamic>)['handle']
            as String;
      }

      FushiApiServer server(FushiExtensionApiCore? core) => FushiApiServer(
        port: 0,
        lookupService: _NoLookup(),
        tokenizer: (List<String> ts) async => <List<TokenizedSegment>>[
          for (final String t in ts) <TokenizedSegment>[(text: t, reading: '')],
        ],
        subtitleRegistryProvider: registry,
        extensionApiCore: core,
      );

      final FushiExtensionApiCore shared = FushiExtensionApiCore(
        subtitleRegistryProvider: registry,
      );
      final String handle = await searchHandle(shared);
      await server(shared).stop();
      final FushiExtensionApiResponse fetch = await shared.handle(
        '/api/subtitle/fetch',
        <String, dynamic>{'handle': handle},
      );
      expect(
        fetch.json!['ok'],
        isTrue,
        reason: '停 / 重启 HTTP 服务不得清掉 app 内浏览器正在用的候选',
      );
    });

    test('jimaku 旧路径限定 Jimaku 一家：只有 ajatt → no-api-key', () async {
      final FushiExtensionApiResponse res = await FushiExtensionApiCore(
        subtitleRegistryProvider: registry,
      ).handle('/api/subtitle/jimaku/search', <String, dynamic>{'query': 'x'});
      expect(res.json!['ok'], isFalse);
      expect(res.json!['error'], 'no-api-key');
    });

    test('registry 未注入 → 200 no-provider', () async {
      final FushiExtensionApiResponse res = await FushiExtensionApiCore()
          .handle('/api/subtitle/search', <String, dynamic>{'query': 'x'});
      expect(res.status, 200);
      expect(res.json!['error'], 'no-provider');
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
  });
}

class _FakeProvider implements VideoSubtitleProvider {
  _FakeProvider({
    required this.id,
    this.items = const <VideoSubtitleCandidate>[],
    this.downloadBody = '',
  });

  @override
  final String id;

  @override
  int get priority => 150;

  final List<VideoSubtitleCandidate> items;
  final String downloadBody;

  @override
  bool get allowsFreeProbeDownload => true;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async => ProviderBatchResult<VideoSubtitleCandidate>.success(items);

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async => VideoSubtitleDownload(
    bytes: Uint8List.fromList(utf8.encode(downloadBody)),
    fileName: candidate.fileName,
    language: candidate.language,
  );

  @override
  void close() {}
}

class _NoLookup implements FushiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async => null;

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}
