import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// TODO-948/952: unit tests for the pure field-mapping diagnostic helpers used
/// by the mining "no sentence / unmapped field" toast. These answer "does any
/// Anki field consume {sentence} / {sasayaki-audio}?" purely from the persisted
/// [AnkiSettings.fieldMappings] (Anki field name -> handlebar template), with no
/// rendering and no runtime data — the honest "why is the field empty" signal.
void main() {
  group('AnkiHandlebarOptions.anyFieldConsumesToken', () {
    test('bare token in a field value matches', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken(
          {'Sentence': '{sentence}'},
          '{sentence}',
        ),
        isTrue,
      );
    });

    test('token embedded inside a larger HTML template matches', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken(
          {'Front': '<div>{expression}</div><span>{sentence}</span>'},
          '{sentence}',
        ),
        isTrue,
      );
    });

    test('no field consuming the token returns false', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken(
          {'Expression': '{expression}', 'Reading': '{reading}'},
          '{sentence}',
        ),
        isFalse,
      );
    });

    test('empty mappings return false', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken({}, '{sentence}'),
        isFalse,
      );
    });

    test('fields mapped to literal "-" (no token) return false', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken(
          {'Front': '-', 'Back': '-'},
          '{sentence}',
        ),
        isFalse,
      );
    });

    test('matches {sasayaki-audio} for the sentence-audio diagnostic', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken(
          {'SentenceAudio': '{sasayaki-audio}'},
          '{sasayaki-audio}',
        ),
        isTrue,
      );
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken(
          {'Word': '{audio}'},
          '{sasayaki-audio}',
        ),
        isFalse,
      );
    });
  });

  group('AnkiHandlebarOptions.anyFieldConsumesSentence', () {
    test('{sentence} counts as consuming the sentence', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesSentence({'S': '{sentence}'}),
        isTrue,
      );
    });

    test('{cue-sentence} also counts (audiobook variant)', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesSentence({'S': '{cue-sentence}'}),
        isTrue,
      );
    });

    test('neither {sentence} nor {cue-sentence} mapped returns false', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesSentence(
          {'Expression': '{expression}', 'Glossary': '{glossary}'},
        ),
        isFalse,
      );
    });

    test('empty mappings return false (no field to receive the sentence)', () {
      expect(AnkiHandlebarOptions.anyFieldConsumesSentence({}), isFalse);
    });
  });

  group('AnkiHandlebarOptions.anyFieldConsumesCardImage', () {
    // TODO-1298 改名后 {book-cover} / {video-clip} 是 {card-image} 的向后兼容
    // 别名（三者都渲染 context.coverPath）。改名前建的 Lapis 卡组持久化里
    // Picture 仍是 {book-cover}，galgame 场景制卡的诊断必须认这些别名，否则误报
    // 「缺少游戏卡片字段: {card-image}」，尽管画面/GIF 其实已通过别名落卡（BUG）。
    test('{card-image} counts as consuming the card image', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesCardImage(
            {'Picture': '{card-image}'}),
        isTrue,
      );
    });

    test('legacy alias {book-cover} also counts (pre-TODO-1298 config)', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesCardImage(
            {'Picture': '{book-cover}'}),
        isTrue,
      );
    });

    test('legacy alias {video-clip} also counts', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesCardImage(
            {'Picture': '{video-clip}'}),
        isTrue,
      );
    });

    test('none of the three card-image aliases mapped returns false', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesCardImage(
          {'Expression': '{expression}', 'Sentence': '{sentence}'},
        ),
        isFalse,
      );
    });

    test('empty mappings return false (no field to receive the image)', () {
      expect(AnkiHandlebarOptions.anyFieldConsumesCardImage({}), isFalse);
    });
  });

  group('AnkiHandlebarOptions.optionsForField', () {
    // 选择器默认隐藏没被用到的旧别名（新用户只看到新键），但当前字段正用着的旧
    // 别名必须仍在候选里——否则 picker 的列表不含当前值（BUG-952 那类坑）。
    List<String> optionsFor(String currentValue) =>
        AnkiHandlebarOptions.optionsForField(
          dictionaryNames: const <String>[],
          currentValue: currentValue,
        );

    test('unused legacy aliases are hidden for a fresh field', () {
      final List<String> options = optionsFor('');
      for (final String alias in AnkiHandlebarOptions.deprecatedAliases) {
        expect(options, isNot(contains(alias)));
      }
    });

    test('canonical keys always remain available', () {
      final List<String> options = optionsFor('');
      expect(options, contains('{card-image}'));
      expect(options, contains('{sentence-audio}'));
      expect(options, contains('{sentence}'));
      expect(options, contains('-'));
    });

    test('the legacy alias currently in use stays visible', () {
      final List<String> options = optionsFor('{book-cover}');
      expect(options, contains('{book-cover}'),
          reason: '当前值必须在候选里，否则 picker 显示不出当前选中项');
      // 其它没用到的别名仍然隐藏。
      expect(options, isNot(contains('{video-clip}')));
      expect(options, isNot(contains('{sasayaki-audio}')));
    });

    test('alias embedded in a composite HTML template also stays visible', () {
      final List<String> options =
          optionsFor('<div>{expression}</div><img>{book-cover}</img>');
      expect(options, contains('{book-cover}'));
    });

    test('dictionary-specific options are appended untouched', () {
      final List<String> options = AnkiHandlebarOptions.optionsForField(
        dictionaryNames: const <String>['広辞苑'],
        currentValue: '',
      );
      expect(options, contains('{single-glossary-広辞苑}'));
    });
  });
}
