import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/anki_settings_page.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

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

  test('{video-clip} maps to t.handlebar_video_clip', () {
    expect(ankiHandlebarLabel('{video-clip}'), t.handlebar_video_clip);
  });

  test('{book-cover} maps to t.handlebar_book_cover (unchanged)', () {
    expect(ankiHandlebarLabel('{book-cover}'), t.handlebar_book_cover);
  });

  test('unknown placeholder falls back to the raw literal', () {
    expect(ankiHandlebarLabel('{bogus}'), '{bogus}');
  });

  test('{single-glossary-<dict>} falls back to the dictionary name', () {
    expect(ankiHandlebarLabel('{single-glossary-広辞苑}'), '広辞苑');
  });
}
