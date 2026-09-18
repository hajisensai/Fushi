// BUG-530：浏览器扩展（Netflix 等）查词/制卡端点必须在 YomitanApiServer 上可用——扩展被
// 安装助手自动配置指向该 server（port 19633 + yomitanApiKey），用 `Basic base64('hibiki:'+key)`
// 鉴权，POST `/api/lookup/dictionary` + `/api/mine`。历史 bug：这两个端点当时只在
// FushiSyncServer 实现 → Netflix 查词/制卡全断。本测在真实 HTTP 层复现扩展请求验证修复。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart'
    show RemoteThemeColorsProvider;
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/immersion_mine_payload.dart';
import 'package:fushi/src/media/video/browser_video_study_bridge.dart';
import 'package:fushi/src/sync/yomitan_api_server.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';
import 'package:fushi_anki/fushi_anki.dart';

class _FakeLookup
    implements FushiRemoteLookupService, FushiRemotePopupLookupService {
  String? lastTerm;
  int fullLookupCount = 0;
  int popupLookupCount = 0;
  RemoteAudioLookup? audioResult;
  String? lastAudioExpression;
  String? lastAudioReading;
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    fullLookupCount++;
    lastTerm = term;
    final DictionarySearchResult r = DictionarySearchResult(searchTerm: term);
    r.popupJson = '{"html":"<b>$term</b>"}';
    return r;
  }

  @override
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopup({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    popupLookupCount++;
    lastTerm = term;
    return RemoteDictionaryPopupLookup(
      popupJson: '{"html":"<b>$term</b>"}',
      bestLength: 0,
    );
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async {
    lastAudioExpression = expression;
    lastAudioReading = reading;
    return audioResult;
  }
}

class _FakeMining implements FushiRemoteMiningService {
  Map<String, String>? plainFields;
  ImmersionMinePayload? immersionPayload;
  @override
  Future<RemoteMineResult> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  }) async {
    plainFields = fields;
    return const RemoteMineResult(result: 'success');
  }

  @override
  Future<RemoteMineResult> mineImmersion(ImmersionMinePayload payload) async {
    immersionPayload = payload;
    return const RemoteMineResult(result: 'success');
  }

  ForwardedMinePayload? forwardedPayload;

  @override
  Future<RemoteMineResult> mineForwarded(ForwardedMinePayload payload) async {
    forwardedPayload = payload;
    return const RemoteMineResult(result: 'success');
  }

  bool dupResult = false;
  String? lastDupExpression;
  String? lastDupReading;
  @override
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) async {
    lastDupExpression = expression;
    lastDupReading = reading;
    return dupResult;
  }

  // 互联 Lapis 客制化端点的捕获（/api/anki/note-type/*）。
  AnkiNoteTypeDefinition? noteTypeDef;
  String? lastNoteTypeRead;
  (String, String)? lastStylingWrite;

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
      String modelName) async {
    lastNoteTypeRead = modelName;
    return noteTypeDef;
  }

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) async {
    lastStylingWrite = (modelName, css);
    return true;
  }

  @override
  Future<bool> updateNoteTypeTemplates(
          String modelName, List<AnkiCardTemplate> templates) async =>
      true;

  @override
  Future<bool> probeMediaMaintenance() async => false;

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({bool dryRun = true}) async =>
      null;
}

String _basic(String token) =>
    'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

Future<HttpClientResponse> _post(
  int port,
  String path,
  Map<String, dynamic> body, {
  String? auth,
}) async {
  // 不在这里 close client（响应尚未被调用方读取）；测试进程退出即回收。
  final HttpClient c = HttpClient();
  final HttpClientRequest req =
      await c.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
  req.headers.contentType = ContentType.json;
  if (auth != null) req.headers.set('authorization', auth);
  req.write(jsonEncode(body));
  return req.close();
}

Future<Map<String, dynamic>> _json(HttpClientResponse resp) async {
  final String s = await resp.transform(utf8.decoder).join();
  return jsonDecode(s) as Map<String, dynamic>;
}

