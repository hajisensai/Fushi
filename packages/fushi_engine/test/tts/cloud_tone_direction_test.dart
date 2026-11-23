import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/providers/azure_tts_provider.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/google_cloud_tts_provider.dart';
import 'package:fushi_engine/tts/providers/openai_compatible_tts_provider.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

/// 逐句语气进入四个在线 / 兼容引擎：OpenAI 兼容（instructions + speed）、Azure
/// （express-as + prosody）、Edge（prosody）、Google Cloud（audioConfig）。
void main() {
  const TtsDirection sadStrong = TtsDirection(
    emotion: CastEmotion.sadness,
    intensity: 80,
    tone: 'おずおずと',
  );

  group('Edge', () {
    test('empty direction: SSML unchanged', () {
      expect(
        edgeTtsSsml(
          voice: 'ja-JP-NanamiNeural',
          text: 'a&b',
          direction: TtsDirection.none,
        ),
        "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
        "xml:lang='en-US'><voice name='ja-JP-NanamiNeural'>"
        "<prosody pitch='+0Hz' rate='+0%' volume='+0%'>"
        'a&amp;b</prosody></voice></speak>',
      );
    });

    test('declares only rate / pitch / volume; emotion folds', () {
      final EdgeTtsProvider p = EdgeTtsProvider(
        voice: 'ja-JP-NanamiNeural',
        host: const TtsHost(),
      );
      final TtsDirectionSupport s = p.directionSupport;
      expect(
        (s.emotion, s.tone, s.rate, s.pitch, s.volume),
        (false, false, true, true, true),
      );
      final TtsDirection d = effectiveTtsDirection(s, sadStrong);
      expect(d.emotion, isNull);
      expect(d.tone, isNull);
      // 悲伤强度 80：-0.096 语速、-1.2 半音、-1.6 dB。
      expect(microsoftProsodyOf(d), (
        rate: '-10%',
        pitch: '-7%',
        volume: '-17%',
      ));
    });

    test('prosody mapping: percent conversions and clamps', () {
      expect(
        microsoftProsodyOf(
          const TtsDirection(
            rateOffset: 0.12,
            pitchOffset: 2,
            volumeOffset: -6,
          ),
        ),
        (rate: '+12%', pitch: '+12%', volume: '-50%'),
      );
      // 只有语速：音高沿用 +0Hz，音量 +0%。
      expect(microsoftProsodyOf(const TtsDirection(rateOffset: -0.5)), (
        rate: '-50%',
        pitch: '+0Hz',
        volume: '+0%',
      ));
      // 音高夹到 0.5..1.5 倍。
      expect(
        microsoftProsodyOf(const TtsDirection(pitchOffset: 12))!.pitch,
        '+50%',
      );
      expect(
        microsoftProsodyOf(const TtsDirection(pitchOffset: -12))!.pitch,
        '-50%',
      );
      expect(microsoftProsodyOf(TtsDirection.none), isNull);
      expect(
        edgeTtsSsml(
          voice: 'v',
          text: 't',
          direction: const TtsDirection(rateOffset: 0.2),
        ),
        contains("<prosody pitch='+0Hz' rate='+20%' volume='+0%'>t</prosody>"),
      );
    });
  });

  group('Azure', () {
    test('empty direction: SSML unchanged', () {
      expect(
        azureTtsSsml(
          voice: 'ja-JP-NanamiNeural',
          text: '<x>',
          direction: TtsDirection.none,
          voiceStyles: const <String>{'cheerful'},
        ),
        "<speak version='1.0' xml:lang='ja-JP'>"
        "<voice name='ja-JP-NanamiNeural'>&lt;x&gt;</voice></speak>",
      );
    });

    test('emotion with a matching style: express-as + styledegree', () {
      final String ssml = azureTtsSsml(
        voice: 'ja-JP-NanamiNeural',
        text: 'やった',
        direction: const TtsDirection(
          emotion: CastEmotion.joy,
          intensity: 75,
          rateOffset: 0.1,
        ),
        voiceStyles: const <String>{'chat', 'cheerful', 'customerservice'},
      );
      expect(
        ssml,
        "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
        "xmlns:mstts='https://www.w3.org/2001/mstts' xml:lang='ja-JP'>"
        "<voice name='ja-JP-NanamiNeural'>"
        "<mstts:express-as style='cheerful' styledegree='1.5'>"
        "<prosody rate='+10%' pitch='+0Hz' volume='+0%'>やった</prosody>"
        '</mstts:express-as></voice></speak>',
      );
    });

    test('medium intensity omits styledegree; degree clamps', () {
      expect(
        azureTtsSsml(
          voice: 'zh-CN-XiaoxiaoNeural',
          text: 't',
          direction: const TtsDirection(emotion: CastEmotion.sadness),
          voiceStyles: const <String>{'sad'},
        ),
        contains("<mstts:express-as style='sad'>t</mstts:express-as>"),
      );
      expect(azureStyleDegree(0), 0.01);
      expect(azureStyleDegree(100), 2.0);
      expect(azureStyleDegree(25), 0.5);
    });

    test('voice without a matching style: never sends it, folds instead', () {
      final String ssml = azureTtsSsml(
        voice: 'ja-JP-KeitaNeural',
        text: 't',
        direction: const TtsDirection(
          emotion: CastEmotion.sadness,
          intensity: 100,
        ),
        voiceStyles: const <String>{'cheerful'},
      );
      expect(ssml, isNot(contains('express-as')));
      // 悲伤强度 100：-12% 语速、-1.5 半音（≈ -8%）、-2 dB（≈ -21%）。
      expect(
        ssml,
        contains("<prosody rate='-12%' pitch='-8%' volume='-21%'>t</prosody>"),
      );
      // 惊讶 / 紧张没有对应风格，一律折算。
      expect(
        azureStyleFor(CastEmotion.surprise, const <String>{'excited'}),
        isNull,
      );
      expect(
        azureStyleFor(CastEmotion.tenderness, const <String>{'gentle'}),
        'gentle',
      );
    });

    test('StyleList is read for the configured voice only', () {
      final Object raw = <Object?>[
        <String, Object?>{
          'ShortName': 'ja-JP-NanamiNeural',
          'Locale': 'ja-JP',
          'StyleList': <Object?>['chat', 'cheerful', 'customerservice'],
        },
        <String, Object?>{'ShortName': 'ja-JP-KeitaNeural', 'Locale': 'ja-JP'},
      ];
      expect(parseMicrosoftVoiceStyles(raw, 'ja-JP-NanamiNeural'), <String>{
        'chat',
        'cheerful',
        'customerservice',
      });
      expect(parseMicrosoftVoiceStyles(raw, 'ja-JP-KeitaNeural'), isEmpty);
      expect(parseMicrosoftVoiceStyles(null, 'x'), isEmpty);
    });

    test('declares native emotion and prosody, no tone', () {
      final AzureTtsProvider p = AzureTtsProvider(
        region: 'japaneast',
        apiKey: 'k',
        voice: 'ja-JP-NanamiNeural',
        host: const TtsHost(),
      );
      final TtsDirectionSupport s = p.directionSupport;
      expect(
        (s.emotion, s.tone, s.rate, s.pitch, s.volume),
        (true, false, true, true, true),
      );
      final TtsDirection d = effectiveTtsDirection(s, sadStrong);
      expect(d.emotion, CastEmotion.sadness);
      expect(d.intensity, 80);
      expect(d.tone, isNull);
      expect(d.rateOffset, isNull);
    });
  });

  group('Google Cloud', () {
    test('empty direction: request body unchanged', () {
      expect(
        googleCloudSynthesizeRequest(
          text: 't',
          voice: 'ja-JP-Neural2-B',
          direction: TtsDirection.none,
        ),
        <String, Object?>{
          'input': <String, Object?>{'text': 't'},
          'voice': <String, Object?>{
            'languageCode': 'ja-JP',
            'name': 'ja-JP-Neural2-B',
          },
          'audioConfig': <String, Object?>{
            'audioEncoding': 'LINEAR16',
            'sampleRateHertz': 24000,
          },
        },
      );
    });

    test('prosody mapping and legal-range clamps', () {
      final Map<String, Object?> body = googleCloudSynthesizeRequest(
        text: 't',
        voice: 'ja-JP-Neural2-B',
        direction: const TtsDirection(
          rateOffset: -0.12,
          pitchOffset: -1.5,
          volumeOffset: 12,
        ),
      );
      expect(body['audioConfig'], <String, Object?>{
        'audioEncoding': 'LINEAR16',
        'sampleRateHertz': 24000,
        'speakingRate': 0.88,
        'pitch': -1.5,
        'volumeGainDb': 10.0,
      });
      final Map<String, Object?> fast = googleCloudSynthesizeRequest(
        text: 't',
        voice: 'v',
        direction: const TtsDirection(rateOffset: 1.0),
      );
      expect(
        (fast['audioConfig']! as Map<String, Object?>)['speakingRate'],
        2.0,
      );
    });

    test('support depends on voice family; emotion folds', () {
      final TtsDirectionSupport classic = googleCloudDirectionSupport(
        'ja-JP-Wavenet-A',
      );
      expect(
        (classic.emotion, classic.rate, classic.pitch, classic.volume),
        (false, true, true, true),
      );
      final TtsDirectionSupport chirp = googleCloudDirectionSupport(
        'ja-JP-Chirp3-HD-Aoede',
      );
      expect((chirp.rate, chirp.pitch, chirp.volume), (true, false, false));
      final TtsDirection folded = effectiveTtsDirection(chirp, sadStrong);
      expect(folded.emotion, isNull);
      expect(folded.pitchOffset, isNull);
      expect(folded.rateOffset, closeTo(-0.096, 1e-9));
      final GoogleCloudTtsProvider p = GoogleCloudTtsProvider(
        apiKey: 'k',
        voice: 'ja-JP-Neural2-B',
        host: const TtsHost(),
      );
      expect(p.directionSupport.pitch, isTrue);
    });
  });

  group('OpenAI compatible', () {
    test('empty direction: request body unchanged', () {
      expect(
        openAiCompatibleSpeechRequest(text: 't', voice: ' v ', model: 'm'),
        <String, Object?>{
          'model': 'm',
          'input': 't',
          'voice': 'v',
          'response_format': 'wav',
        },
      );
    });

    test('instructions from emotion + tone, speed from rate', () {
      expect(
        openAiCompatibleSpeechRequest(
          text: 't',
          voice: 'v',
          model: 'gpt-4o-mini-tts',
          direction: const TtsDirection(
            emotion: CastEmotion.sadness,
            intensity: 80,
            tone: 'おずおずと',
            rateOffset: -0.1,
          ),
        ),
        <String, Object?>{
          'model': 'gpt-4o-mini-tts',
          'input': 't',
          'voice': 'v',
          'response_format': 'wav',
          'instructions': '感情：悲しげ（強く）。話し方：おずおずと。',
          'speed': 0.9,
        },
      );
    });

    late HttpServer server;
    late Directory tmp;
    late List<Map<String, Object?>> bodies;
    setUp(() async {
      bodies = <Map<String, Object?>>[];
      tmp = await Directory.systemTemp.createTemp('openai_tone_test');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        final String text = await utf8.decodeStream(req);
        if (text.isNotEmpty) {
          bodies.add(jsonDecode(text) as Map<String, Object?>);
        }
        req.response.add(buildWav(dataBytes: 320));
        await req.response.close();
      });
    });
    tearDown(() async {
      await server.close(force: true);
      await tmp.delete(recursive: true);
    });

    TtsProvider make({String? delivery}) =>
        const OpenAiCompatibleTtsDescriptor().create(
          TtsVoicePreset(
            id: 'p',
            providerId: OpenAiCompatibleTtsDescriptor.providerId,
            name: 'p',
            params: <String, String>{
              OpenAiCompatibleTtsDescriptor.endpointKey:
                  'http://127.0.0.1:${server.port}',
              OpenAiCompatibleTtsDescriptor.modelKey: 'gpt-4o-mini-tts',
              OpenAiCompatibleTtsDescriptor.voiceKey: 'coral',
              if (delivery != null)
                OpenAiCompatibleTtsDescriptor.deliveryInstructionsKey: delivery,
            },
          ),
          const TtsHost(),
        );

    Future<void> speak(TtsProvider p, TtsDirection wanted) =>
        synthesizeWithDirection(
          p,
          't',
          outputPath: '${tmp.path}${Platform.pathSeparator}a.wav',
          cancel: TtsCancelToken(),
          direction: effectiveTtsDirection(ttsDirectionSupportOf(p), wanted),
        );

    test('default on: instructions sent end to end', () async {
      final TtsProvider p = make();
      final TtsDirectionSupport s = ttsDirectionSupportOf(p);
      expect(
        (s.emotion, s.tone, s.rate, s.pitch, s.volume),
        (true, true, true, false, false),
      );
      await speak(p, sadStrong);
      await speak(p, TtsDirection.none);
      await p.dispose();
      expect(bodies.first['instructions'], '感情：悲しげ（強く）。話し方：おずおずと。');
      expect(bodies.first.containsKey('speed'), isFalse);
      expect(bodies.last.keys, <String>[
        'model',
        'input',
        'voice',
        'response_format',
      ]);
    });

    test('switched off: no instructions, emotion folds into speed', () async {
      final TtsProvider p = make(
        delivery: OpenAiCompatibleTtsDescriptor.deliveryOff,
      );
      final TtsDirectionSupport s = ttsDirectionSupportOf(p);
      expect((s.emotion, s.tone, s.rate), (false, false, true));
      await speak(p, sadStrong);
      await p.dispose();
      expect(bodies.single.containsKey('instructions'), isFalse);
      // 悲伤强度 80 → 语速 -0.096 → speed 0.9。
      expect(bodies.single['speed'], 0.9);
    });

    test('switch does not enter the audio identity', () {
      TtsVoicePreset preset(String v) => TtsVoicePreset(
        id: 'p',
        providerId: OpenAiCompatibleTtsDescriptor.providerId,
        name: 'p',
        params: <String, String>{
          OpenAiCompatibleTtsDescriptor.voiceKey: 'coral',
          OpenAiCompatibleTtsDescriptor.deliveryInstructionsKey: v,
        },
      );
      const OpenAiCompatibleTtsDescriptor d = OpenAiCompatibleTtsDescriptor();
      expect(
        d.audioIdentity(preset(OpenAiCompatibleTtsDescriptor.deliveryOn)),
        d.audioIdentity(preset(OpenAiCompatibleTtsDescriptor.deliveryOff)),
      );
    });
  });
}
