import 'dart:convert';

import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/local/irodori_batch_worker.dart';
import 'package:fushi_engine/tts/local/irodori_batch_worker_script.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack_provider.dart';
import 'package:fushi_engine/tts/providers/irodori_server_tts_provider.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:test/test.dart';

const TtsDirection _sad = TtsDirection(
  seed: 7,
  emotion: CastEmotion.sadness,
  intensity: 90,
  rateOffset: 0.2,
  pitchOffset: 2,
  volumeOffset: -3,
  tone: 'おずおずと',
);

const String _sadInstruction = '感情：悲しげ（強く）。話し方：おずおずと。';

IrodoriBatchItem _item({double? seconds}) => IrodoriBatchItem(
  id: 'x',
  text: 'うん',
  refs: const <String>['/r/a.wav'],
  outputPath: '/o/x.wav',
  seconds: seconds,
  seed: 3,
);

void main() {
  group('官方服务 irodori.caption / speed', () {
    test('没有演出参数：请求体与以前逐字节相同', () {
      final Map<String, Object?> plain = irodoriServerSpeechRequest(
        text: 'あ',
        voice: 'v',
        caption: ' 落ち着いた女性 ',
      );
      expect(
        jsonEncode(plain),
        '{"model":"irodori-tts","input":"あ","voice":"v",'
        '"response_format":"wav","irodori":{"caption":"落ち着いた女性"}}',
      );
      expect(
        jsonEncode(irodoriServerSpeechRequest(text: 'あ', voice: 'none')),
        '{"model":"irodori-tts","input":"あ","voice":"none",'
        '"response_format":"wav"}',
      );
    });

    test('能力：情绪 + 语气说明原生、语速走 speed；音高 / 音量 / 种子不声明、不折算', () {
      final TtsDirection d = effectiveTtsDirection(
        kIrodoriServerDirectionSupport,
        _sad,
      );
      expect(d.emotion, CastEmotion.sadness);
      expect(d.tone, 'おずおずと');
      expect(d.rateOffset, closeTo(0.2, 1e-9)); // 情绪原生表达，不再折进语速
      expect(d.pitchOffset, isNull);
      expect(d.volumeOffset, isNull);
      expect(d.seed, isNull);
    });

    test('情绪 + 语气说明接在预设 caption 后面，语速偏移变成 speed', () {
      final TtsDirection d = effectiveTtsDirection(
        kIrodoriServerDirectionSupport,
        _sad,
      );
      expect(
        irodoriServerSpeechRequest(
          text: 'あ',
          voice: 'v',
          caption: '落ち着いた女性',
          direction: d,
        ),
        <String, Object?>{
          'model': 'irodori-tts',
          'input': 'あ',
          'voice': 'v',
          'response_format': 'wav',
          'speed': 1.2,
          'irodori': <String, Object?>{'caption': '落ち着いた女性。$_sadInstruction'},
        },
      );
      // 没有预设 caption：只用指令。
      expect(
        irodoriServerSpeechRequest(
          text: 'あ',
          voice: 'v',
          direction: const TtsDirection(emotion: CastEmotion.joy),
        )['irodori'],
        <String, Object?>{'caption': '感情：嬉しそう。'},
      );
    });

    test('caption 拼接：已有句末标点不再补「。」；指令为空只留 caption', () {
      expect(irodoriCaptionWithDelivery('女性の声。', '感情：怒り。'), '女性の声。感情：怒り。');
      expect(irodoriCaptionWithDelivery('女性の声', '感情：怒り。'), '女性の声。感情：怒り。');
      expect(irodoriCaptionWithDelivery(' 女性の声 ', null), '女性の声');
      expect(irodoriCaptionWithDelivery('', ' '), '');
    });

    test('speed 换算：1 + rateOffset，夹到 0.25..4，0 不发', () {
      expect(irodoriServerSpeed(null), isNull);
      expect(irodoriServerSpeed(0), isNull);
      expect(irodoriServerSpeed(-0.5), 0.5);
      expect(irodoriServerSpeed(1.0), 2.0);
      expect(irodoriServerSpeed(0.0833333), 1.083);
      expect(irodoriServerSpeed(-0.9), 0.25);
      expect(irodoriServerSpeed(5), 4.0);
    });
  });

  group('声音包批处理 caption / duration_scale', () {
    const TtsVoicePreset preset = TtsVoicePreset(
      id: 'pack:a/main',
      providerId: kIrodoriPackProviderId,
      name: 'a',
    );

    test('能力：情绪 + 语气说明 + 语速（另有种子 / 时长），不声明音高 / 音量', () {
      final TtsDirectionSupport s = irodoriPackDirectionSupport(preset);
      expect(s.emotion, isTrue);
      expect(s.tone, isTrue);
      expect(s.rate, isTrue);
      expect(s.pitch, isFalse);
      expect(s.volume, isFalse);
      expect(s.seed, isTrue);
      expect(s.duration, isTrue);
    });

    test('没有演出参数：请求行与以前相同（不出现 caption / duration_scale）', () {
      final IrodoriBatchItem base = _item(seconds: 1.2);
      final Map<String, Object?> json = irodoriDirectedItem(
        base,
        TtsDirection.none,
      ).toJson();
      expect(json, base.toJson());
      expect(json.keys, <String>[
        'id',
        'text',
        'refs',
        'adapter',
        'seconds',
        'seed',
        'steps',
        'cfg_text',
        'cfg_speaker',
        'out',
      ]);
    });

    test('情绪 + 语气说明进 caption；语速缩放短句规则给的秒数', () {
      final TtsDirection d = effectiveTtsDirection(
        irodoriPackDirectionSupport(preset),
        _sad,
      );
      final IrodoriBatchItem item = irodoriDirectedItem(_item(seconds: 1.2), d);
      expect(item.caption, _sadInstruction);
      expect(item.seconds, closeTo(1.0, 1e-9)); // 1.2 / 1.2
      expect(item.durationScale, isNull);
      expect(item.seed, 7);
      final Map<String, Object?> json = item.toJson();
      expect(json['caption'], _sadInstruction);
      expect(json.containsKey('duration_scale'), isFalse);
    });

    test('走时长预测时语速变成 duration_scale = 1 / (1 + rateOffset)', () {
      final IrodoriBatchItem item = irodoriDirectedItem(
        _item(),
        const TtsDirection(rateOffset: -0.2),
      );
      expect(item.seconds, isNull);
      expect(item.durationScale, 1.25);
      expect(item.caption, isNull);
      expect(item.toJson()['duration_scale'], 1.25);
    });

    test('给定时长优先：不再按语速缩放', () {
      final IrodoriBatchItem item = irodoriDirectedItem(
        _item(seconds: 1.2),
        const TtsDirection(durationSeconds: 0.7, rateOffset: 0.5),
      );
      expect(item.seconds, 0.7);
      expect(item.durationScale, isNull);
    });

    test('worker 脚本把 caption / duration_scale 交给 SamplingRequest，协议升到 2', () {
      expect(kIrodoriBatchProtocol, 2);
      expect(
        kIrodoriBatchWorkerScript,
        contains('caption=item.get("caption") or None'),
      );
      expect(
        kIrodoriBatchWorkerScript,
        contains('duration_scale=float(item.get("duration_scale") or 1.0)'),
      );
    });
  });
}
