import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/clipboard_dedupe.dart';

void main() {
  group('dedupeClipboard', () {
    test('trims and returns new text', () {
      expect(dedupeClipboard('  見る  ', null), '見る');
    });
    test('returns null when same as last (after trim)', () {
      expect(dedupeClipboard('見る', '見る'), isNull);
      expect(dedupeClipboard('  見る ', '見る'), isNull);
    });
    test('returns null for empty/blank', () {
      expect(dedupeClipboard('', null), isNull);
      expect(dedupeClipboard('   ', null), isNull);
    });
    test('returns new text when changed', () {
      expect(dedupeClipboard('読む', '見る'), '読む');
    });
  });
}
