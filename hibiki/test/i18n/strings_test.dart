import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';

void main() {
  group('Chinese reader settings labels', () {
    test('uses compact labels for furigana modes', () {
      final strings = AppLocale.zhCn.translations;

      expect(strings.ttu_furigana_partial, '部分');
      expect(strings.ttu_furigana_toggle, '切换');
      expect(
        strings.ttu_furigana_mode_hint,
        '',
      );
    });
  });
}
