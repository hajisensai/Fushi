import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  test('v57 upgrade creates mappings before the outbox foreign key', () async {
    final HibikiDatabase db = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA user_version = 57');
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
    // 本用例守的是「v57 库能被迁到 v58 的 media_tracking 阶梯之上」，不是「终点恰好
    // 是 58」——写死 58 会让每次 schema bump 都无辜变红（本次 bump 到 59 即已发生）。
    // 判据改成「至少到 58」+「等于当前 schemaVersion」，语义不变且不随 bump 失效。
    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), greaterThanOrEqualTo(58));
    expect(version.read<int>('user_version'), db.schemaVersion);
  });
}
