import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart'
    show MicrosoftProsody, microsoftProsodyOf;
import 'package:fushi_engine/tts/providers/translate_tts_providers.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:test/test.dart';

void main() {
  const String voice = 'ja-JP-NanamiNeural';

  test('微软翻译：没有演出参数时 SSML 与以前逐字节相同', () {
    expect(
      MicrosoftTranslatorTtsProvider.ssml(voice, 'a<b'),
      "<speak version='1.0' xml:lang='ja-JP'>"
      "<voice xml:lang='ja-JP' name='ja-JP-NanamiNeural'>a&lt;b</voice></speak>",
    );
  });

  test('微软翻译：只声明语速 / 音高 / 音量，情绪折进 <prosody>', () {
    const TtsDirectionSupport s = kMicrosoftTranslatorDirectionSupport;
    expect(<bool>[s.rate, s.pitch, s.volume], everyElement(isTrue));
    expect(<bool>[s.emotion, s.tone, s.seed], everyElement(isFalse));
    final TtsDirection d = effectiveTtsDirection(
      s,
      const TtsDirection(
        emotion: CastEmotion.sadness,
        intensity: 100,
        tone: 'しんみりと',
      ),
    );
    expect(d.tone, isNull);
    // 情绪折成三项偏移；属性值的换算与 Edge 共用（microsoftProsodyOf）。
    expect(d.rateOffset, closeTo(-0.12, 1e-9));
    expect(d.pitchOffset, closeTo(-1.5, 1e-9));
    expect(d.volumeOffset, closeTo(-2, 1e-9));
    final MicrosoftProsody p = microsoftProsodyOf(d)!;
    expect(
      MicrosoftTranslatorTtsProvider.ssml(voice, 'あ', direction: d),
      "<speak version='1.0' xml:lang='ja-JP'>"
      "<voice xml:lang='ja-JP' name='ja-JP-NanamiNeural'>"
      "<prosody rate='${p.rate}' pitch='${p.pitch}' volume='${p.volume}'>"
      'あ</prosody></voice></speak>',
    );
    expect(p.rate, '-12%');
  });
}
