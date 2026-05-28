import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

void main() {
  group('ShortcutAction', () {
    test('every action has a scope', () {
      for (final action in ShortcutAction.values) {
        expect(action.scope, isA<ShortcutScope>());
      }
    });

    test('every action has a non-empty serialization key', () {
      for (final action in ShortcutAction.values) {
        expect(action.key, isNotEmpty);
      }
    });

    test('serialization keys are unique', () {
      final keys = ShortcutAction.values.map((a) => a.key).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('fromKey round-trips for all actions', () {
      for (final action in ShortcutAction.values) {
        expect(ShortcutAction.fromKey(action.key), action);
      }
    });

    test('fromKey returns null for unknown key', () {
      expect(ShortcutAction.fromKey('nonexistent_action'), isNull);
    });

    test('actionsForScope filters correctly', () {
      final readerActions = ShortcutAction.actionsForScope(ShortcutScope.reader);
      expect(readerActions, isNotEmpty);
      for (final action in readerActions) {
        expect(action.scope, ShortcutScope.reader);
      }
    });
  });
}
