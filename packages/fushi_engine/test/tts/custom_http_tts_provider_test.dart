import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/custom_http_tts_provider.dart';
import 'package:fushi_engine/tts/tts_builtin_providers.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

const CustomHttpTtsDescriptor _descriptor = CustomHttpTtsDescriptor();

TtsVoicePreset _preset(Map<String, String> params, {String apiKey = ''}) =>
    TtsVoicePreset(
      id: 'p',
      providerId: CustomHttpTtsDescriptor.providerId,
      name: 'n',
      params: params,
      secrets: <String, String>{
        if (apiKey.isNotEmpty) CustomHttpTtsDescriptor.apiKeyKey: apiKey,
      },
    );

class _Recorded {
  _Recorded(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final HttpHeaders headers;
  final String body;
}

void main() {
  test('registered as a builtin external provider', () {
    expect(
      kBuiltinTtsProviders.map((TtsProviderDescriptor d) => d.id),
      contains(CustomHttpTtsDescriptor.providerId),
    );
    expect(_descriptor.category, TtsProviderCategory.external);
    // 不预置任何第三方服务地址。
    expect(_descriptor.params.first.defaultValue, isNull);
  });

  group('buildCustomHttpTtsRequest', () {
    test('JSON body: placeholders substituted inside strings and re-encoded', () {
      const String text = 'He said "hi"\nback\\slash {lang}';
      final CustomHttpTtsRequest r = buildCustomHttpTtsRequest(
        const CustomHttpTtsConfig(
          endpoint: 'http://127.0.0.1:8001/infer_single',
          bodyTemplate:
              '{"text": "{text}", "text_lang": "{lang}", "speed_facter": "{speed}",'
              ' "label": "x{speed}x", "app_key": "{api_key}", "n": [1, "{lang}"]}',
          lang: '日语',
          speed: '1.25',
          apiKey: 'k"1',
        ),
        text,
      );
      expect(r.method, 'POST');
      expect(r.headers[HttpHeaders.contentTypeHeader], contains('json'));
      final Object? decoded = jsonDecode(utf8.decode(r.body!));
      expect(decoded, <String, Object?>{
        // 文本里的 {lang} 是正文，不再被二次代入。
        'text': text,
        'text_lang': '日语',
        'speed_facter': 1.25,
        'label': 'x1.25x',
        'app_key': 'k"1',
        'n': <Object?>[1, '日语'],
      });
    });

    test('query template values are URL-encoded and appended', () {
      final CustomHttpTtsRequest r = buildCustomHttpTtsRequest(
        const CustomHttpTtsConfig(
          endpoint: 'http://h:9880/tts?fixed=1',
          method: 'GET',
          queryTemplate: 'text={text}&text_lang={lang}&flag',
          lang: 'ja',
        ),
        'あ&b=c #?',
      );
      expect(r.method, 'GET');
      expect(r.body, isNull);
      expect(r.uri.path, '/tts');
      expect(r.uri.queryParametersAll, <String, List<String>>{
        'fixed': <String>['1'],
        'text': <String>['あ&b=c #?'],
        'text_lang': <String>['ja'],
        'flag': <String>[''],
      });
    });

    test('headers: {api_key} substituted; empty speed defaults to 1.0', () {
      final CustomHttpTtsRequest r = buildCustomHttpTtsRequest(
        const CustomHttpTtsConfig(
          endpoint: 'https://h/x',
          headersTemplate: 'Authorization: Bearer {api_key}\n\nX-Rate: {speed}',
          apiKey: 'sk-1',
        ),
        't',
      );
      expect(r.headers['Authorization'], 'Bearer sk-1');
      expect(r.headers['X-Rate'], '1.0');
      // POST 没有模板也带空请求体（Content-Length: 0），不自作主张加 JSON 头。
      expect(r.body, isEmpty);
      expect(r.headers.containsKey(HttpHeaders.contentTypeHeader), isFalse);
    });

    test('header injection through a substituted value is refused', () {
      expect(
        () => buildCustomHttpTtsRequest(
          const CustomHttpTtsConfig(
            endpoint: 'https://h/x',
            headersTemplate: 'Authorization: Bearer {api_key}',
            apiKey: 'a\r\nX-Evil: 1',
          ),
          't',
        ),
        throwsA(
          isA<TtsFailure>().having(
            (TtsFailure f) => f.code,
            'code',
            TtsFailureCode.notConfigured,
          ),
        ),
      );
    });

    test('literal credentials in templates are refused', () {
      for (final CustomHttpTtsConfig c in <CustomHttpTtsConfig>[
        const CustomHttpTtsConfig(
          endpoint: 'https://h/x',
          headersTemplate: 'X-Api-Key: plain',
        ),
        const CustomHttpTtsConfig(
          endpoint: 'https://h/x',
          bodyTemplate: '{"app_key": "plain"}',
        ),
        const CustomHttpTtsConfig(
          endpoint: 'https://h/x',
          method: 'GET',
          queryTemplate: 'token=plain',
        ),
      ]) {
        expect(
          () => buildCustomHttpTtsRequest(c, 't'),
          throwsA(isA<TtsFailure>()),
        );
      }
    });
  });

  group('validate', () {
    test('missing endpoint and bad templates are reported by key', () {
      expect(_descriptor.validate(_preset(const <String, String>{})), <String>[
        CustomHttpTtsDescriptor.endpointKey,
      ]);
      expect(
        _descriptor.validate(
          _preset(<String, String>{
            CustomHttpTtsDescriptor.endpointKey: 'http://127.0.0.1:1/tts',
            CustomHttpTtsDescriptor.bodyKey: '{"text": {text}}',
            CustomHttpTtsDescriptor.headersKey: 'no colon here',
            CustomHttpTtsDescriptor.queryKey: '=x',
            CustomHttpTtsDescriptor.responseKey:
                CustomHttpTtsResponse.jsonUrl.id,
          }),
        ),
        unorderedEquals(<String>[
          CustomHttpTtsDescriptor.bodyKey,
          CustomHttpTtsDescriptor.headersKey,
          CustomHttpTtsDescriptor.queryKey,
          CustomHttpTtsDescriptor.responsePathKey,
        ]),
      );
    });

    test('GET with a body, and literal credentials, are invalid', () {
      expect(
        _descriptor.validate(
          _preset(<String, String>{
            CustomHttpTtsDescriptor.endpointKey: 'http://h/tts',
            CustomHttpTtsDescriptor.methodKey: 'GET',
            CustomHttpTtsDescriptor.bodyKey: '{"text": "{text}"}',
            CustomHttpTtsDescriptor.headersKey: 'Authorization: Bearer abc',
          }),
        ),
        unorderedEquals(<String>[
          CustomHttpTtsDescriptor.bodyKey,
          CustomHttpTtsDescriptor.headersKey,
        ]),
      );
      expect(
        _descriptor.validate(
          _preset(<String, String>{
            CustomHttpTtsDescriptor.endpointKey: 'http://h/infer_single',
            CustomHttpTtsDescriptor.bodyKey:
                '{"app_key": "{api_key}", "text": "{text}"}',
            CustomHttpTtsDescriptor.headersKey:
                'Authorization: Bearer {api_key}',
            CustomHttpTtsDescriptor.responseKey:
                CustomHttpTtsResponse.jsonUrl.id,
            CustomHttpTtsDescriptor.responsePathKey: 'audio_url',
          }, apiKey: 'k'),
        ),
        isEmpty,
      );
    });
  });

  test(
    'audioIdentity: templates count, secrets / headers / transport do not',
    () {
      final Map<String, String> base = <String, String>{
        CustomHttpTtsDescriptor.endpointKey: 'http://127.0.0.1:8001/infer',
        CustomHttpTtsDescriptor.bodyKey: '{"text": "{text}", "model": "a"}',
      };
      final Map<String, Object?> id = _descriptor.audioIdentity(_preset(base));
      expect(
        _descriptor.audioIdentity(
          _preset(<String, String>{
            ...base,
            CustomHttpTtsDescriptor.headersKey: 'X-Trace: 1',
            CustomHttpTtsDescriptor.responseKey:
                CustomHttpTtsResponse.jsonUrl.id,
          }, apiKey: 'secret'),
        ),
        id,
      );
      expect(id.values, isNot(contains('secret')));
      expect(
        _descriptor.audioIdentity(
          _preset(<String, String>{
            ...base,
            CustomHttpTtsDescriptor.bodyKey: '{"text": "{text}", "model": "b"}',
          }),
        ),
        isNot(id),
      );
      expect(
        _descriptor.audioIdentity(
          _preset(<String, String>{
            ...base,
            CustomHttpTtsDescriptor.endpointKey: 'http://127.0.0.1:8002/infer',
          }),
        ),
        isNot(id),
      );
    },
  );

  group('synthesize against a local server', () {
    late HttpServer server;
    late HttpServer other;
    late Directory tmp;
    final List<_Recorded> requests = <_Recorded>[];
    final List<_Recorded> otherRequests = <_Recorded>[];
    late Future<void> Function(HttpRequest req) handler;
    final TtsHost host = TtsHost(httpClientFactory: () => HttpClient());

    Future<void> serveWav(HttpRequest req) async {
      req.response.headers.contentType = ContentType('audio', 'wav');
      req.response.add(buildWav());
      await req.response.close();
    }

    setUp(() async {
      requests.clear();
      otherRequests.clear();
      tmp = await Directory.systemTemp.createTemp('tts_custom_http_test_');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      handler = serveWav;
      server.listen((HttpRequest req) async {
        final String body = await utf8.decoder.bind(req).join();
        requests.add(_Recorded(req.method, req.uri, req.headers, body));
        await handler(req);
      });
      other.listen((HttpRequest req) async {
        await req.drain<void>();
        otherRequests.add(_Recorded(req.method, req.uri, req.headers, ''));
        await serveWav(req);
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await other.close(force: true);
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    String base() => 'http://127.0.0.1:${server.port}';
    String out() => p.join(tmp.path, 'out.wav');

    Future<TtsResult> run(
      Map<String, String> params, {
      String apiKey = '',
      String text = 'こんにちは',
    }) async {
      final TtsProvider provider = _descriptor.create(
        _preset(params, apiKey: apiKey),
        host,
      );
      try {
        return await provider.synthesize(
          text,
          outputPath: out(),
          cancel: TtsCancelToken(),
        );
      } finally {
        await provider.dispose();
      }
    }

    test(
      'audio response: POST JSON body, bytes land in the output file',
      () async {
        final TtsResult result = await run(<String, String>{
          CustomHttpTtsDescriptor.endpointKey: '${base()}/tts',
          CustomHttpTtsDescriptor.bodyKey:
              '{"text": "{text}", "lang": "{lang}"}',
          CustomHttpTtsDescriptor.langKey: 'ja',
          CustomHttpTtsDescriptor.headersKey: 'Authorization: Bearer {api_key}',
        }, apiKey: 'sk-x');
        expect(result.format, TtsAudioFormat.wav);
        expect(await File(out()).readAsBytes(), buildWav());
        expect(requests.single.method, 'POST');
        expect(requests.single.uri.path, '/tts');
        expect(jsonDecode(requests.single.body), <String, Object?>{
          'text': 'こんにちは',
          'lang': 'ja',
        });
        expect(
          requests.single.headers.value(HttpHeaders.authorizationHeader),
          'Bearer sk-x',
        );
      },
    );

    test('audio response: GET with query template', () async {
      await run(<String, String>{
        CustomHttpTtsDescriptor.endpointKey: base(),
        CustomHttpTtsDescriptor.methodKey: 'GET',
        CustomHttpTtsDescriptor.queryKey: 'text={text}&speed={speed}',
        CustomHttpTtsDescriptor.speedKey: '0.9',
      }, text: 'a b&c');
      expect(requests.single.method, 'GET');
      expect(requests.single.uri.queryParameters, <String, String>{
        'text': 'a b&c',
        'speed': '0.9',
      });
    });

    test('json_base64: decodes data-URI base64 at the field path', () async {
      handler = (HttpRequest req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'audio': 'data:audio/wav;base64,${base64Encode(buildWav())}',
              },
            ],
          }),
        );
        await req.response.close();
      };
      final TtsResult result = await run(<String, String>{
        CustomHttpTtsDescriptor.endpointKey: base(),
        CustomHttpTtsDescriptor.responseKey:
            CustomHttpTtsResponse.jsonBase64.id,
        CustomHttpTtsDescriptor.responsePathKey: 'data.0.audio',
      });
      expect(result.format, TtsAudioFormat.wav);
      expect(await File(out()).readAsBytes(), buildWav());
    });

    test(
      'json_url: same-origin URL fetched with the configured headers',
      () async {
        handler = (HttpRequest req) async {
          if (req.uri.path == '/outputs/a.wav') return serveWav(req);
          req.response.headers.contentType = ContentType.json;
          req.response.write('{"msg": "ok", "audio_url": "/outputs/a.wav"}');
          await req.response.close();
        };
        await run(<String, String>{
          CustomHttpTtsDescriptor.endpointKey: '${base()}/infer_single',
          CustomHttpTtsDescriptor.bodyKey:
              '{"app_key": "{api_key}", "text": "{text}"}',
          CustomHttpTtsDescriptor.headersKey: 'X-Api-Key: {api_key}',
          CustomHttpTtsDescriptor.responseKey: CustomHttpTtsResponse.jsonUrl.id,
          CustomHttpTtsDescriptor.responsePathKey: 'audio_url',
        }, apiKey: 'k1');
        expect(
          requests.map((_Recorded r) => '${r.method} ${r.uri.path}'),
          <String>['POST /infer_single', 'GET /outputs/a.wav'],
        );
        expect(requests.last.headers.value('x-api-key'), 'k1');
        expect(await File(out()).readAsBytes(), buildWav());
      },
    );

    test('json_url: a different origin never receives the headers', () async {
      handler = (HttpRequest req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{
            'audio_url': 'http://127.0.0.1:${other.port}/a.wav',
          }),
        );
        await req.response.close();
      };
      await run(<String, String>{
        CustomHttpTtsDescriptor.endpointKey: base(),
        CustomHttpTtsDescriptor.headersKey: 'Authorization: Bearer {api_key}',
        CustomHttpTtsDescriptor.responseKey: CustomHttpTtsResponse.jsonUrl.id,
        CustomHttpTtsDescriptor.responsePathKey: 'audio_url',
      }, apiKey: 'sk-secret');
      expect(otherRequests.single.method, 'GET');
      expect(
        otherRequests.single.headers.value(HttpHeaders.authorizationHeader),
        isNull,
      );
    });

