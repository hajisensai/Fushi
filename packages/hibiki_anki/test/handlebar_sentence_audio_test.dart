import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// 通用句子音频键 `{sentence-audio}` 守卫 + 旧别名向后兼容。
///
/// `{sentence-audio}` 是句子音频的通用占位符（语义中性、名副其实），取代名不副实的
/// 内部历史命名 `{sasayaki-audio}` 成为 Lapis `SentenceAudio` 字段的默认映射。旧键
/// `{sasayaki-audio}` 保留为别名：两者都读同一个 `context.sasayakiAudioPath`，渲染
/// 结果必须逐字节相同——老配置 / 老卡片模板不受影响。
void main() {
  const AnkiMiningPayload payload = AnkiMiningPayload(expression: '言葉');

  AnkiMiningContext contextWithAudio(String? audio) => AnkiMiningContext(
        sentence: 'これは言葉です。',
        sasayakiAudioPath: audio,
      );

  group('AnkiHandlebarRenderer {sentence-audio}', () {
    test('renders context.sasayakiAudioPath', () {
      final String value = AnkiHandlebarRenderer.render(
        '{sentence-audio}',
        payload,
        contextWithAudio('sentence.mp3'),
      );
      expect(value, 'sentence.mp3');
    });

    test('{sentence-audio} == {sasayaki-audio} 逐字节相同（向后兼容）', () {
      final AnkiMiningContext ctx = contextWithAudio('hibiki_audio_x.mp3');
      final String sentenceAudio =
          AnkiHandlebarRenderer.render('{sentence-audio}', payload, ctx);
      final String sasayakiAudio =
          AnkiHandlebarRenderer.render('{sasayaki-audio}', payload, ctx);
      expect(sentenceAudio, sasayakiAudio);
    });

    test('sasayakiAudioPath 为 null 时两者都渲染空串', () {
      final AnkiMiningContext ctx = contextWithAudio(null);
      expect(
          AnkiHandlebarRenderer.render('{sentence-audio}', payload, ctx), '');
      expect(
          AnkiHandlebarRenderer.render('{sasayaki-audio}', payload, ctx), '');
    });

    test('两者都渲染媒体引用串（模拟 backend 落盘后回填）逐字节相同', () {
      // backend 把音频落盘后用 `[sound:ref]` 覆盖 sasayakiAudioPath 再渲染。
      const String mediaRef = '[sound:hibiki_audio_abc.mp3]';
      final AnkiMiningContext ctx = contextWithAudio(mediaRef);
      expect(AnkiHandlebarRenderer.render('{sentence-audio}', payload, ctx),
          mediaRef);
      expect(
        AnkiHandlebarRenderer.render('{sentence-audio}', payload, ctx),
        AnkiHandlebarRenderer.render('{sasayaki-audio}', payload, ctx),
      );
    });
  });

  group('AnkiHandlebarOptions.coreOptions', () {
    test('含新键 {sentence-audio} 且仍保留旧别名 {sasayaki-audio}', () {
      expect(AnkiHandlebarOptions.coreOptions, contains('{sentence-audio}'));
      expect(AnkiHandlebarOptions.coreOptions, contains('{sasayaki-audio}'));
    });
  });

  group('AnkiHandlebarOptions.anyFieldConsumesSentenceAudio', () {
    test('新键 {sentence-audio} 被消费时为 true', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesSentenceAudio(
            {'SentenceAudio': '{sentence-audio}'}),
        isTrue,
      );
    });

    test('旧别名 {sasayaki-audio} 被消费时也为 true（向后兼容诊断）', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesSentenceAudio(
            {'SentenceAudio': '{sasayaki-audio}'}),
        isTrue,
      );
    });

    test('没有字段消费任一句子音频键时为 false', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesSentenceAudio(
            {'Expression': '{expression}'}),
        isFalse,
      );
      expect(AnkiHandlebarOptions.anyFieldConsumesSentenceAudio({}), isFalse);
    });
  });

  group('LapisNoteType default mapping', () {
    test('SentenceAudio 默认映射到通用键 {sentence-audio}（不再是内部命名 sasayaki）', () {
      expect(LapisNoteType.defaultFieldMappings['SentenceAudio'],
          '{sentence-audio}');
    });
  });
}
