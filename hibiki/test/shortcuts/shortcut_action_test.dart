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
      final readerActions =
          ShortcutAction.actionsForScope(ShortcutScope.reader);
      expect(readerActions, isNotEmpty);
      for (final action in readerActions) {
        expect(action.scope, ShortcutScope.reader);
      }
    });
  });

  group('ShortcutScope.coactiveScopes', () {
    test('reader and audiobook share one co-active group', () {
      expect(
          ShortcutScope.reader.coactiveScopes,
          containsAll(
              <ShortcutScope>[ShortcutScope.reader, ShortcutScope.audiobook]));
      expect(ShortcutScope.audiobook.coactiveScopes,
          ShortcutScope.reader.coactiveScopes);
    });

    test('home and global share one co-active group', () {
      expect(
          ShortcutScope.home.coactiveScopes,
          containsAll(
              <ShortcutScope>[ShortcutScope.home, ShortcutScope.global]));
      expect(ShortcutScope.global.coactiveScopes,
          ShortcutScope.home.coactiveScopes);
    });

    test('the two groups are disjoint', () {
      final readerGroup = ShortcutScope.reader.coactiveScopes.toSet();
      final homeGroup = ShortcutScope.home.coactiveScopes.toSet();
      expect(readerGroup.intersection(homeGroup), isEmpty);
    });

    test('every scope belongs to its own co-active group', () {
      for (final scope in ShortcutScope.values) {
        expect(scope.coactiveScopes, contains(scope));
      }
    });
  });
}
