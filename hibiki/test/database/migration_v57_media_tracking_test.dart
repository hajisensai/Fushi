import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  test('v56 upgrade creates mappings before the outbox foreign key', () async {
    final HibikiDatabase db = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA user_version = 56');
        },
      ),
    );
    addTearDown(db.close);

    final List<QueryRow> tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name LIKE 'media_tracking_%' ORDER BY name",
        )
        .get();

    expect(
      tables.map((QueryRow row) => row.read<String>('name')).toList(),
      <String>['media_tracking_mappings', 'media_tracking_outbox'],
    );
    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 57);
  });
}
