import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 通用句子音频键 `{sentence-audio}` 守卫 + 旧别名退役负向守卫。
///
/// `{sentence-audio}` 是句子音频的通用占位符（语义中性、名副其实），是 Lapis
/// `SentenceAudio` 字段的默认映射。历史别名 `{sasayaki-audio}` 已退役：存量用户
/// 模板由 `BaseAnkiRepository.loadSettings` 载入期一次性改写为 `{sentence-audio}`，
/// 渲染器 / 候选列表 / 诊断均不再受理旧别名——本文件同时锁定这组负向语义。
void main() {
  const AnkiMiningPayload payload = AnkiMiningPayload(expression: '言葉');

  AnkiMiningContext contextWithAudio(String? audio) =>
      AnkiMiningContext(sentence: 'これは言葉です。', sentenceAudioPath: audio);

  group('AnkiHandlebarRenderer {sentence-audio}', () {
    test('renders context.sentenceAudioPath', () {
      final String value = AnkiHandlebarRenderer.render(
        '{sentence-audio}',
        payload,
        contextWithAudio('sentence.mp3'),
      );
      expect(value, 'sentence.mp3');
    });

    test('退役别名 {sasayaki-audio} 不再被渲染器认领（未知 token → 空串）', () {
      final AnkiMiningContext ctx = contextWithAudio('hibiki_audio_x.mp3');
      expect(
        AnkiHandlebarRenderer.render('{sasayaki-audio}', payload, ctx),
        '',
        reason: '别名已由载入期迁移改写为 {sentence-audio}，渲染器走 default 空串',
      );
      // 新键仍正常读 sentenceAudioPath。
      expect(
        AnkiHandlebarRenderer.render('{sentence-audio}', payload, ctx),
        'hibiki_audio_x.mp3',
      );
    });

    test('sentenceAudioPath 为 null 时渲染空串', () {
      final AnkiMiningContext ctx = contextWithAudio(null);
      expect(
        AnkiHandlebarRenderer.render('{sentence-audio}', payload, ctx),
        '',
      );
    });

    test('渲染媒体引用串（模拟 backend 落盘后回填）', () {
      // backend 把音频落盘后用 `[sound:ref]` 覆盖 sentenceAudioPath 再渲染。
      const String mediaRef = '[sound:hibiki_audio_abc.mp3]';
      final AnkiMiningContext ctx = contextWithAudio(mediaRef);
      expect(
        AnkiHandlebarRenderer.render('{sentence-audio}', payload, ctx),
        mediaRef,
      );
    });
  });

  group('AnkiHandlebarOptions.coreOptions', () {
    test('含新键 {sentence-audio}，退役别名 {sasayaki-audio} 不在候选', () {
      expect(AnkiHandlebarOptions.coreOptions, contains('{sentence-audio}'));
      expect(
        AnkiHandlebarOptions.coreOptions,
        isNot(contains('{sasayaki-audio}')),
      );
    });
  });

  group('AnkiHandlebarOptions.anyFieldConsumesSentenceAudio', () {
    test('新键 {sentence-audio} 被消费时为 true', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesSentenceAudio({
          'SentenceAudio': '{sentence-audio}',
        }),
        isTrue,
      );
    });

    test('退役别名 {sasayaki-audio} 不再计入（已由载入期迁移改写）', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesSentenceAudio({
          'SentenceAudio': '{sasayaki-audio}',
        }),
        isFalse,
      );
    });

    test('没有字段消费句子音频键时为 false', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesSentenceAudio({
          'Expression': '{expression}',
        }),
        isFalse,
      );
      expect(AnkiHandlebarOptions.anyFieldConsumesSentenceAudio({}), isFalse);
    });
  });

  group('LapisNoteType default mapping', () {
    test(
      'SentenceAudio 默认映射到通用键 {sentence-audio}（不再是内部历史命名别名）',
      () {
        expect(
          LapisNoteType.defaultFieldMappings['SentenceAudio'],
          '{sentence-audio}',
        );
      },
    );
  });
}
