import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/elevenlabs_tts_provider.dart';
import 'package:fushi_engine/tts/tts_builtin_providers.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

/// ElevenLabs：请求形状（模型 / 语言 / 种子）、模型与声音列表（翻页）、免费与付费档
/// 的失败码（额度用完的新旧两种错误形状、免费账户用声音库声音）。响应形状取自官方
/// 文档（elevenlabs.io/docs，2026-11）。
void main() {
  const String key = 'xi-test-key';
  const String roger = 'CwhRBWXzGAHq8TQ4Fs17';

  late HttpServer server;
  late Directory tmp;
  late List<_Call> log;

  /// 合成接口下一次的错误（null = 正常出音频）。
  late ({int status, Object? body})? ttsError;

  setUp(() async {
    log = <_Call>[];
    ttsError = null;
    tmp = await Directory.systemTemp.createTemp('elevenlabs_tts_test');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      final String text = await utf8.decodeStream(req);
      final Object? json = text.isEmpty ? null : jsonDecode(text);
      final String? auth = req.headers.value('xi-api-key');
      log.add((
        method: req.method,
        path: req.uri.path,
        query: req.uri.queryParameters,
        json: json is Map<String, Object?> ? json : null,
      ));
      final HttpResponse res = req.response;
      void writeJson(Object? body) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(body));
      }

      if (auth != key) {
        res.statusCode = 401;
        writeJson(<String, Object?>{
          'detail': <String, Object?>{
            'type': 'authentication_error',
            'code': 'invalid_api_key',
            'message': 'Invalid API key',
          },
        });
        await res.close();
        return;
      }
      final String path = req.uri.path;
      if (req.method == 'POST' && path.startsWith('/v1/text-to-speech/')) {
        final ({int status, Object? body})? error = ttsError;
        if (error != null) {
          res.statusCode = error.status;
          writeJson(error.body);
        } else {
          res.headers.contentType = ContentType('audio', 'mpeg');
          res.add(buildMp3(frames: 4));
        }
      } else if (req.method == 'GET' && path == '/v1/models') {
        writeJson(<Object?>[
          <String, Object?>{
            'model_id': 'eleven_multilingual_v2',
            'name': 'Eleven Multilingual v2',
            'can_do_text_to_speech': true,
          },
          <String, Object?>{
            'model_id': 'eleven_v4',
            'name': 'Eleven v4',
            'can_do_text_to_speech': true,
          },
          <String, Object?>{
            'model_id': 'eleven_multilingual_sts_v2',
            'name': 'Speech to speech',
            'can_do_text_to_speech': false,
          },
        ]);
      } else if (req.method == 'GET' && path == '/v2/voices') {
        final String? token = req.uri.queryParameters['next_page_token'];
        writeJson(
          token == null
              ? <String, Object?>{
                  'voices': <Object?>[
                    <String, Object?>{
                      'voice_id': roger,
                      'name': 'Roger',
                      'category': 'premade',
                      'labels': <String, Object?>{
                        'gender': 'male',
                        'language': 'en',
                      },
                    },
                  ],
                  'has_more': true,
                  'next_page_token': 'page2',
                }
              : <String, Object?>{
                  'voices': <Object?>[
                    <String, Object?>{
                      'voice_id': 'jaVoice',
                      'name': 'Kaori',
                      'category': 'cloned',
                      'labels': <String, Object?>{'gender': 'female'},
                      'verified_languages': <Object?>[
                        <String, Object?>{
                          'language': 'ja',
                          'model_id': 'eleven_v4',
                          'locale': 'ja-JP',
                        },
                      ],
                    },
                  ],
                  'has_more': false,
                },
        );
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  int n = 0;
  String out() => '${tmp.path}${Platform.pathSeparator}${n++}.mp3';

  ElevenLabsTtsProvider provider({
    String apiKey = key,
    String model = 'eleven_v4',
    String voice = roger,
    String language = 'ja',
  }) => ElevenLabsTtsProvider(
    apiKey: apiKey,
    model: model,
    voice: voice,
    language: language,
    host: const TtsHost(),
    apiBase: Uri.parse('http://127.0.0.1:${server.port}'),
  );

  Matcher failsWith(TtsFailureCode code) =>
      throwsA(isA<TtsFailure>().having((TtsFailure f) => f.code, 'code', code));

  test(
    'registered as a built-in online engine; voice and model can be typed in',
    () {
      const ElevenLabsTtsDescriptor d = ElevenLabsTtsDescriptor();
      expect(
        kBuiltinTtsProviders.map((TtsProviderDescriptor p) => p.id),
        contains(ElevenLabsTtsDescriptor.providerId),
      );
      expect(d.category, TtsProviderCategory.online);
      for (final String k in <String>[
        ElevenLabsTtsDescriptor.voiceKey,
        ElevenLabsTtsDescriptor.modelKey,
      ]) {
        expect(
          d.params.firstWhere((TtsParamSpec s) => s.key == k).allowsCustomValue,
          isTrue,
          reason: k,
        );
      }
    },
  );

  test('synthesizes MP3 for the voice with model, language and seed', () async {
    final TtsResult result = await provider().synthesizeDirected(
      'こんにちは。',
      outputPath: out(),
      cancel: TtsCancelToken(),
      direction: const TtsDirection(seed: 42),
    );
    expect(result.format, TtsAudioFormat.mp3);
    final _Call call = log.single;
    expect(call.path, '/v1/text-to-speech/$roger');
    expect(call.query['output_format'], 'mp3_44100_128');
    expect(call.json, <String, Object?>{
      'text': 'こんにちは。',
      'model_id': 'eleven_v4',
      'language_code': 'ja',
      'seed': 42,
    });
  });

  test('language_code is left out for auto and for multilingual v2', () {
    expect(
      elevenLabsSpeechRequest(text: 'a', model: 'eleven_v4', language: 'auto'),
      isNot(contains('language_code')),
    );
    expect(
      elevenLabsSpeechRequest(
        text: 'a',
        model: 'eleven_multilingual_v2',
        language: 'ja',
      ),
      isNot(contains('language_code')),
    );
    // 只声明种子：语速 / 情绪等不发（不发 voice_settings，免得覆盖网页上保存的设置）。
    expect(
      effectiveTtsDirection(
        provider().directionSupport,
        const TtsDirection(rateOffset: 0.2, seed: 1),
      ).rateOffset,
      isNull,
    );
  });

  test('quota used up (402 insufficient_credits) is quotaExceeded', () async {
    ttsError = (
      status: 402,
      body: <String, Object?>{
        'detail': <String, Object?>{
          'type': 'payment_required',
          'code': 'insufficient_credits',
          'message': 'Not enough credits',
        },
      },
    );
    await expectLater(
      provider().synthesize('a', outputPath: out(), cancel: TtsCancelToken()),
      failsWith(TtsFailureCode.quotaExceeded),
    );
  });

  test(
    'old-style 401 quota_exceeded is quotaExceeded, not a bad key',
    () async {
      ttsError = (
        status: 401,
        body: <String, Object?>{
          'detail': <String, Object?>{
            'status': 'quota_exceeded',
            'message': 'This request exceeds your quota.',
          },
        },
      );
      await expectLater(
        provider().synthesize('a', outputPath: out(), cancel: TtsCancelToken()),
        failsWith(TtsFailureCode.quotaExceeded),
      );
    },
  );

  test(
    'free plan using a paid-only feature is quotaExceeded (upgrade, not a new key)',
    () async {
      ttsError = (
        status: 403,
        body: <String, Object?>{
          'detail': <String, Object?>{
            'type': 'authorization_error',
            'code': 'subscription_required',
          },
        },
      );
      await expectLater(
        provider().synthesize('a', outputPath: out(), cancel: TtsCancelToken()),
        failsWith(TtsFailureCode.quotaExceeded),
      );
    },
  );

  test('a wrong key stays unauthorized; rate limits stay transient', () async {
    await expectLater(
      provider(
        apiKey: 'wrong',
      ).synthesize('a', outputPath: out(), cancel: TtsCancelToken()),
      failsWith(TtsFailureCode.unauthorized),
    );
    ttsError = (
      status: 429,
      body: <String, Object?>{
        'detail': <String, Object?>{
          'type': 'rate_limit_error',
          'code': 'concurrent_limit_exceeded',
        },
      },
    );
    await expectLater(
      provider().synthesize('a', outputPath: out(), cancel: TtsCancelToken()),
      throwsA(
        isA<TtsFailure>()
            .having(
              (TtsFailure f) => f.code,
              'code',
              TtsFailureCode.rateLimited,
            )
            .having((TtsFailure f) => f.isTransient, 'transient', isTrue),
      ),
    );
  });

  test('a deleted voice is rejected', () async {
    ttsError = (
      status: 404,
      body: <String, Object?>{
        'detail': <String, Object?>{
          'type': 'not_found',
          'code': 'voice_not_found',
        },
      },
    );
    await expectLater(
      provider().synthesize('a', outputPath: out(), cancel: TtsCancelToken()),
      failsWith(TtsFailureCode.rejected),
    );
  });

  test(
    'voices follow next_page_token; locale and gender come from the voice',
    () async {
      final List<TtsVoice> voices = await provider().listVoices();
      expect(voices.map((TtsVoice v) => v.id), <String>[roger, 'jaVoice']);
      expect(voices[0].locale, 'en');
      expect(voices[0].gender, 'male');
      expect(voices[1].locale, 'ja-JP');
      expect(log.last.query['next_page_token'], 'page2');
    },
  );

  test('model list only has text-to-speech models', () async {
    final List<TtsVoice> models = await provider().listParamOptions(
      ElevenLabsTtsDescriptor.modelKey,
    );
    expect(models.map((TtsVoice m) => m.id), <String>[
      'eleven_multilingual_v2',
      'eleven_v4',
    ]);
    expect(models.first.displayName, 'Eleven Multilingual v2');
  });
}

typedef _Call = ({
  String method,
  String path,
  Map<String, String> query,
  Map<String, Object?>? json,
});
