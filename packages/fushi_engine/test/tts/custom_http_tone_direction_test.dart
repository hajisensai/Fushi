import 'dart:convert';

import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/providers/custom_http_tts_provider.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:test/test.dart';

const TtsDirection _sad = TtsDirection(
  seed: 7,
  emotion: CastEmotion.sadness,
  intensity: 100,
  rateOffset: 0.1,
  pitchOffset: 2,
  volumeOffset: -3,
  tone: 'おずおずと',
);

CustomHttpTtsConfig _config(String body, {String speed = ''}) =>
    CustomHttpTtsConfig(
      endpoint: 'http://127.0.0.1:9/tts',
      bodyTemplate: body,
      speed: speed,
    );

Object? _body(CustomHttpTtsConfig config, TtsDirection wanted) => jsonDecode(
  utf8.decode(
    buildCustomHttpTtsRequest(
      config,
      'あ',
      direction: effectiveTtsDirection(
        customHttpTtsDirectionSupport(config),
        wanted,
      ),
    ).body!,
  ),
);

void main() {
  test('模板没用语气占位符：什么都不声明，请求与没有演出参数时逐字节相同', () {
    final CustomHttpTtsConfig config = _config('{"text":"{text}"}');
    final TtsDirectionSupport s = customHttpTtsDirectionSupport(config);
    expect(<bool>[
      s.emotion,
      s.tone,
      s.rate,
      s.pitch,
      s.volume,
      s.seed,
    ], everyElement(isFalse));
    final TtsDirection d = effectiveTtsDirection(s, _sad);
    expect(d.isEmpty, isTrue);
    expect(
      buildCustomHttpTtsRequest(config, 'あ', direction: d).body,
      buildCustomHttpTtsRequest(config, 'あ').body,
    );
  });

  test('只有 {speed}：声明语速，情绪折进语速并乘到预设速度上', () {
    final CustomHttpTtsConfig config = _config(
      '{"text":"{text}","speed_facter":"{speed}"}',
      speed: '1.5',
    );
    final TtsDirectionSupport s = customHttpTtsDirectionSupport(config);
    expect(s.rate, isTrue);
    expect(s.emotion, isFalse);
    expect(s.pitch, isFalse);
    // 没有演出参数：原样发预设速度。
    expect(_body(config, TtsDirection.none), <String, Object?>{
      'text': 'あ',
      'speed_facter': 1.5,
    });
    // 0.1（标注）+ -0.12（悲伤 100 折算）= -0.02 → 1.5 × 0.98 = 1.47
    expect(_body(config, _sad), <String, Object?>{
      'text': 'あ',
      'speed_facter': 1.47,
    });
  });

  test('预设速度不是数字：{speed} 原样发送，不声明语速', () {
    final CustomHttpTtsConfig config = _config(
      '{"speed":"{speed}"}',
      speed: 'fast',
    );
    expect(customHttpTtsDirectionSupport(config).rate, isFalse);
    expect(_body(config, _sad), <String, Object?>{'speed': 'fast'});
  });

  test('全部语气占位符：情绪原生，数值占位符整值代入数字', () {
    final CustomHttpTtsConfig config = _config(
      '{"emotion":"{emotion}","strength":"{intensity}","tone":"{tone}",'
      '"instruct":"{instruction}","rate":"{rate}","pitch":"{pitch}",'
      '"gain":"{volume}","note":"x{rate}"}',
    );
    final TtsDirectionSupport s = customHttpTtsDirectionSupport(config);
    expect(<bool>[
      s.emotion,
      s.tone,
      s.rate,
      s.pitch,
      s.volume,
    ], everyElement(isTrue));
    expect(s.seed, isFalse);
    expect(_body(config, _sad), <String, Object?>{
      'emotion': 'sadness',
      'strength': 100,
      'tone': 'おずおずと',
      'instruct': '感情：悲しげ（強く）。話し方：おずおずと。',
      // 情绪原生表达：不再折进语速 / 音高 / 音量，只用标注的偏移。
      'rate': 1.1,
      'pitch': 2,
      'gain': -3,
      'note': 'x1.1',
    });
    // 没有演出参数时的默认值。
    expect(_body(config, TtsDirection.none), <String, Object?>{
      'emotion': 'neutral',
      'strength': 0,
      'tone': '',
      'instruct': '',
      'rate': 1,
      'pitch': 0,
      'gain': 0,
      'note': 'x1',
    });
  });

  test('只写 {pitch} / {volume}：情绪折进这两项（query 模板里按文本代入）', () {
    final CustomHttpTtsConfig config = CustomHttpTtsConfig(
      endpoint: 'http://127.0.0.1:9/tts',
      method: 'GET',
      queryTemplate: 'text={text}&p={pitch}&v={volume}',
    );
    final TtsDirectionSupport s = customHttpTtsDirectionSupport(config);
    expect(s.pitch && s.volume, isTrue);
    expect(s.emotion || s.rate || s.tone, isFalse);
    final Uri uri = buildCustomHttpTtsRequest(
      config,
      'あ',
      direction: effectiveTtsDirection(
        s,
        const TtsDirection(emotion: CastEmotion.joy, intensity: 100),
      ),
    ).uri;
    expect(uri.queryParameters, <String, String>{
      'text': 'あ',
      'p': '1.5',
      'v': '1',
    });
  });

  test('只写 {tone}：收语气说明，情绪不声明', () {
    final TtsDirectionSupport s = customHttpTtsDirectionSupport(
      _config('{"t":"{tone}"}'),
    );
    expect(s.tone, isTrue);
    expect(s.emotion, isFalse);
  });

  test('数值格式：最多三位小数、去掉尾零', () {
    expect(customHttpTtsNumber(1), '1');
    expect(customHttpTtsNumber(1.08), '1.08');
    expect(customHttpTtsNumber(-2.5), '-2.5');
    expect(customHttpTtsNumber(10), '10');
    expect(customHttpTtsNumber(-0.0001), '0');
    expect(customHttpTtsNumber(0.33333), '0.333');
  });
}
