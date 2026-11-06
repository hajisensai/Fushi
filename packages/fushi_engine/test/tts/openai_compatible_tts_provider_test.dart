import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/openai_compatible_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

/// 通用 OpenAI 兼容语音接口：请求形状、model 留空时的探测、声音列表。形状取自本机
/// VPTTS 0.5.0（`/v1/models` 只有 `voicepeak`，别的 model 名回 400 unknown_model）。
void main() {
  late HttpServer server;
  late Directory tmp;
  late List<({String method, String path, Map<String, Object?>? json})> log;
  String modelsBody = '{"object":"list","data":[{"id":"voicepeak"}]}';
  int modelsStatus = 200;

  setUp(() async {
    log = <({String method, String path, Map<String, Object?>? json})>[];
    modelsBody = '{"object":"list","data":[{"id":"voicepeak"}]}';
    modelsStatus = 200;
    tmp = await Directory.systemTemp.createTemp('openai_compat_tts_test');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      final String text = await utf8.decodeStream(req);
      final Object? json = text.isEmpty ? null : jsonDecode(text);
      log.add((
        method: req.method,
        path: req.uri.path,
        json: json is Map<String, Object?> ? json : null,
      ));
      final HttpResponse res = req.response;
      switch ((req.method, req.uri.path)) {
        case ('GET', '/v1/models'):
          res.statusCode = modelsStatus;
          res.write(modelsBody);
        case ('GET', '/v1/audio/voices'):
          res.headers.contentType = ContentType.json;
          res.write(
            '{"object":"list","data":['
            '{"id":"asumi-shuo","name":"彩澄しゅお","language":"ja"},'
            '{"id":"plain"}]}',
          );
        case ('POST', '/v1/audio/speech'):
          final Object? model = json is Map ? json['model'] : null;
          if (model != 'voicepeak' && model != 'custom') {
            res.statusCode = 400;
            res.write('{"error":{"code":"unknown_model"}}');
          } else {
            res.add(buildWav(dataBytes: 3200));
          }
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

  TtsProvider provider({String model = '', String voice = 'asumi-shuo'}) =>
      const OpenAiCompatibleTtsDescriptor().create(
        TtsVoicePreset(
          id: 'p',
          providerId: OpenAiCompatibleTtsDescriptor.providerId,
          name: 'p',
          params: <String, String>{
            OpenAiCompatibleTtsDescriptor.endpointKey:
                'http://127.0.0.1:${server.port}/v1',
            OpenAiCompatibleTtsDescriptor.modelKey: model,
            OpenAiCompatibleTtsDescriptor.voiceKey: voice,
          },
        ),
        const TtsHost(),
      );

  Future<void> say(TtsProvider p, String name) => p.synthesize(
    '赤い傘。',
    outputPath: '${tmp.path}${Platform.pathSeparator}$name.wav',
    cancel: TtsCancelToken(),
  );

  test('empty model: uses the server\'s only model, probed once', () async {
    final TtsProvider p = provider();
    await say(p, 'a');
    await say(p, 'b');
    await p.dispose();
    expect(log.where((e) => e.path == '/v1/models'), hasLength(1));
    final List<Map<String, Object?>?> speech = <Map<String, Object?>?>[
      for (final e in log)
        if (e.path == '/v1/audio/speech') e.json,
    ];
    expect(speech, hasLength(2));
    expect(speech.first, <String, Object?>{
      'model': 'voicepeak',
      'input': '赤い傘。',
      'voice': 'asumi-shuo',
      'response_format': 'wav',
    });
  });

  test('explicit model is sent as-is without probing', () async {
    final TtsProvider p = provider(model: 'custom');
    await say(p, 'a');
    await p.dispose();
    expect(log.map((e) => e.path), <String>['/v1/audio/speech']);
    expect(log.single.json?['model'], 'custom');
  });

  test('no /v1/models (404) falls back to tts-1', () async {
    modelsStatus = 404;
    final TtsProvider p = provider();
    // 假服务只认 voicepeak / custom：tts-1 被拒，说明确实按回退名请求了。
    await expectLater(say(p, 'a'), throwsA(isA<TtsFailure>()));
    await p.dispose();
    expect(
      log.lastWhere((e) => e.path == '/v1/audio/speech').json?['model'],
      OpenAiCompatibleTtsDescriptor.fallbackModel,
    );
  });

  test('several models: falls back to tts-1 instead of guessing', () {
    expect(
      openAiCompatibleSoleModel(<String, Object?>{
        'data': <Object?>[
          <String, Object?>{'id': 'a'},
          <String, Object?>{'id': 'b'},
        ],
      }),
      isNull,
    );
  });

  test('missing voice is notConfigured', () async {
    final TtsProvider p = provider(voice: ' ');
    await expectLater(
      say(p, 'a'),
      throwsA(
        isA<TtsFailure>().having(
          (TtsFailure f) => f.code,
          'code',
          TtsFailureCode.notConfigured,
        ),
      ),
    );
    await p.dispose();
  });

  test('voices list shows name and id', () async {
    final TtsProvider p = provider();
    final List<TtsVoice> voices = await p.listVoices();
    await p.dispose();
    expect(
      <String>[for (final v in voices) v.id],
      <String>['asumi-shuo', 'plain'],
    );
    expect(voices.first.displayName, '彩澄しゅお（asumi-shuo）');
    expect(voices.first.locale, 'ja');
    expect(voices.last.displayName, 'plain');
  });

  test('cache identity includes host and port, not the api key', () {
    final Map<String, Object?>
    id = const OpenAiCompatibleTtsDescriptor().audioIdentity(
      const TtsVoicePreset(
        id: 'p',
        providerId: OpenAiCompatibleTtsDescriptor.providerId,
        name: 'p',
        params: <String, String>{
          OpenAiCompatibleTtsDescriptor.endpointKey: 'http://192.168.1.5:9000',
          OpenAiCompatibleTtsDescriptor.voiceKey: 'v',
        },
        secrets: <String, String>{OpenAiCompatibleTtsDescriptor.apiKeyKey: 'k'},
      ),
    );
    expect(id['host'], '192.168.1.5');
    expect(id['port'], 9000);
    expect(id.containsKey(OpenAiCompatibleTtsDescriptor.apiKeyKey), isFalse);
  });
}
