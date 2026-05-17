import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/converters/immutable_string_map_converter.dart';

void main() {
  group('ImmutableStringMapConverter', () {
    test('round-trip with simple map', () {
      final original = {'key': 'value', 'number': 42};
      final serialized = ImmutableStringMapConverter.toIsar(original);
      final restored = ImmutableStringMapConverter.fromIsar(serialized);

      expect(restored['key'], 'value');
      expect(restored['number'], 42);
    });

    test('round-trip with empty map', () {
      final original = <String, dynamic>{};
      final serialized = ImmutableStringMapConverter.toIsar(original);
      final restored = ImmutableStringMapConverter.fromIsar(serialized);

      expect(restored, isEmpty);
    });

    test('round-trip with nested map', () {
      final original = <String, dynamic>{
        'outer': {'inner': 'value'},
      };
      final serialized = ImmutableStringMapConverter.toIsar(original);
      final restored = ImmutableStringMapConverter.fromIsar(serialized);

      expect(restored['outer'], isA<Map>());
      expect((restored['outer'] as Map)['inner'], 'value');
    });

    test('round-trip with list values', () {
      final original = <String, dynamic>{
        'items': [1, 2, 3],
      };
      final serialized = ImmutableStringMapConverter.toIsar(original);
      final restored = ImmutableStringMapConverter.fromIsar(serialized);

      expect(restored['items'], [1, 2, 3]);
    });

    test('round-trip with null values', () {
      final original = <String, dynamic>{
        'present': 'yes',
        'absent': null,
      };
      final serialized = ImmutableStringMapConverter.toIsar(original);
      final restored = ImmutableStringMapConverter.fromIsar(serialized);

      expect(restored['present'], 'yes');
      expect(restored['absent'], isNull);
      expect(restored.containsKey('absent'), isTrue);
    });

    test('round-trip with boolean values', () {
      final original = <String, dynamic>{
        'flag': true,
        'disabled': false,
      };
      final serialized = ImmutableStringMapConverter.toIsar(original);
      final restored = ImmutableStringMapConverter.fromIsar(serialized);

      expect(restored['flag'], isTrue);
      expect(restored['disabled'], isFalse);
    });

    test('toIsar produces valid JSON string', () {
      final serialized = ImmutableStringMapConverter.toIsar({'a': 1});
      expect(serialized, '{"a":1}');
    });

    test('fromIsar parses JSON string', () {
      final result = ImmutableStringMapConverter.fromIsar('{"x":"y"}');
      expect(result, {'x': 'y'});
    });

    test('round-trip with CJK content', () {
      final original = <String, dynamic>{
        '日本語': '漢字テスト',
        'key': '吾輩は猫である',
      };
      final serialized = ImmutableStringMapConverter.toIsar(original);
      final restored = ImmutableStringMapConverter.fromIsar(serialized);

      expect(restored['日本語'], '漢字テスト');
      expect(restored['key'], '吾輩は猫である');
    });
  });
}
