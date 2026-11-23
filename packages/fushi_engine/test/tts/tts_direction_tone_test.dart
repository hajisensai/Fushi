import 'package:fushi_engine/tts/cast/cast_line_direction.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:test/test.dart';

void main() {
  const TtsDirection sad = TtsDirection(
    seed: 7,
    emotion: CastEmotion.sadness,
    intensity: 100,
    rateOffset: 0.1,
    tone: 'おずおずと',
  );

  test('不支持语气的引擎：只留种子，缓存键与改动前一致', () {
    final TtsDirection d = effectiveTtsDirection(
      const TtsDirectionSupport(seed: true),
      sad,
    );
    expect(d.cacheIdentity, <String, Object?>{'seed': 7});
  });

  test('只能调韵律的引擎：情绪折进语速 / 音高 / 音量并与标注偏移相加', () {
    final TtsDirection d = effectiveTtsDirection(
      const TtsDirectionSupport(rate: true, pitch: true, volume: true),
      sad,
    );
    expect(d.emotion, isNull);
    expect(d.tone, isNull);
    // 0.1（标注）+ -0.12（悲伤 100）= -0.02
    expect(d.rateOffset, closeTo(-0.02, 1e-9));
    expect(d.pitchOffset, closeTo(-1.5, 1e-9));
    expect(d.volumeOffset, closeTo(-2, 1e-9));
  });

  test('强度线性缩放；中性情绪不产生偏移', () {
    final TtsProsodyOffsets half = ttsEmotionProsody(CastEmotion.joy, 50);
    expect(half.rate, closeTo(0.04, 1e-9));
    final TtsDirection neutral = effectiveTtsDirection(
      const TtsDirectionSupport(rate: true, pitch: true),
      const TtsDirection(emotion: CastEmotion.neutral, intensity: 100),
    );
    expect(neutral.isEmpty, isTrue);
  });

  test('原生表达情绪的引擎：情绪原样下发，不折成偏移', () {
    final TtsDirection d = effectiveTtsDirection(
      const TtsDirectionSupport(emotion: true, tone: true, rate: true),
      sad,
    );
    expect(d.emotion, CastEmotion.sadness);
    expect(d.intensity, 100);
    expect(d.rateOffset, closeTo(0.1, 1e-9));
    expect(d.tone, 'おずおずと');
    expect(ttsDeliveryInstruction(d), '感情：悲しげ（強く）。話し方：おずおずと。');
  });

  test('fromLine 把标注行的语气带进来，中性当作没标', () {
    final TtsDirection d = TtsDirection.fromLine(
      CastLineDirection.fromJson(<String, Object?>{
        'e': 'neutral',
        'ei': 80,
        'tone': '  必死に  ',
        'pitch': 2,
      }),
      seed: 1,
    );
    expect(d.emotion, isNull);
    expect(d.tone, '必死に');
    expect(d.pitchOffset, 2);
  });

  test('语气说明超长截断，JSON 往返保留', () {
    final CastLineDirection line = CastLineDirection.fromJson(<String, Object?>{
      'tone': 'あ' * 100,
    });
    expect(line.tone!.length, CastLineLimits.maxToneChars);
    expect(CastLineDirection.fromJson(line.toJson()).tone, line.tone);
  });

  test('拆句片段去掉时长、保留语气', () {
    const TtsDirection d = TtsDirection(
      durationSeconds: 1.2,
      emotion: CastEmotion.anger,
      tone: '強く',
    );
    final TtsDirection piece = d.withoutDuration();
    expect(piece.durationSeconds, isNull);
    expect(piece.emotion, CastEmotion.anger);
    expect(piece.tone, '強く');
  });
}
