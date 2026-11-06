import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/translate_tts_providers.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:test/test.dart';

/// 造一枚形如微软令牌的 JWT（只有 payload 有意义）。
String _jwt(DateTime exp, {String tag = 'c2ln'}) {
  String part(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part(<String, Object>{'alg': 'ES256'})}.'
      '${part(<String, Object>{'region': 'eastasia', 'exp': exp.millisecondsSinceEpoch ~/ 1000})}.'
      '$tag';
}

/// 本机假服务：令牌端点 + 合成端点 + 声音列表端点。
class _FakeTranslator {
  _FakeTranslator(this._server, this.now) {
    _server.listen(_handle);
  }

  static Future<_FakeTranslator> start(DateTime now) async =>
      _FakeTranslator(await HttpServer.bind('127.0.0.1', 0), now);

  final HttpServer _server;
  final DateTime now;

  int tokenRequests = 0;
  int tokenStatus = 200;
  final List<String> signatures = <String>[];
  final List<String> authorizations = <String>[];
  final List<String> ssmlBodies = <String>[];
  final List<String> outputFormats = <String>[];
  final List<String> speechContentTypes = <String>[];

  /// 依次消费的合成端状态码（空了就 200）。
  final List<int> speechStatuses = <int>[];

  Uri get tokenEndpoint => Uri.parse(
    'http://127.0.0.1:${_server.port}/apps/endpoint?api-version=1.0',
  );

  final List<String> regions = <String>[];

  Uri speechBase(String region) {
    regions.add(region);
    return Uri.http('127.0.0.1:${_server.port}');
  }

  Future<void> _handle(HttpRequest req) async {
    final String body = await utf8.decoder.bind(req).join();
    final HttpResponse res = req.response;
    switch (req.uri.path) {
      case '/apps/endpoint':
        tokenRequests++;
        signatures.add(
          '${req.method} ${req.headers.value('X-MT-Signature') ?? ''}',
        );
        res.statusCode = tokenStatus;
        if (tokenStatus == 200) {
          res.write(
            jsonEncode(<String, String>{
              'r': 'eastasia',
              't': _jwt(
                now.add(const Duration(minutes: 10)),
                tag: 'sig$tokenRequests',
              ),
            }),
          );
        }
      case '/cognitiveservices/v1':
        authorizations.add(req.headers.value('authorization') ?? '');
        ssmlBodies.add(body);
        outputFormats.add(req.headers.value('X-Microsoft-OutputFormat') ?? '');
        speechContentTypes.add(req.headers.contentType?.mimeType ?? '');
        final int status = speechStatuses.isEmpty
            ? 200
            : speechStatuses.removeAt(0);
        res.statusCode = status;
        if (status == 200) res.add(<int>[0xff, 0xf3, 0x64, 0xc4, 1, 2, 3]);
      case '/cognitiveservices/voices/list':
        authorizations.add(req.headers.value('authorization') ?? '');
        res.write(
          jsonEncode(<Object>[
            <String, String>{
              'ShortName': 'ja-JP-NanamiNeural',
              'LocalName': '七海',
              'Locale': 'ja-JP',
              'Gender': 'Female',
            },
          ]),
        );
      default:
        res.statusCode = 404;
    }
    await res.close();
  }

  Future<void> close() => _server.close(force: true);
}

Matcher _failsWith(TtsFailureCode code) =>
    throwsA(isA<TtsFailure>().having((TtsFailure f) => f.code, 'code', code));

