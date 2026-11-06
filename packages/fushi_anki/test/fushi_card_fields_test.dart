import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:test/test.dart';

void main() {
  test('Fushi Card fields are Lapis fields under their canonical names', () {
    expect(FushiCardNoteType.fields, <String>[
      for (final String f in LapisNoteType.fields) FushiCardFields.canonical(f),
      FushiCardNoteType.sentenceTranslationField,
    ]);
  });

  test('default mappings are Lapis mappings re-keyed to canonical names', () {
    expect(FushiCardNoteType.defaultFieldMappings, <String, String>{
      for (final MapEntry<String, String> e
          in LapisNoteType.defaultFieldMappings.entries)
        FushiCardFields.canonical(e.key): e.value,
    });
  });

  test('legacy names resolve to the new names and back', () {
    for (final MapEntry<String, String> e
        in FushiCardFields.legacyNames.entries) {
      expect(FushiCardFields.canonical(e.value), e.key);
      expect(FushiCardFields.canonical(e.key), e.key);
      expect(FushiCardFields.legacyNameOf(e.key), e.value);
      expect(FushiCardNoteType.fields, contains(e.key));
      expect(FushiCardNoteType.fields, isNot(contains(e.value)));
    }
    expect(FushiCardFields.canonical('Sentence'), 'Sentence');
    expect(FushiCardFields.legacyNameOf('Sentence'), 'Sentence');
  });

  test('canonicalizeFields renames legacy keys, new key wins on clash', () {
    expect(
      FushiCardFields.canonicalizeFields(<String, String>{
        'Expression': 'old',
        'Picture': '<img>',
        'Sentence': 's',
      }),
      <String, String>{'Term': 'old', 'Media': '<img>', 'Sentence': 's'},
    );
    expect(
      FushiCardFields.canonicalizeFields(<String, String>{
        'Expression': 'old',
        'Term': 'new',
      }),
      <String, String>{'Term': 'new'},
    );
  });

  test('template references only canonical field names', () {
    final String all = '$kFushiCardFrontTemplate$kFushiCardBackTemplate';
    for (final String legacy in FushiCardFields.legacyNames.values) {
      expect(
        RegExp('\{\{[^}]*\b$legacy\b[^}]*\}\}').hasMatch(all),
        isFalse,
        reason: legacy,
      );
    }
  });

  test(
    'alignToFields maps keys onto the actual field names of the note type',
    () {
      // Anki 里已导出的还是旧名，渲染键是新名 -> 改用旧名。
      expect(
        FushiCardFields.alignToFields(
          <String, String>{'Term': 'a', 'Media': 'b', 'Sentence': 'c'},
          <String>['Expression', 'Picture', 'Sentence'],
        ),
        <String, String>{'Expression': 'a', 'Picture': 'b', 'Sentence': 'c'},
      );
      // 反过来：映射存的是旧名，Anki 里已是新名。
      expect(
        FushiCardFields.alignToFields(
          <String, String>{'Expression': 'a', 'Picture': 'b'},
          <String>['Term', 'Media'],
        ),
        <String, String>{'Term': 'a', 'Media': 'b'},
      );
      // 键本身就是字段：不动；别名字段已被占用：不覆盖；对不上的键原样保留。
      expect(
        FushiCardFields.alignToFields(
          <String, String>{'Term': 'new', 'Expression': 'old', 'Other': 'x'},
          <String>['Term'],
        ),
        <String, String>{'Term': 'new', 'Expression': 'old', 'Other': 'x'},
      );
      // 没有字段清单（设置陈旧）：原样返回。
      final Map<String, String> m = <String, String>{'Term': 'a'};
      expect(
        identical(FushiCardFields.alignToFields(m, <String>[]), m),
        isTrue,
      );
    },
  );

  test('value falls back to the legacy name', () {
    expect(
      FushiCardFields.value(<String, String>{'Picture': 'p'}, 'Media'),
      'p',
    );
    expect(
      FushiCardFields.value(<String, String>{
        'Media': 'n',
        'Picture': 'p',
      }, 'Media'),
      'n',
    );
    expect(FushiCardFields.value(<String, String>{}, 'Media'), isNull);
  });
}
