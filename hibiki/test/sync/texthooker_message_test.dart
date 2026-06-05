import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/texthooker_message.dart';

void main() {
  group('parseTexthookerMessage', () {
    test('raw text passes through', () {
      expect(parseTexthookerMessage('走り出した。'), '走り出した。');
    });
    test('json with sentence field is unwrapped', () {
      expect(parseTexthookerMessage('{"sentence":"こんにちは"}'), 'こんにちは');
    });
    test('json without sentence falls back to raw', () {
      expect(parseTexthookerMessage('{"text":"x"}'), '{"text":"x"}');
    });
    test('invalid json falls back to raw', () {
      expect(parseTexthookerMessage('{not json'), '{not json');
    });
    test('json string scalar (not object) falls back to raw', () {
      expect(parseTexthookerMessage('"hi"'), '"hi"');
    });
    test('non-string sentence falls back to raw', () {
      expect(parseTexthookerMessage('{"sentence":123}'), '{"sentence":123}');
    });
  });
}
