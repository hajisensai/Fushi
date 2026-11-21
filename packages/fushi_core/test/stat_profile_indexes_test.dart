import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// video-36i：统计按 Profile 分区的两条索引只在 v105 迁移步里建过，fresh 库的
/// onCreate 漏建——v105 之后新装的库统计页按 `(profile_id, date_key)` 取区间时
/// 全表扫描。修复后 onCreate 建，onUpgrade 末尾也幂等补一次（让已经缺索引的
/// 存量库在下次升 schema 时补齐）。
const List<String> _statIndexes = <String>[
  'idx_study_segments_profile_date',
  'idx_galgame_sessions_profile_date',
];

Future<Set<String>> _indexNames(FushiDatabase db) async => <String>{
  for (final QueryRow row
      in await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
          .get())
    row.read<String>('name'),
};

void main() {
  test('fresh 库建好两条统计分区索引', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(await _indexNames(db), containsAll(_statIndexes));
  });

  test('缺索引的存量库在下一次升 schema 时补齐', () async {
    final Directory dir = Directory.systemTemp.createTempSync('stat_idx');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File file = File('${dir.path}/fushi.db');

    // 模拟「v105 后新装、onCreate 漏建索引」的库：建好后删掉两条索引，再把
    // user_version 退一格，下一次打开走一步 onUpgrade。
    final FushiDatabase seeded = FushiDatabase.forTesting(NativeDatabase(file));
    for (final String name in _statIndexes) {
      await seeded.customStatement('DROP INDEX IF EXISTS $name');
    }
    expect(await _indexNames(seeded), isNot(contains(_statIndexes.first)));
    await seeded.customStatement(
      'PRAGMA user_version = ${kFushiDbSchemaVersion - 1}',
    );
    await seeded.close();

    final FushiDatabase upgraded = FushiDatabase.forTesting(
      NativeDatabase(file),
    );
    addTearDown(upgraded.close);
    expect(await _indexNames(upgraded), containsAll(_statIndexes));
  });
}
