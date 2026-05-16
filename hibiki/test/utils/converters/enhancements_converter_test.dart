import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/converters/enhancements_converter.dart';

void main() {
  group('EnhancementsConverter', () {
    test('round-trip serialization preserves data', () {
      final original = <String, Map<int, String>>{
        'image': {0: 'bing_images', 2: 'camera'},
        'audio': {1: 'forvo'},
      };

      final json = EnhancementsConverter.toIsar(original);
      final restored = EnhancementsConverter.fromIsar(json);

      expect(restored, original);
    });

    test('empty map serializes and deserializes correctly', () {
      final original = <String, Map<int, String>>{};

      final json = EnhancementsConverter.toIsar(original);
      final restored = EnhancementsConverter.fromIsar(json);

      expect(restored, isEmpty);
    });

    test('toIsar produces valid JSON string', () {
      final data = <String, Map<int, String>>{
        'field': {0: 'value'},
      };

      final json = EnhancementsConverter.toIsar(data);

      expect(json, '{"field":{"0":"value"}}');
    });

    test('fromIsar parses int keys from string representation', () {
      const json = '{"key":{"42":"hello","100":"world"}}';

      final result = EnhancementsConverter.fromIsar(json);

      expect(result['key']![42], 'hello');
      expect(result['key']![100], 'world');
    });

    test('nested empty map is preserved', () {
      final original = <String, Map<int, String>>{
        'empty': {},
        'full': {1: 'a'},
      };

      final json = EnhancementsConverter.toIsar(original);
      final restored = EnhancementsConverter.fromIsar(json);

      expect(restored['empty'], isEmpty);
      expect(restored['full']![1], 'a');
    });
  });
}