    test('200 with an empty audio field is a bad response', () async {
      handler = (HttpRequest req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"msg": "app_key错误", "audio_url": ""}');
        await req.response.close();
      };
      await expectLater(
        run(<String, String>{
          CustomHttpTtsDescriptor.endpointKey: base(),
          CustomHttpTtsDescriptor.responseKey: CustomHttpTtsResponse.jsonUrl.id,
          CustomHttpTtsDescriptor.responsePathKey: 'audio_url',
        }),
        throwsA(
          isA<TtsFailure>().having(
            (TtsFailure f) => f.code,
            'code',
            TtsFailureCode.badResponse,
          ),
        ),
      );
    });

    test(
      'non-audio bytes are refused; HTTP status mapped; no detail leak',
      () async {
        handler = (HttpRequest req) async {
          req.response.write('<html>not audio</html>');
          await req.response.close();
        };
        await expectLater(
          run(<String, String>{CustomHttpTtsDescriptor.endpointKey: base()}),
          throwsA(
            isA<TtsFailure>().having(
              (TtsFailure f) => f.code,
              'code',
              TtsFailureCode.badResponse,
            ),
          ),
        );
        handler = (HttpRequest req) async {
          req.response.statusCode = 401;
          req.response.write('bad key sk-secret');
          await req.response.close();
        };
        try {
          await run(<String, String>{
            CustomHttpTtsDescriptor.endpointKey: base(),
            CustomHttpTtsDescriptor.headersKey:
                'Authorization: Bearer {api_key}',
          }, apiKey: 'sk-secret');
          fail('should throw');
        } on TtsFailure catch (f) {
          expect(f.code, TtsFailureCode.unauthorized);
          expect(f.toString(), isNot(contains('sk-secret')));
          expect(f.toString(), isNot(contains('127.0.0.1')));
        }
      },
    );
  });
}
