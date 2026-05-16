import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/converters/quick_actions_converter.dart';

void main() {
  group('QuickActionsConverter', () {
    test('round-trip serialization preserves data', () {
      final original = <int, String>{
        0: 'copy',
        1: 'share',
        5: 'search_web',
      };

      final json = QuickActionsConverter.toIsar(original);
      final restored = QuickActionsConverter.fromIsar(json);

      expect(restored, original);
    });

    test('empty map serializes and deserializes correctly', () {
      final original = <int, String>{};

      final json = QuickActionsConverter.toIsar(original);
      final restored = QuickActionsConverter.fromIsar(json);

      expect(restored, isEmpty);
    });

    test('toIsar produces valid JSON with string keys', () {
      final data = <int, String>{3: 'action'};

      final json = QuickActionsConverter.toIsar(data);

      expect(json, '{"3":"action"}');
    });

    test('fromIsar parses int keys from JSON string keys', () {
      const json = '{"7":"lookup","99":"bookmark"}';

      final result = QuickActionsConverter.fromIsar(json);

      expect(result[7], 'lookup');
      expect(result[99], 'bookmark');
    });
  });
}