void main() {
  group('MicrosoftTranslatorProtocol', () {
    test('signature matches the Translator client algorithm', () {
      // 期望值由独立的 Python 实现（hmac / quote_plus / strftime）算出。
      expect(
        MicrosoftTranslatorProtocol.signature(
          now: DateTime.fromMillisecondsSinceEpoch(
            1793806681 * 1000,
            isUtc: true,
          ),
          nonce: '0123456789abcdef0123456789abcdef',
        ),
        'MSTranslatorAndroidApp::v7bDzZld+Nnt1zBfh7LwR/fk7vH0kYFqKSq03o6jFtM='
        '::wed, 04 nov 2026 15:38:01 gmt::0123456789abcdef0123456789abcdef',
      );
    });

    test('http date is zero-padded RFC 1123 in UTC', () {
      expect(
        MicrosoftTranslatorProtocol.httpDate(DateTime.utc(2026, 3, 5, 7, 8, 9)),
        'Thu, 05 Mar 2026 07:08:09 GMT',
      );
    });

    final DateTime now = DateTime.utc(2026, 11, 4, 12);

    test('parses region, bearer and JWT expiry', () {
      final String bearer = _jwt(now.add(const Duration(minutes: 10)));
      final MicrosoftTranslatorToken token =
          MicrosoftTranslatorProtocol.parseToken(
            jsonEncode(<String, String>{'r': 'eastasia', 't': bearer}),
            now: now,
          );
      expect(token.region, 'eastasia');
      expect(token.bearer, bearer);
      expect(token.expiresAt, now.add(const Duration(minutes: 10)));
    });

    test('rejects malformed token responses instead of guessing', () {
      final String ok = _jwt(now.add(const Duration(minutes: 10)));
      for (final String body in <String>[
        'not json',
        '[]',
        jsonEncode(<String, String>{'t': ok}),
        // 区域要拼进主机名：带点 / 斜杠的一律拒。
        jsonEncode(<String, String>{'r': 'evil.com/x', 't': ok}),
        jsonEncode(<String, String>{'r': 'eastasia', 't': 'a.b'}),
        jsonEncode(<String, String>{'r': 'eastasia', 't': 'a b.c.d'}),
        jsonEncode(<String, String>{'r': 'eastasia', 't': 'a.!!!.c'}),
        jsonEncode(<String, String>{
          'r': 'eastasia',
          't': _jwt(now.subtract(const Duration(seconds: 1))),
        }),
      ]) {
        expect(
          () => MicrosoftTranslatorProtocol.parseToken(body, now: now),
          _failsWith(TtsFailureCode.badResponse),
          reason: body,
        );
      }
    });

    test('voice locale takes the first two segments', () {
      expect(microsoftVoiceLocale('ja-JP-NanamiNeural'), 'ja-JP');
      expect(microsoftVoiceLocale('yue-CN-XiaoMinNeural'), 'yue-CN');
      expect(microsoftVoiceLocale('weird'), 'ja-JP');
    });

    test('default endpoints point at the Translator / Speech hosts', () {
      expect(
        MicrosoftTranslatorProtocol.tokenEndpoint.toString(),
        'https://dev.microsofttranslator.com/apps/endpoint?api-version=1.0',
      );
      expect(
        microsoftTranslatorSpeechBase('eastasia').toString(),
        'https://eastasia.tts.speech.microsoft.com',
      );
    });
  });

  group('MicrosoftTranslatorTtsProvider against a local fake', () {
    late _FakeTranslator fake;
    late Directory tmp;
    final DateTime now = DateTime.utc(2026, 11, 4, 12);

    setUp(() async {
      fake = await _FakeTranslator.start(now);
      tmp = await Directory.systemTemp.createTemp('ms_translator_tts_');
    });

    tearDown(() async {
      await fake.close();
      await tmp.delete(recursive: true);
    });

    MicrosoftTranslatorSession session() => MicrosoftTranslatorSession(
      tokenEndpoint: fake.tokenEndpoint,
      clock: () => now,
    );

    MicrosoftTranslatorTtsProvider provider(MicrosoftTranslatorSession s) =>
        MicrosoftTranslatorTtsProvider(
          voice: 'ja-JP-NanamiNeural',
          host: TtsHost(httpClientFactory: () => HttpClient()),
          session: s,
          speechBase: fake.speechBase,
        );

    test(
      'signs the token request, then synthesizes MP3 with the bearer',
      () async {
        final MicrosoftTranslatorTtsProvider p = provider(session());
        final String out = '${tmp.path}/a.mp3';
        final TtsResult result = await p.synthesize(
          'こんにちは<世界>',
          outputPath: out,
          cancel: TtsCancelToken(),
        );
        expect(result.format, TtsAudioFormat.mp3);
        expect(File(out).readAsBytesSync().take(2), <int>[0xff, 0xf3]);
        expect(fake.tokenRequests, 1);
        expect(
          fake.signatures.single,
          matches(
            RegExp(
              r'^POST MSTranslatorAndroidApp::[A-Za-z0-9+/=]+::'
              r'[a-z]{3}, \d\d [a-z]{3} \d{4} \d\d:\d\d:\d\d gmt::[0-9a-f]{32}$',
            ),
          ),
        );
        expect(fake.regions, <String>['eastasia']);
        expect(fake.authorizations.single, startsWith('Bearer '));
        expect(fake.speechContentTypes.single, 'application/ssml+xml');
        expect(fake.outputFormats.single, 'audio-24khz-48kbitrate-mono-mp3');
        expect(fake.ssmlBodies.single, contains("name='ja-JP-NanamiNeural'"));
        expect(fake.ssmlBodies.single, contains('こんにちは&lt;世界&gt;'));
      },
    );

    test('reuses one token across sentences and concurrent calls', () async {
      final MicrosoftTranslatorTtsProvider p = provider(session());
      await Future.wait(<Future<TtsResult>>[
        for (int i = 0; i < 3; i++)
          p.synthesize(
            '文$i',
            outputPath: '${tmp.path}/$i.mp3',
            cancel: TtsCancelToken(),
          ),
      ]);
      await p.synthesize(
        '文',
        outputPath: '${tmp.path}/later.mp3',
        cancel: TtsCancelToken(),
      );
      expect(fake.tokenRequests, 1);
      expect(fake.authorizations.toSet().length, 1);
    });

    test(
      'a revoked token is replaced once; a second refusal surfaces',
      () async {
        final MicrosoftTranslatorTtsProvider p = provider(session());
        fake.speechStatuses.add(401);
        await p.synthesize(
          '文',
          outputPath: '${tmp.path}/r.mp3',
          cancel: TtsCancelToken(),
        );
        expect(fake.tokenRequests, 2);
        expect(fake.authorizations[0], isNot(fake.authorizations[1]));

        fake.speechStatuses.addAll(<int>[401, 401]);
        await expectLater(
          p.synthesize(
            '文',
            outputPath: '${tmp.path}/r2.mp3',
            cancel: TtsCancelToken(),
          ),
          _failsWith(TtsFailureCode.unauthorized),
        );
        expect(fake.tokenRequests, 3);
      },
    );

    test('a failing token endpoint reports a clear failure code', () async {
      fake.tokenStatus = 503;
      await expectLater(
        provider(session()).synthesize(
          '文',
          outputPath: '${tmp.path}/f.mp3',
          cancel: TtsCancelToken(),
        ),
        _failsWith(TtsFailureCode.serverError),
      );
      expect(File('${tmp.path}/f.mp3').existsSync(), isFalse);
    });

    test('rejected text is not retried with a new token', () async {
      fake.speechStatuses.add(400);
      await expectLater(
        provider(session()).synthesize(
          '文',
          outputPath: '${tmp.path}/b.mp3',
          cancel: TtsCancelToken(),
        ),
        _failsWith(TtsFailureCode.rejected),
      );
      expect(fake.tokenRequests, 1);
    });

    test('lists voices from the speech endpoint', () async {
      final List<TtsVoice> voices = await provider(session()).listVoices();
      expect(voices.single.id, 'ja-JP-NanamiNeural');
      expect(voices.single.locale, 'ja-JP');
      expect(fake.authorizations.single, startsWith('Bearer '));
    });
  });

  test('both translate voices are online, keyless and voice-selectable', () {
    for (final TtsProviderDescriptor d in const <TtsProviderDescriptor>[
      MicrosoftTranslatorTtsDescriptor(),
      GoogleTranslateTtsDescriptor(),
    ]) {
      expect(d.category, TtsProviderCategory.online);
      expect(d.capabilities.needsCredential, isFalse);
      expect(d.params.single.kind, TtsParamKind.voice, reason: d.id);
      expect(
        d.validate(TtsVoicePreset(id: 'p', providerId: d.id, name: 'n')),
        isEmpty,
        reason: 'defaults make it usable out of the box',
      );
    }
  });

  test('microsoft translator keeps its frozen provider id', () {
    expect(MicrosoftTranslatorTtsDescriptor.providerId, 'ms_translator');
  });

  test('google translate lists one voice per language, ja first', () async {
    final TtsProvider p = const GoogleTranslateTtsDescriptor().create(
      const TtsVoicePreset(id: 'p', providerId: 'google_translate', name: 'n'),
      const TtsHost(),
    );
    final List<TtsVoice> voices = await p.listVoices();
    expect(voices.first.id, 'ja');
    expect(voices.map((TtsVoice v) => v.id).toSet().length, voices.length);
    await p.dispose();
  });
}
