import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

void main() {
  group('LapisNoteType authoritative schema', () {
    test('has the 22 official fields in order', () {
      expect(LapisNoteType.fields, <String>[
        'Expression',
        'ExpressionFurigana',
        'ExpressionReading',
        'ExpressionAudio',
        'SelectionText',
        'MainDefinition',
        'DefinitionPicture',
        'Sentence',
        'SentenceFurigana',
        'SentenceAudio',
        'Picture',
        'Glossary',
        'Hint',
        'IsWordAndSentenceCard',
        'IsClickCard',
        'IsSentenceCard',
        'IsAudioCard',
        'PitchPosition',
        'PitchCategories',
        'Frequency',
        'FreqSort',
        'MiscInfo',
      ]);
    });

    test('model and deck names', () {
      expect(LapisNoteType.modelName, 'Lapis');
      expect(LapisNoteType.deckName, 'Lapis');
      expect(LapisNoteType.cardName, 'Card 1');
    });

    test('templates are non-trivial vendored content', () {
      expect(LapisNoteType.front.length, greaterThan(500));
      expect(LapisNoteType.back.length, greaterThan(5000));
      expect(LapisNoteType.css.length, greaterThan(5000));
      expect(LapisNoteType.front, contains('id="lapis"'));
      expect(LapisNoteType.back, contains('Expression'));
    });

    test('template carries all schema fields', () {
      expect(LapisNoteType.template.name, 'Lapis');
      expect(LapisNoteType.template.fields, LapisNoteType.fields);
      expect(LapisNoteType.template.cardName, 'Card 1');
      expect(LapisNoteType.template.front, LapisNoteType.front);
      expect(LapisNoteType.template.back, LapisNoteType.back);
      // template.css is the verbatim upstream css followed by the Hibiki delta.
      expect(LapisNoteType.template.css,
          '${LapisNoteType.css}\n${LapisNoteType.fushiCssOverride}');
    });

    test('Hibiki css override separates the def-info label from the sentence',
        () {
      // BUG-056 follow-up: upstream `.def-info` has no top margin so the
      // "Primary Definition N/M" label crowds the sentence on multi-def desktop
      // cards. The delta lives in its own constant (css stays verbatim) and is
      // appended after the vendored css so it wins by source order.
      expect(LapisNoteType.css, isNot(contains('Hibiki delta')),
          reason: 'vendored css must stay byte-identical to upstream');
      // BUG-2151 / BUG-2155 曾把四处补丁直接写进 vendored `css`，而上面那条
      // 只认 'Hibiki delta' 这一个串，没抓到。本仓的补丁一律带 `BUG-NNNN` 引用，
      // 拿它当判据：vendored 常量里出现本仓的 bug 号 = 有人又在里面打补丁了。
      // 代价是真实的：重新 vendor 会把补丁静默冲掉（没有守卫会红），且原版
      // Lapis 用户会被 lapis_styling 的 pristine 集合判成「手改过」，每次点
      // 「应用样式到 Anki」都要多确认一次。
      expect(
        RegExp(r'BUG-\d+').hasMatch(LapisNoteType.css),
        isFalse,
        reason: 'Hibiki 的 CSS 补丁只能写在 fushiCssOverride 里，'
            '不能改 vendored 的 css 常量',
      );
      expect(LapisNoteType.fushiCssOverride, contains('.def-info'));
      expect(LapisNoteType.fushiCssOverride, contains('Hibiki delta'));
      expect(LapisNoteType.fushiCssOverride, contains('margin-top'));
      expect(
        LapisNoteType.template.css.indexOf(LapisNoteType.fushiCssOverride),
        greaterThan(LapisNoteType.template.css.indexOf('.def-info {')),
        reason: 'override must come after the upstream .def-info rule',
      );
    });

    test('default field mappings only reference real fields', () {
      for (final field in LapisNoteType.defaultFieldMappings.keys) {
        expect(LapisNoteType.fields, contains(field));
      }
      expect(LapisNoteType.defaultFieldMappings['Picture'], '{card-image}');
      expect(LapisNoteType.defaultFieldMappings['SentenceAudio'],
          '{sentence-audio}');
      expect(LapisNoteType.defaultFieldMappings['IsWordAndSentenceCard'], 'x');
    });
  });
}
