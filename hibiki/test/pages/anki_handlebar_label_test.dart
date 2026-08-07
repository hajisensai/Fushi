import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/anki_settings_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// TODO-843：占位符友好标签映射守卫。
///
/// picker 现在显示本地化友好标签（接 `t.handlebar_*`），但写进 fieldMappings 的仍是
/// 字面量。本测试锁定：coreOptions 里每个非 `-` 字面量都有友好标签（无漏接），未知 /
/// 动态占位符按规则回退，绝不返回空白。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  test('every coreOptions literal maps to a non-literal friendly label', () {
    for (final String option in AnkiHandlebarOptions.coreOptions) {
      if (option == '-') continue;
      final String label = ankiHandlebarLabel(option);
      expect(label, isNotEmpty, reason: 'no label for $option');
      expect(
        label,
        isNot(equals(option)),
        reason:
            '$option still shows the raw literal — friendly label not wired',
      );
    }
  });

  test('{video-clip} keeps its label but is marked deprecated', () {
    expect(
      ankiHandlebarLabel('{video-clip}'),
      t.handlebar_deprecated_label(label: t.handlebar_video_clip),
    );
  });

  test('{book-cover} keeps its label but is marked deprecated', () {
    expect(
      ankiHandlebarLabel('{book-cover}'),
      t.handlebar_deprecated_label(label: t.handlebar_book_cover),
    );
  });

  test('{sasayaki-audio} keeps its label but is marked deprecated', () {
    expect(
      ankiHandlebarLabel('{sasayaki-audio}'),
      t.handlebar_deprecated_label(label: t.handlebar_sasayaki_audio),
    );
  });

  test('{card-image} maps to t.handlebar_card_image (TODO-1298)', () {
    expect(ankiHandlebarLabel('{card-image}'), t.handlebar_card_image);
  });

  test('canonical keys are never marked deprecated', () {
    // 新键（含刚接管 {book-cover} 的 {card-image}）不该带弃用标注。
    final Map<String, String> canonical = <String, String>{
      '{card-image}': t.handlebar_card_image,
      '{sentence-audio}': t.handlebar_sentence_audio,
      '{sentence}': t.handlebar_sentence,
      '{audio}': t.handlebar_audio,
    };
    canonical.forEach((String option, String expected) {
      expect(
        AnkiHandlebarOptions.deprecatedAliases.contains(option),
        isFalse,
        reason: '$option 是新键，不该进 deprecatedAliases',
      );
      expect(ankiHandlebarLabel(option), expected);
    });
  });

  test('every deprecated alias still has a real label under the marker', () {
    for (final String alias in AnkiHandlebarOptions.deprecatedAliases) {
      final String label = ankiHandlebarLabel(alias);
      expect(label, isNotEmpty);
      expect(label, isNot(equals(alias)), reason: '$alias 不该退化成裸字面量');
      expect(label, isNot(equals(t.handlebar_deprecated_label(label: ''))),
          reason: '$alias 只剩弃用标记、丢了本体标签');
    }
  });

  test('unknown placeholder falls back to the raw literal', () {
    expect(ankiHandlebarLabel('{bogus}'), '{bogus}');
  });

  test('{single-glossary-<dict>} falls back to the dictionary name', () {
    expect(ankiHandlebarLabel('{single-glossary-広辞苑}'), '広辞苑');
  });
}