Future<HttpClientResponse> _get(String url) async {
  final HttpClient c = HttpClient();
  final HttpClientRequest req = await c.getUrl(Uri.parse(url));
  return req.close();
}

Future<List<int>> _collectBytes(HttpClientResponse resp) async {
  final List<int> out = <int>[];
  await for (final List<int> chunk in resp) {
    out.addAll(chunk);
  }
  return out;
}

void main() {
  const Tokenizer tok = _noopTokenize;
  const ReadingResolver rr = _noopReading;

  group('YomitanApiServer browser-extension endpoints (BUG-530)', () {
    late _FakeLookup lookup;
    late _FakeMining mining;
    late YomitanApiServer server;

    Future<void> startServer({
      String? apiKey,
      RemoteThemeColorsProvider? themeColorsProvider,
      List<String> Function()? audioSourcesProvider,
      String? Function()? extensionBuildProvider,
      String Function()? appLocaleProvider,
      void Function(double maxWidth, double maxHeight)? onExtensionPopupSize,
      void Function(BrowserVideoSample sample)? onExtensionStudy,
    }) async {
      lookup = _FakeLookup();
      mining = _FakeMining();
      server = YomitanApiServer(
        port: 0, // ephemeral
        lookupService: lookup,
        miningService: mining,
        tokenizer: tok,
        readingResolver: rr,
        themeColorsProvider: themeColorsProvider,
        audioSourcesProvider: audioSourcesProvider,
        extensionBuildProvider: extensionBuildProvider,
        appLocaleProvider: appLocaleProvider,
        onExtensionPopupSize: onExtensionPopupSize,
        onExtensionStudy: onExtensionStudy,
        apiKey: apiKey,
      );
      await server.start();
    }

    tearDown(() async => server.stop());

    test('/api/lookup/dictionary works with Basic auth', () async {
      await startServer(apiKey: 'k123');
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '走る', 'record': false},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      expect(j['type'], 'dictionaryResult');
      expect(lookup.lastTerm, '走る');
      expect((j['result'] as Map<String, dynamic>)['searchTerm'], '走る');
      expect(j['popupJson'], contains('走る'));
    });

    test('/api/extension/status identifies Hibiki on the configured port',
        () async {
      await startServer(apiKey: 'k123');
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/extension/status',
        <String, dynamic>{},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      expect(j['app'], 'fushi');
      expect(j['ready'], true);
      expect(j['port'], server.port);
    });

    test('popupOnly returns only bestLength while default keeps full result',
        () async {
      await startServer(apiKey: 'k123');

      final Map<String, dynamic> compact = await _json(await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{
          'term': '見る',
          'record': false,
          'popupOnly': true,
        },
        auth: _basic('k123'),
      ));
      expect(compact['result'], <String, dynamic>{'bestLength': 0});
      expect(compact['popupJson'], contains('見る'));
      expect(lookup.popupLookupCount, 1);
      expect(lookup.fullLookupCount, 0);

      final Map<String, dynamic> full = await _json(await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '見る', 'record': false},
        auth: _basic('k123'),
      ));
      expect((full['result'] as Map<String, dynamic>)['searchTerm'], '見る');
      expect(lookup.fullLookupCount, 1);
    });

    test(
        'lookup response carries popup size vars from themeColorsProvider '
        '(TODO-1185)', () async {
      // TODO-1185 follow-up：浏览器扩展弹窗尺寸跟随 app 内弹窗尺寸设置。app 注入的
      // browserExtensionThemeColors 把用户配置的 popupMaxWidth/Height 作为
      // --fushi-popup-max-width / --fushi-popup-max-height 放进查词响应 theme 字段，
      // content.js 逐项 setProperty 到 #entries-container，content.css 同名 var(...) 消费。
      Map<String, String> provider(String? _) => <String, String>{
            '--md-primary': 'rgb(1, 2, 3)',
            '--fushi-popup-max-width': '520px',
            '--fushi-popup-max-height': '640px',
          };
      await startServer(apiKey: 'k123', themeColorsProvider: provider);
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '猫', 'record': false},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      final Map<String, dynamic> theme = j['theme'] as Map<String, dynamic>;
      expect(theme['--fushi-popup-max-width'], '520px');
      expect(theme['--fushi-popup-max-height'], '640px');
    });

    test('lookup response omits theme when provider absent (backward compat)',
        () async {
      await startServer(apiKey: 'k123');
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '猫', 'record': false},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      // 无 provider（旧 app / server 未注入）→ 不带 theme，扩展 CSS 回落默认 400x360。
      expect(j.containsKey('theme'), isFalse);
    });

    test('lookup response carries appLocale from provider and omits it when '
        'absent', () async {
      // app 当前 UI 语言随查词响应下发（Slang languageTag），扩展据此选文案；
      // 未注入（旧 app / sync host）→ 不带字段，扩展回落浏览器语言。
      await startServer(apiKey: 'k123', appLocaleProvider: () => 'ja');
      final Map<String, dynamic> j = await _json(await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '猫', 'record': false},
        auth: _basic('k123'),
      ));
      expect(j['appLocale'], 'ja');

      await server.stop();
      await startServer(apiKey: 'k123');
      final Map<String, dynamic> j2 = await _json(await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '猫', 'record': false},
        auth: _basic('k123'),
      ));
      expect(j2.containsKey('appLocale'), isFalse);
    });

    // 扩展「主题：跟随 / 浅色 / 深色」设置：显式明暗随查词请求体 `colorScheme` 送到
    // app，provider 按它生成变量；缺省 / 非法值一律 null = 跟随 app 当前明暗。
    test('lookup request colorScheme is forwarded to themeColorsProvider',
        () async {
      final List<String?> received = <String?>[];
      Map<String, String> provider(String? colorScheme) {
        received.add(colorScheme);
        return <String, String>{'--fushi-color-scheme': colorScheme ?? 'app'};
      }

      await startServer(apiKey: 'k123', themeColorsProvider: provider);
      Future<Map<String, dynamic>> lookup(Map<String, dynamic> extra) async =>
          _json(await _post(
            server.port,
            '/api/lookup/dictionary',
            <String, dynamic>{'term': '猫', 'record': false, ...extra},
            auth: _basic('k123'),
          ));

      // 显式深色 / 浅色原样到达 provider。
      final Map<String, dynamic> dark =
          await lookup(<String, dynamic>{'colorScheme': 'dark'});
      expect((dark['theme'] as Map<String, dynamic>)['--fushi-color-scheme'],
          'dark');
      final Map<String, dynamic> light =
          await lookup(<String, dynamic>{'colorScheme': 'light'});
      expect((light['theme'] as Map<String, dynamic>)['--fushi-color-scheme'],
          'light');
      // 缺省（旧扩展 / 跟随）→ null。
      await lookup(<String, dynamic>{});
      // 非法值（别的字符串 / 非字符串）→ 当 null，不让扩展随便塞值。
      await lookup(<String, dynamic>{'colorScheme': 'auto'});
      await lookup(<String, dynamic>{'colorScheme': 1});
      await lookup(<String, dynamic>{'colorScheme': null});
      expect(received, <String?>['dark', 'light', null, null, null, null]);
    });

    test(
        'lookup response carries extensionBuild from provider and omits it '
        'when absent (BUG-726)', () async {
      // BUG-726：扩展自更新信号。app 把内置扩展内容指纹随查词响应下发（extensionBuild），
      // 扩展 background 与自身 FUSHI_DEFAULTS.build 比对，不一致即 runtime.reload 拉新。
      await startServer(apiKey: 'k123', extensionBuildProvider: () => 'abc123');
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '猫', 'record': false},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      expect(j['extensionBuild'], 'abc123');

      // 未注入（旧 app / sync host）→ 不带该字段（向后兼容：旧扩展代码不受影响）。
      await server.stop();
      await startServer(apiKey: 'k123');
      final Map<String, dynamic> j2 = await _json(await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '猫', 'record': false},
        auth: _basic('k123'),
      ));
      expect(j2.containsKey('extensionBuild'), isFalse);
    });

    test('/api/mine with screenshot routes to mineImmersion', () async {
      await startServer(apiKey: 'k123');
      final String shot = base64Encode(Uint8List.fromList(<int>[1, 2, 3]));
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/mine',
        <String, dynamic>{
          'fields': <String, String>{'expression': '走る'},
          'sentence': '走り出した。',
          'timestampMs': 1234,
          'netflixVideoId': '81',
          'screenshotBase64': shot,
        },
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      expect(j['result'], 'success');
      expect(mining.immersionPayload, isNotNull);
      expect(mining.immersionPayload!.screenshotBytes, <int>[1, 2, 3]);
      expect(mining.plainFields, isNull); // 未走纯文本回落
    });

    test('/api/mine plain text routes to mineEntry', () async {
      await startServer(apiKey: 'k123');
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/mine',
        <String, dynamic>{
          'fields': <String, String>{'expression': '本'},
          'sentence': '本を読む。',
        },
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      expect((await _json(resp))['result'], 'success');
      expect(mining.plainFields, isNotNull);
      expect(mining.immersionPayload, isNull);
    });

    // BUG-2189：扩展入队时冻进 fields.audio 的是本机签发的 5 分钟短命 token URL；Netflix /
    // YouTube 批量队列几十分钟后才「生成全部」→ token 早被 prune → Anki 抓 404 → 卡建好但
    // 单词音频空。制卡时必须把它换成自包含 data: URI。
    group('BUG-2189 /api/mine 单词音频 token → 自包含 data URI', () {
      test('token 已过期/未知 → 按 expression+reading 重解析成 data URI', () async {
        await startServer(apiKey: 'k123');
        lookup.audioResult = RemoteAudioLookup(
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          contentType: 'audio/mpeg',
        );
        final HttpClientResponse resp = await _post(
          server.port,
          '/api/mine',
          <String, dynamic>{
            'fields': <String, String>{
              'expression': '鼠',
              'reading': 'ねずみ',
              'audio': 'http://127.0.0.1:${server.port}'
                  '/api/lookup/audio/file?id=expired-token',
            },
            'sentence': '鼠が走る。',
          },
          auth: _basic('k123'),
        );
        expect(resp.statusCode, 200);
        expect((await _json(resp))['result'], 'success');
        expect(lookup.lastAudioExpression, '鼠');
        expect(lookup.lastAudioReading, 'ねずみ');
        expect(mining.plainFields!['audio'],
            'data:audio/mpeg;base64,${base64Encode(<int>[1, 2, 3])}');
        // 其余字段原样。
        expect(mining.plainFields!['expression'], '鼠');
      });

      test('token 仍活 → 直接用 token 字节，不再打音频后端', () async {
        await startServer(apiKey: 'k123');
        lookup.audioResult = RemoteAudioLookup(
          bytes: Uint8List.fromList(<int>[9, 8, 7]),
          contentType: 'audio/ogg',
        );
        final HttpClientResponse issue = await _post(
          server.port,
          '/api/lookup/audio',
          <String, dynamic>{'expression': '鼠', 'reading': 'ねずみ'},
          auth: _basic('k123'),
        );
        final String url = (await _json(issue))['url'] as String;
        lookup.lastAudioExpression = null;
        lookup.audioResult = null; // 后端此刻若被打到会得 null → 断言能分辨
        final HttpClientResponse resp = await _post(
          server.port,
          '/api/mine',
          <String, dynamic>{
            'fields': <String, String>{
              'expression': '鼠',
              'reading': 'ねずみ',
              'audio': url,
            },
            'sentence': '鼠が走る。',
          },
          auth: _basic('k123'),
        );
        expect(resp.statusCode, 200);
        expect(mining.plainFields!['audio'],
            'data:audio/ogg;base64,${base64Encode(<int>[9, 8, 7])}');
        expect(lookup.lastAudioExpression, isNull);
      });

      test('token 过期且音频库无此词 → 原引用保留（让 404 诊断照常浮出）', () async {
        await startServer(apiKey: 'k123');
        lookup.audioResult = null;
        const String stale =
            'http://127.0.0.1:1/api/lookup/audio/file?id=gone';
        final HttpClientResponse resp = await _post(
          server.port,
          '/api/mine',
          <String, dynamic>{
            'fields': <String, String>{'expression': '鼠', 'audio': stale},
            'sentence': '',
          },
          auth: _basic('k123'),
        );
        expect(resp.statusCode, 200);
        expect(mining.plainFields!['audio'], stale);
      });

      test('非本机 token 的引用（外部 http / data:）原样透传', () async {
        await startServer(apiKey: 'k123');
        lookup.audioResult = RemoteAudioLookup(
          bytes: Uint8List.fromList(<int>[1]),
          contentType: 'audio/mpeg',
        );
        for (final String ref in <String>[
          'https://example.com/forvo/鼠.mp3',
          'data:audio/mpeg;base64,AQ==',
        ]) {
          final HttpClientResponse resp = await _post(
            server.port,
            '/api/mine',
            <String, dynamic>{
              'fields': <String, String>{'expression': '鼠', 'audio': ref},
              'sentence': '',
            },
            auth: _basic('k123'),
          );
          expect(resp.statusCode, 200);
          expect(mining.plainFields!['audio'], ref);
          expect(lookup.lastAudioExpression, isNull);
        }
      });

      // BUG-2573：上面几条用例的音频只有 1~3 字节（base64 是 `AQID` / `CAgH` 之流），
      // **不含 base64 字母表里的 `+`**，恰好绕开了 `_normalizeIncomingText` 的
      // 「孤立 `+` → 空格」还原。真实单词音频是几 KB，base64 里几十个 `+` 全被换成
      // 空格 → 落卡侧 `UriData.parse` 抛 Invalid base64 data → 单词音频静默丢失。
      // 这条用真实长度载荷，端到端断言「制卡时音频字节原样落地」。
      test('真实长度音频（base64 含 +）经 /api/mine 后仍可解码出原字节', () async {
        await startServer(apiKey: 'k123');
        final Uint8List audio = Uint8List.fromList(
          List<int>.generate(1024, (int i) => (i * 7919 + 13) % 256),
        );
        final String b64 = base64Encode(audio);
        expect(b64, contains('+'),
            reason: '构造必须含 + 才覆盖得到本 bug（短音频碰不到）');
        lookup.audioResult = RemoteAudioLookup(
          bytes: audio,
          contentType: 'audio/mpeg',
        );

        final HttpClientResponse resp = await _post(
          server.port,
          '/api/mine',
          <String, dynamic>{
            'fields': <String, String>{
              'expression': '鼠',
              'reading': 'ねずみ',
              'audio': 'http://127.0.0.1:${server.port}'
                  '/api/lookup/audio/file?id=expired-token',
            },
            'sentence': '鼠が走る。',
          },
          auth: _basic('k123'),
        );
        expect(resp.statusCode, 200);
        final String? landed = mining.plainFields!['audio'];
        expect(landed, startsWith('data:audio/mpeg;base64,'));
        // 落卡侧真实解码路径：解不出字节 = 卡片没有单词音频。
        final AnkiAudioData? decoded = AnkiAudioRef.decodeDataUri(landed!);
        expect(decoded, isNotNull,
            reason: '解码失败 = 落卡侧 AudioFetchOutcome.none() '
                '= ExpressionAudio 空');
        expect(decoded!.bytes, audio);
      });

      test('沉浸制卡（clip 路径）同样改写 fields.audio', () async {
        await startServer(apiKey: 'k123');
        lookup.audioResult = RemoteAudioLookup(
          bytes: Uint8List.fromList(<int>[4, 5]),
          contentType: 'audio/mpeg',
        );
        final HttpClientResponse resp = await _post(
          server.port,
          '/api/mine',
          <String, dynamic>{
            'fields': <String, String>{
              'expression': '鼠',
              'reading': 'ねずみ',
              'audio': 'http://localhost:19633'
                  '/api/lookup/audio/file?id=expired',
            },
            'sentence': '鼠が走る。',
            'youtubeVideoId': 'abc',
            'clipStartMs': 1000,
            'clipEndMs': 2500,
          },
          auth: _basic('k123'),
        );
        expect(resp.statusCode, 200);
        expect(mining.immersionPayload, isNotNull);
        expect(mining.immersionPayload!.fields['audio'],
            'data:audio/mpeg;base64,${base64Encode(<int>[4, 5])}');
      });
    });

    test('wrong token → 401', () async {
      await startServer(apiKey: 'k123');
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '走る'},
        auth: _basic('WRONG'),
      );
      expect(resp.statusCode, 401);
      await resp.drain<void>();
    });

    test('no api key configured → auth skipped (extension still works)',
        () async {
      await startServer(apiKey: null);
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '猫'},
        auth: _basic(''),
      );
      expect(resp.statusCode, 200);
      expect((await _json(resp))['type'], 'dictionaryResult');
    });

    test('mine without fields → 400', () async {
      await startServer(apiKey: null);
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/mine',
        <String, dynamic>{'sentence': 'no fields'},
      );
      expect(resp.statusCode, 400);
      await resp.drain<void>();
    });

    test('/api/duplicate returns real duplicate flag (TODO-1176)', () async {
      await startServer(apiKey: 'k123');
      mining.dupResult = true;
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/duplicate',
        <String, dynamic>{'expression': '走る', 'reading': 'はしる'},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      expect((await _json(resp))['duplicate'], true);
      expect(mining.lastDupExpression, '走る');
      expect(mining.lastDupReading, 'はしる');
    });

    test('/api/duplicate empty expression → false without hitting backend',
        () async {
      await startServer(apiKey: 'k123');
      mining.dupResult = true;
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/duplicate',
        <String, dynamic>{'expression': ''},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      expect((await _json(resp))['duplicate'], false);
      expect(mining.lastDupExpression, isNull);
    });

    test('单词音频①②：/api/lookup/audio 返 file url，GET file 免鉴权返字节', () async {
      await startServer(apiKey: 'k123');
      lookup.audioResult = RemoteAudioLookup(
        bytes: Uint8List.fromList(<int>[9, 8, 7]),
        contentType: 'audio/mpeg',
      );
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/audio',
        <String, dynamic>{'expression': '走る', 'reading': 'はしる'},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      expect(j['type'], 'audioResult');
      expect(j['contentType'], 'audio/mpeg');
      expect(lookup.lastAudioExpression, '走る');
      expect(lookup.lastAudioReading, 'はしる');
      final String url = j['url'] as String;
      expect(url, contains('/api/lookup/audio/file?id='));
      // 文件端点裸 GET（HTML5 Audio 无 Authorization）→ 免鉴权返回字节。
      final HttpClientResponse fileResp = await _get(url);
      expect(fileResp.statusCode, 200);
      expect(fileResp.headers.contentType.toString(), contains('audio/mpeg'));
      expect(await _collectBytes(fileResp), <int>[9, 8, 7]);
    });

    test('/api/lookup/audio 未命中 → url null（弹窗降级 ✕）', () async {
      await startServer(apiKey: 'k123');
      lookup.audioResult = null;
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/audio',
        <String, dynamic>{'expression': '走る', 'reading': 'はしる'},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      expect(j['type'], 'audioResult');
      expect(j['url'], isNull);
    });

    test('/api/lookup/audio 空 expression → url null（不打后端）', () async {
      await startServer(apiKey: 'k123');
      lookup.audioResult = RemoteAudioLookup(
        bytes: Uint8List.fromList(<int>[1]),
        contentType: 'audio/mpeg',
      );
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/audio',
        <String, dynamic>{'expression': ''},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      expect((await _json(resp))['url'], isNull);
      expect(lookup.lastAudioExpression, isNull);
    });

    test('/api/lookup/audio/file 未知 id → 404', () async {
      await startServer(apiKey: 'k123');
      final HttpClientResponse resp = await _get(
          'http://127.0.0.1:${server.port}/api/lookup/audio/file?id=nope');
      expect(resp.statusCode, 404);
      await resp.drain<void>();
    });

    test('查词响应带 audioSources（provider 非空 → 渲染 ♪ 按钮）', () async {
      await startServer(
          apiKey: 'k123',
          audioSourcesProvider: () => <String>['hibiki://audio']);
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '猫', 'record': false},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      expect(j['audioSources'], <String>['hibiki://audio']);
    });

    test('查词响应无 provider 时省略 audioSources（向后兼容）', () async {
      await startServer(apiKey: 'k123');
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '猫', 'record': false},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      expect((await _json(resp)).containsKey('audioSources'), isFalse);
    });

    test('/api/duplicate wrong token → 401', () async {
      await startServer(apiKey: 'k123');
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/duplicate',
        <String, dynamic>{'expression': '猫'},
        auth: _basic('WRONG'),
      );
      expect(resp.statusCode, 401);
      await resp.drain<void>();
    });

    // 弹窗尺寸精细化 Phase D：扩展拖角 resize 回写端点 /api/extension/popup-size。
    test('/api/extension/popup-size 把原始尺寸交给 sink（未 clamp，clamp 在 app 侧）',
        () async {
      double? gotW;
      double? gotH;
      await startServer(
        apiKey: 'k123',
        onExtensionPopupSize: (double w, double h) {
          gotW = w;
          gotH = h;
        },
      );
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/extension/popup-size',
        <String, dynamic>{'maxWidth': 720, 'maxHeight': 600},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      expect((await _json(resp))['ok'], true);
      // server 不 clamp（透传原始值给 app 侧 resolveExtensionPopupSize）。
      expect(gotW, 720);
      expect(gotH, 600);
    });

    test('/api/extension/popup-size 数值型 int/double 都接受', () async {
      double? gotW;
      double? gotH;
      await startServer(
        apiKey: 'k123',
        onExtensionPopupSize: (double w, double h) {
          gotW = w;
          gotH = h;
        },
      );
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/extension/popup-size',
        <String, dynamic>{'maxWidth': 640.5, 'maxHeight': 480},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      expect(gotW, 640.5);
      expect(gotH, 480.0);
    });

    test('/api/extension/popup-size 缺字段/类型错 → 400，不触发 sink', () async {
      bool called = false;
      await startServer(
        apiKey: 'k123',
        onExtensionPopupSize: (double w, double h) => called = true,
      );
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/extension/popup-size',
        <String, dynamic>{'maxWidth': 'wide'},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 400);
      await resp.drain<void>();
      expect(called, isFalse);
    });

    test('/api/extension/popup-size 未注入 sink → 404（旧 app / 配对 host 向后兼容）',
        () async {
      await startServer(apiKey: 'k123'); // onExtensionPopupSize 缺省 null
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/extension/popup-size',
        <String, dynamic>{'maxWidth': 720, 'maxHeight': 600},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 404);
      await resp.drain<void>();
    });

    test('/api/extension/popup-size 错 token → 401，不触发 sink（鉴权守卫）', () async {
      bool called = false;
      await startServer(
        apiKey: 'k123',
        onExtensionPopupSize: (double w, double h) => called = true,
      );
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/extension/popup-size',
        <String, dynamic>{'maxWidth': 720, 'maxHeight': 600},
        auth: _basic('WRONG'),
      );
      expect(resp.statusCode, 401);
      await resp.drain<void>();
      expect(called, isFalse);
    });

    // 扩展网页视频沉浸时间 → 学习统计：POST /api/extension/study。与 popup-size 同一
    // 鉴权中间件、不进免鉴权白名单；体经 BrowserVideoSample.tryParse 校验后交 sink。
    group('/api/extension/study', () {
      const Map<String, dynamic> good = <String, dynamic>{
        'mediaKind': 'video',
        'mediaKey': 'web:yt-abc123',
        'title': '页面标题',
        'positionMs': 12345,
        'durationMs': 1400000,
        'playing': true,
        'speed': 1.5,
        'ended': false,
      };

      test('好体 → 200 且 sink 收到解析后的样本（mediaKey 原样、不加前缀）',
          () async {
        BrowserVideoSample? got;
        await startServer(
          apiKey: 'k123',
          onExtensionStudy: (BrowserVideoSample s) => got = s,
        );
        final HttpClientResponse resp = await _post(
          server.port,
          '/api/extension/study',
          good,
          auth: _basic('k123'),
        );
        expect(resp.statusCode, 200);
        expect((await _json(resp))['ok'], true);
        expect(got, isNotNull);
        expect(got!.mediaKey, 'web:yt-abc123');
        expect(got!.title, '页面标题');
        expect(got!.positionMs, 12345);
        expect(got!.durationMs, 1400000);
        expect(got!.playing, isTrue);
        expect(got!.speed, 1.5);
        expect(got!.ended, isFalse);
      });

      test('缺省字段取默认：durationMs null（直播）、speed 1.0、ended false、title 空串',
          () async {
        BrowserVideoSample? got;
        await startServer(
          apiKey: 'k123',
          onExtensionStudy: (BrowserVideoSample s) => got = s,
        );
        final HttpClientResponse resp = await _post(
          server.port,
          '/api/extension/study',
          <String, dynamic>{
            'mediaKind': 'video',
            'mediaKey': 'web:live',
            'positionMs': 0,
            'durationMs': null,
            'playing': false,
          },
          auth: _basic('k123'),
        );
        expect(resp.statusCode, 200);
        await resp.drain<void>();
        expect(got!.durationMs, isNull);
        expect(got!.speed, 1.0);
        expect(got!.ended, isFalse);
        expect(got!.title, '');
        expect(got!.displayTitle, 'web:live');
      });

      test('坏体 → 400，不触发 sink', () async {
        int called = 0;
        await startServer(
          apiKey: 'k123',
          onExtensionStudy: (BrowserVideoSample s) => called++,
        );
        final List<Map<String, dynamic>> bad = <Map<String, dynamic>>[
          <String, dynamic>{...good, 'mediaKind': 'audio'},
          <String, dynamic>{...good}..remove('mediaKind'),
          <String, dynamic>{...good, 'mediaKey': ''},
          <String, dynamic>{...good, 'mediaKey': 7},
          <String, dynamic>{...good, 'positionMs': -1},
          <String, dynamic>{...good, 'positionMs': '12'},
          <String, dynamic>{...good, 'positionMs': 1.5},
          <String, dynamic>{...good}..remove('positionMs'),
          <String, dynamic>{...good, 'durationMs': 'x'},
          <String, dynamic>{...good, 'playing': 'yes'},
          <String, dynamic>{...good}..remove('playing'),
          <String, dynamic>{...good, 'speed': 0},
          <String, dynamic>{...good, 'speed': -1},
          <String, dynamic>{...good, 'ended': 1},
          <String, dynamic>{...good, 'title': 3},
        ];
        for (final Map<String, dynamic> body in bad) {
          final HttpClientResponse resp = await _post(
            server.port,
            '/api/extension/study',
            body,
            auth: _basic('k123'),
          );
          expect(resp.statusCode, 400, reason: jsonEncode(body));
          await resp.drain<void>();
        }
        expect(called, 0);
      });

      test('未注入 sink → 404（旧 app / 配对 host 向后兼容）', () async {
        await startServer(apiKey: 'k123');
        final HttpClientResponse resp = await _post(
          server.port,
          '/api/extension/study',
          good,
          auth: _basic('k123'),
        );
        expect(resp.statusCode, 404);
        await resp.drain<void>();
      });

      test('错 token → 401，不触发 sink（写统计的入口绝不免鉴权）', () async {
        bool called = false;
        await startServer(
          apiKey: 'k123',
          onExtensionStudy: (BrowserVideoSample s) => called = true,
        );
        final HttpClientResponse resp = await _post(
          server.port,
          '/api/extension/study',
          good,
          auth: _basic('WRONG'),
        );
        expect(resp.statusCode, 401);
        await resp.drain<void>();
        expect(called, isFalse);
      });
    });
  });
}

List<String> _noopTokenize(String text) => <String>[text];
String _noopReading(String word) => '';
