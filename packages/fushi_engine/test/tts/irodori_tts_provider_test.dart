import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/irodori_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

void main() {
  late HttpServer server;
  late Directory tmp;
  final List<({String path, Object? body})> requests =
      <({String path, Object? body})>[];
  int status = 200;

  setUp(() async {
    requests.clear();
    status = 200;
    tmp = await Directory.systemTemp.createTemp('irodori_test');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      final String raw = await utf8.decoder.bind(req).join();
      requests.add((path: req.uri.path, body: raw.isEmpty ? null : jsonDecode(raw)));
      req.response.statusCode = status;
      if (req.uri.path == '/api/quick/voices') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{'id': 'v1', 'name': 'エミリア', 'trained': true, 'language': 'ja'},
            <String, Object?>{'id': 'v2', 'name': 'スバル', 'trained': false},
          ],
        }));
      } else if (status == 200) {
        req.response.add(buildWav(dataBytes: 3200));
      }
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  TtsProvider provider({String voice = 'v1'}) => const IrodoriTtsDescriptor().create(
        TtsVoicePreset(
          id: 'p',
          providerId: IrodoriTtsDescriptor.providerId,
          name: 'n',
          params: <String, String>{
            'endpoint': 'http://127.0.0.1:${server.port}/whatever',
            'voice': voice,
          },
        ),
        TtsHost(httpClientFactory: () => HttpClient()),
      );

  test('posts text and voice to /api/quick/speech', () async {
    final TtsProvider p = provider();
    final String out = '${tmp.path}/a.wav';
    final TtsResult r = await p.synthesize('こんにちは', outputPath: out, cancel: TtsCancelToken());
    expect(r.format, TtsAudioFormat.wav);
    expect(requests.single.path, '/api/quick/speech');
    expect(requests.single.body, <String, Object?>{'text': 'こんにちは', 'voice': 'v1'});
    expect(File(out).lengthSync(), greaterThan(44));
    await p.dispose();
  });

  test('409 means the studio is busy', () async {
    status = 409;
    final TtsProvider p = provider();
    await expectLater(
      p.synthesize('x', outputPath: '${tmp.path}/b.wav', cancel: TtsCancelToken()),
      throwsA(isA<TtsFailure>().having((TtsFailure f) => f.code, 'code', TtsFailureCode.busy)),
    );
    await p.dispose();
  });

  test('missing voice is not configured', () async {
    final TtsProvider p = provider(voice: '');
    await expectLater(
      p.synthesize('x', outputPath: '${tmp.path}/c.wav', cancel: TtsCancelToken()),
      throwsA(isA<TtsFailure>().having((TtsFailure f) => f.code, 'code', TtsFailureCode.notConfigured)),
    );
    await p.dispose();
  });

  test('lists studio voices', () async {
    final TtsProvider p = provider();
    final List<TtsVoice> voices = await p.listVoices();
    expect(voices.map((TtsVoice v) => v.id), <String>['v1', 'v2']);
    expect(voices.first.displayName, 'エミリア');
    expect(voices[1].locale, 'ja');
    await p.dispose();
  });

  test('audio identity separates studio ports but not hosts', () {
    Map<String, Object?> id(String endpoint) => const IrodoriTtsDescriptor().audioIdentity(
          TtsVoicePreset(
            id: 'p',
            providerId: 'irodori',
            name: 'n',
            params: <String, String>{'endpoint': endpoint, 'voice': 'v1'},
          ),
        );
    expect(id('http://127.0.0.1:7870'), id('http://192.168.1.2:7870'));
    expect(id('http://127.0.0.1:7870'), isNot(id('http://127.0.0.1:7871')));
  });
}
