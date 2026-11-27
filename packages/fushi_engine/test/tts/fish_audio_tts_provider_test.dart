import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/fish_audio_tts_provider.dart';
import 'package:fushi_engine/tts/tts_builtin_providers.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

/// Fish Audio：请求形状（模型走请求头、语气走 prosody）、声音列表（自己的 + 公共库）、
/// 免费 / 付费档的失败码（余额为 0 → 402 → quotaExceeded）。响应形状取自官方文档
/// （docs.fish.audio，2026-11）。
void main() {
  const String key = 'fish-test-key';
  const String ownVoice = '0089dce5fefb4c6ba9b9f2f0debe1ddc';
  const String libraryVoice = '2e65f0bfcdb04895a97a825fdc8546f6';

  late HttpServer server;
  late Directory tmp;
  late List<_Call> log;
  late int ttsStatus;

  setUp(() async {
    log = <_Call>[];
    ttsStatus = 200;
    tmp = await Directory.systemTemp.createTemp('fish_tts_test');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      final String text = await utf8.decodeStream(req);
      final Object? json = text.isEmpty ? null : jsonDecode(text);
      final String? auth = req.headers.value(HttpHeaders.authorizationHeader);
      log.add((
        method: req.method,
        path: req.uri.path,
        query: req.uri.queryParameters,
        auth: auth,
        model: req.headers.value('model'),
        json: json is Map<String, Object?> ? json : null,
      ));
      final HttpResponse res = req.response;
      if (auth != 'Bearer $key') {
        res.statusCode = 401;
        await res.close();
        return;
      }
      switch ((req.method, req.uri.path)) {
        case ('POST', '/v1/tts'):
          res.statusCode = ttsStatus;
          if (ttsStatus == 200) {
            res.headers.contentType = ContentType('audio', 'mpeg');
            res.add(buildMp3(frames: 4));
          } else {
            res.headers.contentType = ContentType.json;
            res.write(
              jsonEncode(<String, Object?>{
                'status': ttsStatus,
                'message': 'Insufficient balance',
              }),
            );
          }
        case ('GET', '/model'):
          final bool own = req.uri.queryParameters['self'] == 'true';
          res.headers.contentType = ContentType.json;
          res.write(
            jsonEncode(<String, Object?>{
              'total': own ? 2 : 3,
              'items': own
                  ? <Object?>[
                      <String, Object?>{
                        '_id': ownVoice,
                        'type': 'tts',
                        'title': '落ち着いた女性',
                        'state': 'trained',
                        'languages': <String>['ja'],
                      },
                      <String, Object?>{
                        '_id': 'still-training',
                        'type': 'tts',
                        'title': 'Training',
                        'state': 'training',
                        'languages': <String>['ja'],
                      },
                    ]
                  : <Object?>[
                      <String, Object?>{
                        '_id': libraryVoice,
                        'type': 'tts',
                        'title': 'Waguri Kaoruko',
                        'state': 'trained',
                        'languages': <String>['ja', 'en'],
                      },
                      // 自己的声音也是公开的：公共库里再出现一次，只留一份。
                      <String, Object?>{
                        '_id': ownVoice,
                        'type': 'tts',
                        'title': '落ち着いた女性',
                        'state': 'trained',
                        'languages': <String>['ja'],
                      },
                      <String, Object?>{
                        '_id': 'voice-changer',
                        'type': 'svc',
                        'title': 'Voice changer',
                        'state': 'trained',
                      },
                    ],
            }),
          );
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

  Uri base() => Uri.parse('http://127.0.0.1:${server.port}');

  FishAudioTtsProvider provider({
    String apiKey = key,
    String model = FishAudioTtsDescriptor.freeModel,
    String voice = ownVoice,
  }) => FishAudioTtsProvider(
    apiKey: apiKey,
    model: model,
    voice: voice,
    host: const TtsHost(),
    apiBase: base(),
  );

  test('registered as a built-in online engine that needs a key', () {
    const FishAudioTtsDescriptor d = FishAudioTtsDescriptor();
    expect(
      kBuiltinTtsProviders.map((TtsProviderDescriptor p) => p.id),
      contains(FishAudioTtsDescriptor.providerId),
    );
    expect(d.category, TtsProviderCategory.online);
    expect(d.capabilities.needsCredential, isTrue);
    expect(
      d.validate(
        const TtsVoicePreset(
          id: 'p',
          name: 'Fish',
          providerId: FishAudioTtsDescriptor.providerId,
          params: <String, String>{},
        ),
      ),
      containsAll(<String>[
        FishAudioTtsDescriptor.apiKeyKey,
        FishAudioTtsDescriptor.voiceKey,
      ]),
    );
    final TtsParamSpec voice = d.params.firstWhere(
      (TtsParamSpec s) => s.key == FishAudioTtsDescriptor.voiceKey,
    );
    expect(voice.allowsCustomValue, isTrue);
  });

  test('model is part of the audio identity, the key is not', () {
    const FishAudioTtsDescriptor d = FishAudioTtsDescriptor();
    TtsVoicePreset preset(String model, String apiKey) => TtsVoicePreset(
      id: 'p',
      name: 'Fish',
      providerId: FishAudioTtsDescriptor.providerId,
      params: <String, String>{
        FishAudioTtsDescriptor.apiKeyKey: apiKey,
        FishAudioTtsDescriptor.modelKey: model,
        FishAudioTtsDescriptor.voiceKey: ownVoice,
      },
    );
    expect(
      d.audioIdentity(preset('s2.1-pro', 'a')),
      d.audioIdentity(preset('s2.1-pro', 'b')),
    );
    expect(
      d.audioIdentity(preset('s2.1-pro', 'a')),
      isNot(d.audioIdentity(preset('s1', 'a'))),
    );
  });

  test(
    'synthesizes with the model header and the voice as reference_id',
    () async {
      final TtsFishProbe out = TtsFishProbe(tmp);
      final TtsResult result = await provider().synthesize(
        'こんにちは。',
        outputPath: out.path,
        cancel: TtsCancelToken(),
      );
      expect(result.format, TtsAudioFormat.mp3);
      expect(File(out.path).lengthSync(), greaterThan(0));
      final _Call call = log.single;
      expect(call.path, '/v1/tts');
      expect(call.model, FishAudioTtsDescriptor.freeModel);
      expect(call.json, <String, Object?>{
        'text': 'こんにちは。',
        'reference_id': ownVoice,
        'format': 'mp3',
        'mp3_bitrate': 128,
        'latency': 'normal',
      });
    },
  );

  test('rate and volume offsets become prosody, clamped to the API range', () {
    expect(
      fishAudioSpeechRequest(
        text: 'a',
        voice: ownVoice,
        direction: const TtsDirection(rateOffset: -0.2, volumeOffset: 3),
      )['prosody'],
      <String, Object?>{'speed': 0.8, 'volume': 3.0},
    );
    expect(
      (fishAudioSpeechRequest(
            text: 'a',
            voice: ownVoice,
            direction: const TtsDirection(rateOffset: 5),
          )['prosody']!
          as Map<String, Object?>)['speed'],
      kFishAudioMaxSpeed,
    );
    // 情绪不原生：折成语速 / 音量后再进 prosody，音高被去掉。
    final TtsDirection folded = effectiveTtsDirection(
      provider().directionSupport,
      const TtsDirection(pitchOffset: 2, rateOffset: 0.1),
    );
    expect(folded.pitchOffset, isNull);
    expect(folded.rateOffset, closeTo(0.1, 1e-9));
  });

  test(
    'zero balance on a paid model reports quotaExceeded, not a bad key',
    () async {
      ttsStatus = 402;
      await expectLater(
        provider(model: FishAudioTtsDescriptor.defaultModel).synthesize(
          'こんにちは。',
          outputPath: TtsFishProbe(tmp).path,
          cancel: TtsCancelToken(),
        ),
        throwsA(
          isA<TtsFailure>()
              .having(
                (TtsFailure f) => f.code,
                'code',
                TtsFailureCode.quotaExceeded,
              )
              .having((TtsFailure f) => f.isTransient, 'transient', isFalse),
        ),
      );
    },
  );

  test('concurrency limit (429) is a transient rate limit', () async {
    ttsStatus = 429;
    await expectLater(
      provider().synthesize(
        'a',
        outputPath: TtsFishProbe(tmp).path,
        cancel: TtsCancelToken(),
      ),
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

  test('a wrong key is unauthorized', () async {
    await expectLater(
      provider(apiKey: 'wrong').synthesize(
        'a',
        outputPath: TtsFishProbe(tmp).path,
        cancel: TtsCancelToken(),
      ),
      throwsA(
        isA<TtsFailure>().having(
          (TtsFailure f) => f.code,
          'code',
          TtsFailureCode.unauthorized,
        ),
      ),
    );
  });

  test(
    'voices: own trained voices first, then the public library, no duplicates',
    () async {
      final List<TtsVoice> voices = await provider().listVoices();
      expect(voices.map((TtsVoice v) => v.id), <String>[
        ownVoice,
        libraryVoice,
      ]);
      expect(voices.first.displayName, '落ち着いた女性');
      expect(voices.first.locale, 'ja');
      final List<Map<String, String>> queries = <Map<String, String>>[
        for (final _Call c in log)
          if (c.path == '/model') c.query,
      ];
      expect(queries.first['self'], 'true');
      expect(queries.last.containsKey('self'), isFalse);
      expect(queries.last['page_size'], '$kFishAudioVoicePageSize');
    },
  );

  test('no key: not configured, nothing is sent', () async {
    await expectLater(
      provider(apiKey: ' ').synthesize(
        'a',
        outputPath: TtsFishProbe(tmp).path,
        cancel: TtsCancelToken(),
      ),
      throwsA(
        isA<TtsFailure>().having(
          (TtsFailure f) => f.code,
          'code',
          TtsFailureCode.notConfigured,
        ),
      ),
    );
    expect(log, isEmpty);
  });
}

typedef _Call = ({
  String method,
  String path,
  Map<String, String> query,
  String? auth,
  String? model,
  Map<String, Object?>? json,
});

/// 每次一个新的输出文件路径。
class TtsFishProbe {
  TtsFishProbe(Directory dir)
    : path = '${dir.path}${Platform.pathSeparator}${_n++}.mp3';

  static int _n = 0;
  final String path;
}
