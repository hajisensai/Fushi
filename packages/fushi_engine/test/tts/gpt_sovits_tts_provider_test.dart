import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

class _Recorded {
  _Recorded(this.method, this.path, this.headers, this.body);
  final String method;
  final String path;
  final HttpHeaders headers;
  final String body;
}

void main() {
  late HttpServer server;
  late Directory tmp;
  final List<_Recorded> requests = <_Recorded>[];
  int status = 200;
  Completer<void>? hold;
  final TtsHost host = TtsHost(httpClientFactory: () => HttpClient());

  setUp(() async {
    requests.clear();
    status = 200;
    hold = null;
    tmp = await Directory.systemTemp.createTemp('tts_sovits_test_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      final String body = await utf8.decoder.bind(req).join();
      requests.add(_Recorded(req.method, req.uri.path, req.headers, body));
      if (hold != null) await hold!.future;
      req.response.statusCode = status;
      if (status == 200) {
        req.response.headers.contentType = ContentType('audio', 'wav');
        req.response.add(buildWav());
      } else {
        req.response.write('error body with secret-ish detail');
      }
      try {
        await req.response.close();
      } catch (_) {}
    });
  });

  tearDown(() async {
    if (hold != null && !hold!.isCompleted) hold!.complete();
    await server.close(force: true);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  String base() => 'http://127.0.0.1:${server.port}';

  TtsVoicePreset preset({
    String? endpoint,
    String ref = '/srv/ref.wav',
    String apiKey = '',
  }) => TtsVoicePreset(
    id: 'p',
    providerId: GptSovitsTtsDescriptor.providerId,
    name: 'n',
    params: <String, String>{
      GptSovitsTtsDescriptor.endpointKey: endpoint ?? base(),
      GptSovitsTtsDescriptor.refAudioKey: ref,
      GptSovitsTtsDescriptor.promptTextKey: 'こんにちは',
      GptSovitsTtsDescriptor.textLangKey: 'all_ja',
      GptSovitsTtsDescriptor.promptLangKey: 'ja',
    },
    secrets: <String, String>{
      if (apiKey.isNotEmpty) GptSovitsTtsDescriptor.apiKeyKey: apiKey,
    },
  );

  Future<TtsResult> synth(TtsVoicePreset preset, {TtsCancelToken? cancel}) async {
    final TtsProvider provider = const GptSovitsTtsDescriptor().create(
      preset,
      host,
    );
    try {
      return await provider.synthesize(
        '吾輩は猫である',
        outputPath: p.join(tmp.path, 'out.wav'),
        cancel: cancel ?? TtsCancelToken(),
      );
    } finally {
      await provider.dispose();
    }
  }

  Matcher failsWith(TtsFailureCode code) => throwsA(
    isA<TtsFailure>().having((TtsFailure f) => f.code, 'code', code),
  );

  group('ttsEndpointUri', () {
    test('normalises root, /tts, trailing slash, sub-path, query', () {
      String? n(String raw) =>
          GptSovitsTtsProvider.ttsEndpointUri(raw)?.toString();
      expect(n('http://h:9880'), 'http://h:9880/tts');
      expect(n('http://h:9880/'), 'http://h:9880/tts');
      expect(n('http://h:9880/tts'), 'http://h:9880/tts');
      expect(n('http://h:9880/tts/'), 'http://h:9880/tts');
      expect(n('  http://h:9880/api/// '), 'http://h:9880/api/tts');
      expect(n('http://h:9880/tts?x=1'), 'http://h:9880/tts');
      expect(n('https://u:p@h/x/#frag'), 'https://u:p@h/x/tts');
      expect(n('not a url'), isNull);
      expect(n(''), isNull);
    });
  });

  test('POSTs JSON body to /tts and writes the wav', () async {
    final TtsResult result = await synth(preset());
    expect(result.format, TtsAudioFormat.wav);
    expect(File(p.join(tmp.path, 'out.wav')).readAsBytesSync(), buildWav());
    final _Recorded r = requests.single;
    expect(r.method, 'POST');
    expect(r.path, '/tts');
    expect(r.headers.contentType?.mimeType, 'application/json');
    expect(r.headers.value(HttpHeaders.authorizationHeader), isNull);
    final Map<String, Object?> json =
        jsonDecode(r.body) as Map<String, Object?>;
    expect(json['text'], '吾輩は猫である');
    expect(json['text_lang'], 'all_ja');
    expect(json['ref_audio_path'], '/srv/ref.wav');
    expect(json['prompt_text'], 'こんにちは');
    expect(json['prompt_lang'], 'ja');
    expect(json['media_type'], 'wav');
    expect(json['streaming_mode'], false);
    expect(json['text_split_method'], 'cut0');
  });

  test('endpoint variants all hit /tts', () async {
    await synth(preset(endpoint: '${base()}/'));
    await synth(preset(endpoint: '${base()}/tts'));
    await synth(preset(endpoint: '${base()}/tts/'));
    expect(requests.map((_Recorded r) => r.path), <String>[
      '/tts',
      '/tts',
      '/tts',
    ]);
  });

  test('Bearer header only when api_key set', () async {
    await synth(preset(apiKey: ' sk-123 '));
    expect(
      requests.single.headers.value(HttpHeaders.authorizationHeader),
      'Bearer sk-123',
    );
  });

  test('status mapping', () async {
    status = 400;
    await expectLater(synth(preset()), failsWith(TtsFailureCode.rejected));
    status = 401;
    await expectLater(synth(preset()), failsWith(TtsFailureCode.unauthorized));
    status = 403;
    await expectLater(synth(preset()), failsWith(TtsFailureCode.unauthorized));
    status = 429;
    await expectLater(synth(preset()), failsWith(TtsFailureCode.rateLimited));
    status = 500;
    await expectLater(synth(preset()), failsWith(TtsFailureCode.serverError));
    expect(File(p.join(tmp.path, 'out.wav')).existsSync(), isFalse);
  });

  test('empty 200 body is badResponse', () async {
    await server.close(force: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      await req.drain<void>();
      await req.response.close();
    });
    await expectLater(synth(preset()), failsWith(TtsFailureCode.badResponse));
  });

  test('notConfigured when ref audio missing or endpoint invalid', () async {
    await expectLater(
      synth(preset(ref: '   ')),
      failsWith(TtsFailureCode.notConfigured),
    );
    await expectLater(
      synth(preset(endpoint: 'nonsense')),
      failsWith(TtsFailureCode.notConfigured),
    );
    expect(requests, isEmpty);
  });

  test('pre-cancelled token never sends', () async {
    final TtsCancelToken token = TtsCancelToken()..cancel();
    await expectLater(
      synth(preset(), cancel: token),
      failsWith(TtsFailureCode.cancelled),
    );
    expect(requests, isEmpty);
  });

  test('cancellation aborts an in-flight request', () async {
    hold = Completer<void>();
    final TtsCancelToken token = TtsCancelToken();
    final Future<TtsResult> future = synth(preset(), cancel: token);
    await waitFor(() => requests.isNotEmpty);
    token.cancel();
    await expectLater(
      future.timeout(const Duration(seconds: 5)),
      failsWith(TtsFailureCode.cancelled),
    );
  });

  test('connection refused is network', () async {
    final int port = server.port;
    await server.close(force: true);
    await expectLater(
      synth(preset(endpoint: 'http://127.0.0.1:$port')),
      failsWith(TtsFailureCode.network),
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });
}
