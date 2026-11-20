import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/unsloth_studio_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

/// Unsloth Studio：模型 / 声音列表、每句的语言与模板、请求形状。响应形状取自
/// 本机 Unsloth Studio（CosyVoice3 + 一个日语参考的克隆声音）。
void main() {
  const String voiceId = '0f3c9a2b7d4e4b6f8a1c2d3e4f5a6b7c';
  const String transcript = '今日はいい天気ですね。散歩に行きましょう。';
  const String cosy = 'audio-cpp/audio.cpp-gguf/CosyVoice3-GGUF';
  const String key = 'sk-unsloth-test';

  late HttpServer server;
  late Directory tmp;
  late List<
    ({String method, String path, String? auth, Map<String, Object?>? json})
  >
  log;
  late bool voiceDeleted;

  setUp(() async {
    log =
        <
          ({
            String method,
            String path,
            String? auth,
            Map<String, Object?>? json,
          })
        >[];
    voiceDeleted = false;
    tmp = await Directory.systemTemp.createTemp('unsloth_tts_test');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      final String text = await utf8.decodeStream(req);
      final Object? json = text.isEmpty ? null : jsonDecode(text);
      final String? auth = req.headers.value(HttpHeaders.authorizationHeader);
      log.add((
        method: req.method,
        path: req.uri.path,
        auth: auth,
        json: json is Map<String, Object?> ? json : null,
      ));
      final HttpResponse res = req.response;
      if (auth != 'Bearer $key') {
        res.statusCode = 401;
        await res.close();
        return;
      }
      switch ((req.method, req.uri.path)) {
        case ('GET', '/v1/models'):
          res.headers.contentType = ContentType.json;
          res.write(
            jsonEncode(<String, Object?>{
              'object': 'list',
              'data': <Object?>[
                <String, Object?>{
                  'id':
                      'audio-cpp/audio.cpp-gguf/Qwen3-TTS-12Hz-0.6B-Base-GGUF',
                  'task': 'text-to-speech',
                  'loaded': false,
                },
                <String, Object?>{
                  'id': 'unsloth/gemma-4-E4B-it-GGUF',
                  'task': 'text-generation',
                  'loaded': true,
                },
                <String, Object?>{
                  'id': cosy,
                  'task': 'text-to-speech',
                  'loaded': true,
                },
                <String, Object?>{
                  'id': 'audio-cpp/MiniMax-Music3-GGUF',
                  'task': 'music',
                },
              ],
            }),
          );
        case ('GET', '/v1/audio/voices'):
          res.headers.contentType = ContentType.json;
          res.write(
            jsonEncode(<String, Object?>{
              'voices': <Object?>[
                if (!voiceDeleted)
                  <String, Object?>{
                    'id': voiceId,
                    'name': 'narrator-ja',
                    'transcript': transcript,
                    'language': 'ja',
                    'duration_s': 6.416,
                    'sample_rate': 24000,
                  },
                <String, Object?>{'id': 'nameless'},
              ],
            }),
          );
        case ('POST', '/v1/audio/speech'):
          res.add(buildWav(dataBytes: 3200));
        default:
          res.statusCode = 404;
      }
      await res.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  TtsProvider provider({
    String model = cosy,
    String voice = voiceId,
    String language = 'auto',
    String apiKey = key,
  }) => const UnslothStudioTtsDescriptor().create(
    TtsVoicePreset(
      id: 'p',
      providerId: UnslothStudioTtsDescriptor.providerId,
      name: 'p',
      params: <String, String>{
        UnslothStudioTtsDescriptor.endpointKey:
            'http://127.0.0.1:${server.port}/v1',
        UnslothStudioTtsDescriptor.modelKey: model,
        UnslothStudioTtsDescriptor.voiceKey: voice,
        UnslothStudioTtsDescriptor.languageKey: language,
      },
      secrets: <String, String>{UnslothStudioTtsDescriptor.apiKeyKey: apiKey},
    ),
    const TtsHost(),
  );

  Future<void> say(TtsProvider p, String text, String name) => p.synthesize(
    text,
    outputPath: '${tmp.path}${Platform.pathSeparator}$name.wav',
    cancel: TtsCancelToken(),
  );

  List<Map<String, Object?>?> speechBodies() => <Map<String, Object?>?>[
    for (final e in log)
      if (e.path == '/v1/audio/speech') e.json,
  ];

  test('model picker lists only text-to-speech models, loaded first', () async {
    final TtsProvider p = provider();
    final List<TtsVoice> models = await p.listParamOptions(
      UnslothStudioTtsDescriptor.modelKey,
    );
    await p.dispose();
    expect(
      <String>[for (final m in models) m.id],
      <String>[cosy, 'audio-cpp/audio.cpp-gguf/Qwen3-TTS-12Hz-0.6B-Base-GGUF'],
    );
    expect(log.single.auth, 'Bearer $key');
  });

  test('voice picker reads the voices array with name and language', () async {
    final TtsProvider p = provider();
    final List<TtsVoice> voices = await p.listParamOptions(
      UnslothStudioTtsDescriptor.voiceKey,
    );
    await p.dispose();
    expect(
      <String>[for (final v in voices) v.id],
      <String>[voiceId, 'nameless'],
    );
    expect(voices.first.displayName, 'narrator-ja');
    expect(voices.first.locale, 'ja');
    expect(voices.last.displayName, 'nameless');
  });

  test(
    'Chinese sentence: zh + cross_lingual + transcript from the voice',
    () async {
      final TtsProvider p = provider();
      await say(p, '今晚的月亮真美啊，你不觉得吗？', 'zh');
      await p.dispose();
      expect(speechBodies().single, <String, Object?>{
        'model': cosy,
        'input': '今晚的月亮真美啊，你不觉得吗？',
        'language': 'zh',
        'reference': <String, Object?>{'voice_id': voiceId},
        'reference_text': transcript,
        'response_format': 'wav',
        'audio_options': <String, Object?>{'template_name': 'cross_lingual'},
      });
    },
  );

  test('Japanese sentence with a Japanese voice uses zero_shot', () async {
    final TtsProvider p = provider();
    await say(p, '今夜は月がとても綺麗ですね。', 'ja');
    await say(p, 'The moon is beautiful tonight.', 'en');
    await p.dispose();
    final List<Map<String, Object?>?> bodies = speechBodies();
    expect(bodies[0]?['language'], 'ja');
    expect(bodies[0]?['audio_options'], <String, Object?>{
      'template_name': 'zero_shot',
    });
    expect(bodies[1]?['language'], 'en');
    expect(bodies[1]?['audio_options'], <String, Object?>{
      'template_name': 'cross_lingual',
    });
    // 声音信息一个实例只取一次。
    expect(log.where((e) => e.path == '/v1/audio/voices'), hasLength(1));
  });

  test('a fixed language overrides detection (Spanish profile)', () async {
    final TtsProvider p = provider(language: 'es');
    await say(p, 'La luna está preciosa esta noche.', 'es');
    await p.dispose();
    expect(speechBodies().single?['language'], 'es');
  });

  test('unset model is omitted; non-CosyVoice models get no template', () {
    const UnslothVoice v = (id: 'v', name: 'v', transcript: '', language: 'ja');
    final Map<String, Object?> resident = unslothSpeechRequest(
      text: 'hello',
      voice: v,
      model: '',
      language: 'auto',
    );
    expect(resident.containsKey('model'), isFalse);
    expect(resident.containsKey('reference_text'), isFalse);
    expect(resident['audio_options'], isNotNull);
    final Map<String, Object?> qwen = unslothSpeechRequest(
      text: 'hello',
      voice: v,
      model: 'audio-cpp/audio.cpp-gguf/Qwen3-TTS-12Hz-0.6B-Base-GGUF',
      language: 'auto',
    );
    expect(qwen.containsKey('audio_options'), isFalse);
  });

  test('language detection: kana → ja, Chinese characters → zh, else en', () {
    expect(unslothDetectLanguage('赤い傘。'), 'ja');
    expect(unslothDetectLanguage('カタカナ'), 'ja');
    expect(unslothDetectLanguage('今天晚上的月亮好美喔。'), 'zh');
    expect(unslothDetectLanguage('Hello there.'), 'en');
  });

  test('template: unknown voice language falls back to cross_lingual', () {
    expect(
      unslothTemplateFor(textLanguage: 'ja', voiceLanguage: 'ja-JP'),
      'zero_shot',
    );
    expect(
      unslothTemplateFor(textLanguage: 'ja', voiceLanguage: ''),
      'cross_lingual',
    );
  });

  test('voice deleted in Studio is rejected, and retried next time', () async {
    voiceDeleted = true;
    final TtsProvider p = provider();
    await expectLater(
      say(p, '你好。', 'a'),
      throwsA(
        isA<TtsFailure>().having(
          (TtsFailure f) => f.code,
          'code',
          TtsFailureCode.rejected,
        ),
      ),
    );
    voiceDeleted = false;
    await say(p, '你好。', 'b');
    await p.dispose();
    expect(log.where((e) => e.path == '/v1/audio/voices'), hasLength(2));
    expect(speechBodies(), hasLength(1));
  });

  test('wrong API key surfaces as unauthorized', () async {
    final TtsProvider p = provider(apiKey: 'nope');
    await expectLater(
      p.listParamOptions(UnslothStudioTtsDescriptor.voiceKey),
      throwsA(
        isA<TtsFailure>().having(
          (TtsFailure f) => f.code,
          'code',
          TtsFailureCode.unauthorized,
        ),
      ),
    );
    await p.dispose();
  });

  test(
    'missing voice is notConfigured; validate wants key and voice',
    () async {
      final TtsProvider p = provider(voice: ' ');
      await expectLater(
        say(p, 'x', 'a'),
        throwsA(
          isA<TtsFailure>().having(
            (TtsFailure f) => f.code,
            'code',
            TtsFailureCode.notConfigured,
          ),
        ),
      );
      await p.dispose();
      expect(
        const UnslothStudioTtsDescriptor().validate(
          const TtsVoicePreset(
            id: 'p',
            providerId: UnslothStudioTtsDescriptor.providerId,
            name: 'p',
          ),
        ),
        <String>[
          UnslothStudioTtsDescriptor.apiKeyKey,
          UnslothStudioTtsDescriptor.voiceKey,
        ],
      );
    },
  );

  test('cache identity: host, port, model, voice, language — not the key', () {
    final Map<String, Object?> id = const UnslothStudioTtsDescriptor()
        .audioIdentity(
          const TtsVoicePreset(
            id: 'p',
            providerId: UnslothStudioTtsDescriptor.providerId,
            name: 'p',
            params: <String, String>{
              UnslothStudioTtsDescriptor.endpointKey: 'http://192.168.1.5:9000',
              UnslothStudioTtsDescriptor.modelKey: cosy,
              UnslothStudioTtsDescriptor.voiceKey: voiceId,
              UnslothStudioTtsDescriptor.languageKey: 'zh',
            },
            secrets: <String, String>{
              UnslothStudioTtsDescriptor.apiKeyKey: key,
            },
          ),
        );
    expect(id['host'], '192.168.1.5');
    expect(id['port'], 9000);
    expect(id[UnslothStudioTtsDescriptor.modelKey], cosy);
    expect(id[UnslothStudioTtsDescriptor.voiceKey], voiceId);
    expect(id[UnslothStudioTtsDescriptor.languageKey], 'zh');
    expect(id.containsKey(UnslothStudioTtsDescriptor.apiKeyKey), isFalse);
  });
}
