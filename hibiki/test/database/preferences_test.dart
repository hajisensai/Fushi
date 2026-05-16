import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/database/database.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('Preferences table', () {
    test('setPref and getPref round-trip a value', () async {
      final db = await _openDb();

      await db.setPref('theme', 'dark');

      expect(await db.getPref('theme'), 'dark');
    });

    test('getPref returns null for absent key', () async {
      final db = await _openDb();

      expect(await db.getPref('nonexistent'), isNull);
    });

    test('setPref overwrites existing value', () async {
      final db = await _openDb();

      await db.setPref('lang', 'en');
      await db.setPref('lang', 'ja');

      expect(await db.getPref('lang'), 'ja');
    });

    test('deletePref removes a key', () async {
      final db = await _openDb();
      await db.setPref('temp', 'value');

      await db.deletePref('temp');

      expect(await db.getPref('temp'), isNull);
    });

    test('deletePref on absent key is a no-op', () async {
      final db = await _openDb();

      await db.deletePref('ghost');

      expect(await db.getPref('ghost'), isNull);
    });

    test('getAllPrefs returns all stored pairs', () async {
      final db = await _openDb();
      await db.setPref('a', '1');
      await db.setPref('b', '2');

      final all = await db.getAllPrefs();

      expect(all, containsPair('a', '1'));
      expect(all, containsPair('b', '2'));
    });

    test('getPrefTyped returns default for absent key', () async {
      final db = await _openDb();

      final result = await db.getPrefTyped<int>('missing', 42);

      expect(result, 42);
    });

    test('setPrefTyped and getPrefTyped round-trip an int', () async {
      final db = await _openDb();

      await db.setPrefTyped<int>('count', 7);

      expect(await db.getPrefTyped<int>('count', 0), 7);
    });

    test('setPrefTyped and getPrefTyped round-trip a bool', () async {
      final db = await _openDb();

      await db.setPrefTyped<bool>('enabled', true);

      expect(await db.getPrefTyped<bool>('enabled', false), true);
    });
  });
}
