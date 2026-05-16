import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/creator.dart';

void main() {
  group('CreatorFieldValues', () {
    test('default construction has empty maps', () {
      final values = CreatorFieldValues();

      expect(values.textValues, isEmpty);
      expect(values.extraValues, isEmpty);
    });

    test('copyWith replaces textValues', () {
      final original = CreatorFieldValues(
        textValues: {TermField.instance: '猫'},
      );

      final copy = original.copyWith(
        textValues: {TermField.instance: '犬'},
      );

      expect(copy.textValues[TermField.instance], '犬');
      expect(original.textValues[TermField.instance], '猫');
    });

    test('copyWith replaces extraValues', () {
      final original = CreatorFieldValues(
        extraValues: {'key': 'old'},
      );

      final copy = original.copyWith(extraValues: {'key': 'new'});

      expect(copy.extraValues['key'], 'new');
    });

    test('isExportable is true when textValues is non-empty', () {
      final values = CreatorFieldValues(
        textValues: {TermField.instance: '猫'},
      );

      expect(values.isExportable, isTrue);
    });

    test('isExportable is false when textValues is empty', () {
      final values = CreatorFieldValues();

      expect(values.isExportable, isFalse);
    });
  });
}
