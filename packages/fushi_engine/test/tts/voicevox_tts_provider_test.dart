import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fushi_engine/tts/providers/voicevox_tts_provider.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

class _Recorded {
  _Recorded(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final HttpHeaders headers;
  final String body;
}

const Map<String, Object?> _audioQuery = <String, Object?>{
  'accent_phrases': <Object?>[],
  'speedScale': 1.0,
  'pitchScale': 0.0,
  'intonationScale': 1.0,
  'volumeScale': 1.0,
  'prePhonemeLength': 0.1,
  'postPhonemeLength': 0.1,
  'outputSamplingRate': 24000,
  'outputStereo': false,
  'kana': 'ワガハイワ',
};

const List<Object?> _speakers = <Object?>[
  <String, Object?>{
    'name': '四国めたん',
    'speaker_uuid': 'u1',
    'styles': <Object?>[
      <String, Object?>{'name': 'ノーマル', 'id': 2, 'type': 'talk'},
      <String, Object?>{'name': 'あまあま', 'id': 0},
      <String, Object?>{'name': 'ハミング', 'id': 3001, 'type': 'humming'},
      <String, Object?>{'name': '歌', 'id': 3002, 'type': 'sing'},
      <String, Object?>{'name': '教師', 'id': 3003, 'type': 'singing_teacher'},
      <String, Object?>{'name': 'フレーム', 'id': 3004, 'type': 'frame_decode'},
    ],
  },
  <String, Object?>{
    'name': 'ずんだもん',
    'speaker_uuid': 'u2',
    'styles': <Object?>[
      <String, Object?>{'name': 'ノーマル', 'id': 3},
    ],
  },
];

void main() {
  late HttpServer server;
  late Directory tmp;
  final List<_Recorded> requests = <_Recorded>[];
  int synthesisStatus = 200;
  int queryStatus = 200;
  Completer<void>? hold;
  final TtsHost host = TtsHost(httpClientFactory: () => HttpClient());

  setUp(() async {
    requests.clear();
    synthesisStatus = 200;
    queryStatus = 200;
    hold = null;
    tmp = await Directory.systemTemp.createTemp('tts_voicevox_test_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      final String body = await utf8.decoder.bind(req).join();
      requests.add(_Recorded(req.method, req.uri, req.headers, body));
      final HttpResponse res = req.response;
      switch (req.uri.path) {
        case '/speakers':
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode(_speakers));
        case '/audio_query':
          res.statusCode = queryStatus;
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode(_audioQuery));
        case '/synthesis':
          if (hold != null) await hold!.future;
          res.statusCode = synthesisStatus;
          if (synthesisStatus == 200) {
            res.headers.contentType = ContentType('audio', 'wav');
            res.add(buildWav());
          }
        default:
          res.statusCode = 404;
      }
      try {
        await res.close();
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
    String providerId = VoicevoxTtsDescriptor.providerId,
    String? endpoint,
    String speaker = '2',
    Map<String, String> extra = const <String, String>{},
  }) => TtsVoicePreset(
    id: 'p',
    providerId: providerId,
    name: 'n',
    params: <String, String>{
      VoicevoxCompatibleTtsDescriptor.endpointKey: endpoint ?? base(),
      VoicevoxCompatibleTtsDescriptor.speakerKey: speaker,
      ...extra,
    },
  );

  Future<TtsResult> synth(
    TtsVoicePreset preset, {
    TtsCancelToken? cancel,
    String text = '吾輩は猫である',
  }) async {
    final TtsProvider provider = const VoicevoxTtsDescriptor().create(
      preset,
      host,
    );
    try {
      return await provider.synthesize(
        text,
        outputPath: p.join(tmp.path, 'out.wav'),
        cancel: cancel ?? TtsCancelToken(),
      );
    } finally {
      await provider.dispose();
    }
  }

  Matcher failsWith(TtsFailureCode code) =>
      throwsA(isA<TtsFailure>().having((TtsFailure f) => f.code, 'code', code));

  group('descriptors', () {
    test('three engines: own ids and default ports, same param table', () {
      const List<VoicevoxCompatibleTtsDescriptor> all =
          <VoicevoxCompatibleTtsDescriptor>[
            VoicevoxTtsDescriptor(),
            AivisSpeechTtsDescriptor(),
            SharevoxTtsDescriptor(),
          ];
      expect(all.map((VoicevoxCompatibleTtsDescriptor d) => d.id), <String>[
        'voicevox',
        'aivis_speech',
        'sharevox',
      ]);
      expect(
        all.map(
          (VoicevoxCompatibleTtsDescriptor d) => d.params.first.defaultValue,
        ),
        <String>[
          'http://127.0.0.1:50021',
          'http://127.0.0.1:10101',
          'http://127.0.0.1:50025',
        ],
      );
      for (final VoicevoxCompatibleTtsDescriptor d in all) {
        expect(d.capabilities.online, isFalse);
        expect(d.category, TtsProviderCategory.external);
        expect(d.params.map((TtsParamSpec s) => s.key), <String>[
          'endpoint',
          'speaker',
          'speed_scale',
          'pitch_scale',
          'intonation_scale',
          'volume_scale',
        ]);
        expect(d.params[0].affectsAudio, isFalse);
        expect(d.params[1].kind, TtsParamKind.voice);
      }
    });

    test('validate: speaker must be an int, scales must be numbers', () {
      const VoicevoxTtsDescriptor d = VoicevoxTtsDescriptor();
      expect(d.validate(preset(speaker: '')), <String>['speaker']);
      expect(d.validate(preset(speaker: 'abc')), <String>['speaker']);
      expect(d.validate(preset()), isEmpty);
      expect(
        d.validate(
          preset(
            extra: <String, String>{
              'speed_scale': '1.2',
              'pitch_scale': 'x',
              'volume_scale': ' ',
              'intonation_scale': 'NaN',
            },
          ),
        ),
        <String>['pitch_scale', 'intonation_scale'],
      );
    });

    test('audioIdentity: endpoint host out, port and scales in', () {
      const VoicevoxTtsDescriptor d = VoicevoxTtsDescriptor();
      final Map<String, Object?> a = d.audioIdentity(
        preset(endpoint: 'http://127.0.0.1:50021'),
      );
      final Map<String, Object?> b = d.audioIdentity(
        preset(endpoint: 'http://192.168.1.5:50021'),
      );
      final Map<String, Object?> c = d.audioIdentity(
        preset(endpoint: 'http://127.0.0.1:50080'),
      );
      expect(a, b);
      expect(a, isNot(c));
      expect(a['speaker'], '2');
      expect(
        d.audioIdentity(preset(extra: <String, String>{'speed_scale': '1.5'})),
        isNot(a),
      );
    });
  });

  test('parseVoicevoxSpeakers expands talk styles as "character / style"', () {
    final List<TtsVoice> voices = parseVoicevoxSpeakers(_speakers);
    expect(voices.map((TtsVoice v) => v.id), <String>['2', '0', '3']);
    expect(voices.first.displayName, '四国めたん / ノーマル');
    expect(voices.last.displayName, 'ずんだもん / ノーマル');
    expect(parseVoicevoxSpeakers(<String, Object?>{}), isEmpty);
  });

  test('parseVoicevoxSpeakers keeps streaming_talk styles (engine 0.26+)', () {
    // BUG-4503：VOICEVOX 0.26 的 /speakers 把默认角色的风格全报成
    // `streaming_talk`，只认 `talk` 时整张列表为空。
    final List<TtsVoice> voices = parseVoicevoxSpeakers(<Object?>[
      <String, Object?>{
        'name': 'ずんだもん',
        'speaker_uuid': '388f246b',
        'styles': <Object?>[
          <String, Object?>{'name': 'ノーマル', 'id': 3, 'type': 'streaming_talk'},
          <String, Object?>{'name': 'あまあま', 'id': 1, 'type': 'talk'},
          <String, Object?>{'name': '歌', 'id': 3003, 'type': 'sing'},
        ],
      },
    ]);
    expect(voices.map((TtsVoice v) => v.id), <String>['3', '1']);
    expect(voices.first.displayName, 'ずんだもん / ノーマル');
  });

  test('listVoices GETs /speakers (sub-path endpoint kept)', () async {
    final TtsProvider provider = const AivisSpeechTtsDescriptor().create(
      preset(endpoint: '${base()}/'),
      host,
    );
    try {
      final List<TtsVoice> voices = await provider.listVoices();
      expect(voices, hasLength(3));
      expect(requests.single.uri.path, '/speakers');
    } finally {
      await provider.dispose();
    }
  });

  test('audio_query then synthesis with the query as body', () async {
    final TtsResult result = await synth(preset());
    expect(result.format, TtsAudioFormat.wav);
    expect(File(p.join(tmp.path, 'out.wav')).readAsBytesSync(), buildWav());
    expect(requests, hasLength(2));
    final _Recorded q = requests[0];
    expect(q.method, 'POST');
    expect(q.uri.path, '/audio_query');
    expect(q.uri.queryParameters, <String, String>{
      'text': '吾輩は猫である',
      'speaker': '2',
    });
    expect(q.body, isEmpty);
    final _Recorded s = requests[1];
    expect(s.method, 'POST');
    expect(s.uri.path, '/synthesis');
    expect(s.uri.queryParameters, <String, String>{'speaker': '2'});
    expect(s.headers.contentType?.mimeType, 'application/json');
    expect(jsonDecode(s.body), _audioQuery);
  });

  test('non-empty scales override the audio_query fields', () async {
    await synth(
      preset(
        speaker: '3',
        extra: <String, String>{
          'speed_scale': ' 1.25 ',
          'pitch_scale': '-0.05',
          'intonation_scale': '',
          'volume_scale': '2',
        },
      ),
    );
    final Map<String, Object?> sent =
        jsonDecode(requests[1].body) as Map<String, Object?>;
    expect(sent['speedScale'], 1.25);
    expect(sent['pitchScale'], -0.05);
    expect(sent['intonationScale'], 1.0); // 空 = 引擎默认
    expect(sent['volumeScale'], 2.0);
    expect(sent['kana'], 'ワガハイワ'); // 其余字段原样带回
    expect(requests[1].uri.queryParameters['speaker'], '3');
  });

  test('notConfigured without a numeric speaker or a valid endpoint', () async {
    await expectLater(
      synth(preset(speaker: '')),
      failsWith(TtsFailureCode.notConfigured),
    );
    await expectLater(
      synth(preset(endpoint: 'nonsense')),
      failsWith(TtsFailureCode.notConfigured),
    );
    expect(requests, isEmpty);
  });

  test('status mapping on either request', () async {
    queryStatus = 422;
    await expectLater(synth(preset()), failsWith(TtsFailureCode.rejected));
    queryStatus = 200;
    synthesisStatus = 500;
    await expectLater(synth(preset()), failsWith(TtsFailureCode.serverError));
    synthesisStatus = 404;
    await expectLater(synth(preset()), failsWith(TtsFailureCode.rejected));
  });

  test('cancellation aborts an in-flight synthesis', () async {
    hold = Completer<void>();
    final TtsCancelToken token = TtsCancelToken();
    final Future<TtsResult> future = synth(preset(), cancel: token);
    await waitFor(
      () => requests.any((_Recorded r) => r.uri.path == '/synthesis'),
    );
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

  group('per-line direction', () {
    const double ln2 = 0.6931471805599453;

    // 两个有声 mora（ln F0 = 5.4 / 5.6，平均 5.5）+ 一个无声 mora（pitch 0，不计入）。
    final Map<String, Object?> query = <String, Object?>{
      ..._audioQuery,
      'accent_phrases': <Object?>[
        <String, Object?>{
          'moras': <Object?>[
            <String, Object?>{'text': 'ワ', 'pitch': 5.4},
            <String, Object?>{'text': 'ガ', 'pitch': 5.6},
            <String, Object?>{'text': 'ッ', 'pitch': 0.0},
          ],
          'pause_mora': null,
        },
      ],
    };

    double log2(double x) => math.log(x) / ln2;

    test('support: VOICEVOX / SHAREVOX native emotion, AivisSpeech rate + '
        'volume only', () {
      for (final VoicevoxCompatibleTtsDescriptor d
          in <VoicevoxCompatibleTtsDescriptor>[
            const VoicevoxTtsDescriptor(),
            const SharevoxTtsDescriptor(),
          ]) {
        final TtsDirectionSupport s = ttsDirectionSupportOf(
          d.create(preset(providerId: d.id), host),
        );
        expect(
          <bool>[s.emotion, s.rate, s.pitch, s.volume, s.tone, s.seed],
          <bool>[true, true, true, true, false, false],
          reason: d.id,
        );
      }
      final TtsDirectionSupport aivis = ttsDirectionSupportOf(
        const AivisSpeechTtsDescriptor().create(
          preset(providerId: AivisSpeechTtsDescriptor.providerId),
          host,
        ),
      );
      expect(
        <bool>[aivis.emotion, aivis.rate, aivis.pitch, aivis.volume],
        <bool>[false, true, false, true],
      );
    });

    test('empty direction leaves the query untouched', () {
      expect(
        identical(
          VoicevoxCompatibleTtsProvider.applyDirection(
            query,
            TtsDirection.none,
          ),
          query,
        ),
        isTrue,
      );
    });

    test('rate / volume multiply, pitch shifts mean ln(F0) by semitones', () {
      final Map<String, Object?> out =
          VoicevoxCompatibleTtsProvider.applyDirection(
            query,
            const TtsDirection(
              rateOffset: 0.2,
              pitchOffset: 2,
              volumeOffset: 6,
            ),
          );
      expect(out['speedScale'], 1.2);
      expect(out['volumeScale'], closeTo(1.9953, 1e-4));
      final double p = out['pitchScale']! as double;
      expect(p, closeTo(log2(1 + 2 * ln2 / 12 / 5.5), 1e-4));
      // 平均 ln(F0) 被抬高的量 = 2 个半音。
      expect(5.5 * math.pow(2, p) - 5.5, closeTo(2 * ln2 / 12, 1e-3));
      expect(out['intonationScale'], 1.0); // 没情绪不碰抑揚
      expect(out['kana'], 'ワガハイワ');
      expect(out['accent_phrases'], query['accent_phrases']);
    });

    test('stacks on the preset scales and clamps to the engine range', () {
      final Map<String, Object?> overridden =
          VoicevoxCompatibleTtsProvider.applyOverrides(query, <String, String>{
            'speedScale': '1.25',
            'pitchScale': '0.05',
            'volumeScale': '1.5',
          });
      final Map<String, Object?> out =
          VoicevoxCompatibleTtsProvider.applyDirection(
            overridden,
            const TtsDirection(
              rateOffset: 1.0,
              pitchOffset: -1,
              volumeOffset: 6,
            ),
          );
      expect(out['speedScale'], 2.0); // 1.25 × 2 = 2.5 → 夹到 2.0
      expect(out['volumeScale'], 2.0); // 1.5 × 1.995 → 夹到 2.0
      // 在预设的 0.05 上再降 1 个半音（不是替换成「-1 个半音」）。
      final double p = out['pitchScale']! as double;
      expect(p, closeTo(log2(math.pow(2, 0.05) - ln2 / 12 / 5.5), 1e-4));
      expect(p, lessThan(0.05));
      final Map<String, Object?> high =
          VoicevoxCompatibleTtsProvider.applyDirection(
            query,
            const TtsDirection(pitchOffset: 12),
          );
      expect(high['pitchScale'], 0.15);
    });

    test('native emotion: intonation plus folded rate / pitch / volume', () {
      final Map<String, Object?> sad =
          VoicevoxCompatibleTtsProvider.applyDirection(
            query,
            const TtsDirection(emotion: CastEmotion.sadness, intensity: 100),
          );
      expect(sad['intonationScale'], 0.7);
      expect(sad['speedScale'], 0.88);
      expect(sad['volumeScale'], closeTo(0.7943, 1e-4));
      expect(sad['pitchScale']! as double, lessThan(0));
      final Map<String, Object?> joy =
          VoicevoxCompatibleTtsProvider.applyDirection(
            query,
            const TtsDirection(
              emotion: CastEmotion.joy,
              intensity: 40,
              rateOffset: 0.1,
            ),
          );
      expect(joy['intonationScale'], 1.1); // 1 + 0.25 × 0.4
      expect(joy['speedScale'], closeTo(1.132, 1e-9)); // 1 + 0.1 + 0.08 × 0.4
      expect(joy['pitchScale']! as double, greaterThan(0));
    });

    Future<Map<String, Object?>> directed(
      VoicevoxCompatibleTtsDescriptor d,
      TtsDirection wanted,
    ) async {
      final TtsProvider provider = d.create(preset(providerId: d.id), host);
      try {
        await synthesizeWithDirection(
          provider,
          '吾輩は猫である',
          outputPath: p.join(tmp.path, 'out.wav'),
          cancel: TtsCancelToken(),
          direction: effectiveTtsDirection(
            ttsDirectionSupportOf(provider),
            wanted,
          ),
        );
      } finally {
        await provider.dispose();
      }
      return jsonDecode(requests.last.body) as Map<String, Object?>;
    }

    test('VOICEVOX end to end: the synthesis body carries the tone', () async {
      final Map<String, Object?> sent = await directed(
        const VoicevoxTtsDescriptor(),
        const TtsDirection(
          emotion: CastEmotion.anger,
          intensity: 100,
          tone: 'きつく',
          seed: 7,
        ),
      );
      expect(requests.map((_Recorded r) => r.uri.path), <String>[
        '/audio_query',
        '/synthesis',
      ]);
      expect(sent['intonationScale'], 1.3);
      expect(sent['speedScale'], 1.06);
      expect(sent['volumeScale'], closeTo(1.4125, 1e-4));
      // 测试的 audio_query 没有有声 mora：音高按缺省 ln(F0) 5.5 换算。
      expect(sent['pitchScale'], closeTo(log2(1 + 0.5 * ln2 / 12 / 5.5), 1e-4));
    });

    test('AivisSpeech end to end: emotion folds into speed / volume, '
        'pitch and intonation untouched', () async {
      final Map<String, Object?> sent = await directed(
        const AivisSpeechTtsDescriptor(),
        const TtsDirection(emotion: CastEmotion.sadness, intensity: 50),
      );
      expect(sent['speedScale'], 0.94);
      expect(sent['volumeScale'], closeTo(0.8913, 1e-4));
      expect(sent['pitchScale'], 0.0);
      expect(sent['intonationScale'], 1.0);
    });

    test('empty direction sends the same body as plain synthesize', () async {
      final Map<String, Object?> sent = await directed(
        const VoicevoxTtsDescriptor(),
        TtsDirection.none,
      );
      expect(sent, _audioQuery);
    });
  });
}
