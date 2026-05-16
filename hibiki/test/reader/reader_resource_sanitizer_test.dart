import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_resource_sanitizer.dart';

void main() {
  group('ReaderResourceSanitizer.sanitizeCss', () {
    test('strips -epub-writing-mode completely', () {
      final input = '  -epub-writing-mode: vertical-rl;';

      final output = ReaderResourceSanitizer.sanitizeCss(input);

      expect(output, isEmpty);
    });

    test('converts -epub-line-break to standard + webkit prefix', () {
      final input = '  -epub-line-break: strict;';

      final output = ReaderResourceSanitizer.sanitizeCss(input);

      expect(output, contains('-webkit-line-break: strict;'));
      expect(output, contains('line-break: strict;'));
    });

    test('converts -epub-word-break to standard + webkit prefix', () {
      final input = '  -epub-word-break: break-all;';

      final output = ReaderResourceSanitizer.sanitizeCss(input);

      expect(output, contains('-webkit-word-break: break-all;'));
      expect(output, contains('word-break: break-all;'));
    });

    test('converts -epub-hyphens to standard + webkit prefix', () {
      final input = '  -epub-hyphens: auto;';

      final output = ReaderResourceSanitizer.sanitizeCss(input);

      expect(output, contains('-webkit-hyphens: auto;'));
      expect(output, contains('hyphens: auto;'));
    });

    test('converts -epub-text-combine to text-combine-upright', () {
      final input = '  -epub-text-combine: horizontal;';

      final output = ReaderResourceSanitizer.sanitizeCss(input);

      expect(output, contains('-webkit-text-combine: horizontal;'));
      expect(output, contains('text-combine-upright: all;'));
    });

    test('converts -epub-text-emphasis-style to standard + webkit', () {
      final input = '  -epub-text-emphasis-style: dot;';

      final output = ReaderResourceSanitizer.sanitizeCss(input);

      expect(output, contains('-webkit-text-emphasis-style: dot;'));
      expect(output, contains('text-emphasis-style: dot;'));
    });

    test('converts -epub-text-emphasis-color to standard + webkit', () {
      final input = '  -epub-text-emphasis-color: red;';

      final output = ReaderResourceSanitizer.sanitizeCss(input);

      expect(output, contains('-webkit-text-emphasis-color: red;'));
      expect(output, contains('text-emphasis-color: red;'));
    });

    test('unknown -epub- property becomes unprefixed', () {
      final input = '  -epub-some-future-prop: value;';

      final output = ReaderResourceSanitizer.sanitizeCss(input);

      expect(output, contains('some-future-prop: value;'));
      expect(output, isNot(contains('-epub-')));
    });

    test('non-epub CSS is left untouched', () {
      final input = '''body {
  font-size: 16px;
  color: black;
}''';

      final output = ReaderResourceSanitizer.sanitizeCss(input);

      expect(output, input);
    });

    test('handles multiple -epub- properties in one block', () {
      final input = '''p {
  -epub-writing-mode: vertical-rl;
  -epub-line-break: strict;
  margin: 0;
}''';

      final output = ReaderResourceSanitizer.sanitizeCss(input);

      expect(output, isNot(contains('-epub-writing-mode')));
      expect(output, contains('line-break: strict;'));
      expect(output, contains('margin: 0;'));
    });
  });
}
