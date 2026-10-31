import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v117（Fushi SRS，docs/specs/2026-10-14-fushi-srs-design.md）：
/// `profiles.uid`（profile 全局身份，存量行回填 UUIDv7）+ 八张 `srs_*` 表
/// （三张同步事件表 + 不认识事件表 + 本机元信息 / 状态 + 两张可重建缓存）+ 索引。
///
/// 迁移全部幂等守卫：v116 库升级后列 / 表 / 索引齐全、存量 profile 行有 uid；
/// 再开一次（或表已存在时重跑该步）不抛异常、不改既有 uid。
///
/// 2026-10-23 起 SRS 归 Rust 的 srs.db（docs/specs/2026-10-23-srs-rust-store.md）：新建的主库
/// 不再有 srs_* 表；迁移阶梯上的老库仍按当年的形状建出它们（`kLegacySrsTableDdl`），好让
/// app 打开 srs.db 时的一次性搬迁原样搬走。
void main() {
  final RegExp uuidV7 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  const List<String> srsTables = <String>[
    'srs_entities',
    'srs_field_edits',
    'srs_review_logs',
    'srs_unknown_events',
    'srs_event_local',
    'srs_local_state',
    'srs_notes_cache',
    'srs_cards_cache',
  ];

  const List<String> srsIndexes = <String>[
    'idx_profiles_uid',
    'idx_srs_entities_profile_kind',
    'idx_srs_field_edits_entity',
    'idx_srs_review_logs_card',
    'idx_srs_review_logs_profile_time',
    'idx_srs_event_local_outbox',
    'idx_srs_notes_cache_term',
    'idx_srs_cards_cache_note',
    'idx_srs_cards_cache_queue',
  ];

  Future<String> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    // 触发 onCreate，建出当前 schema。
    await original.customSelect('SELECT 1').get();
    await original.close();
    return path;
  }

  Set<String> columnsOf(sqlite.Database raw, String table) {
    return <String>{
      for (final sqlite.Row row in raw.select("PRAGMA table_info('$table')"))
        row['name'] as String,
    };
  }

  Set<String> namesOf(sqlite.Database raw, String type) {
    return <String>{
      for (final sqlite.Row row in raw.select(
        'SELECT name FROM sqlite_master WHERE type = ?',
        <Object>[type],
      ))
        row['name'] as String,
    };
  }

  /// 退回 v116 形态：没有 srs_* 表、profiles 没有 uid 列；插两条存量 profile。
  void downgradeToV116(String path) {
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    for (final String t in srsTables) {
      raw.execute('DROP TABLE IF EXISTS $t');
    }
    raw.execute('DROP INDEX idx_profiles_uid');
    raw.execute('ALTER TABLE profiles DROP COLUMN uid');
    raw.execute(
      'INSERT INTO profiles (name, created_at, updated_at) '
      "VALUES ('legacy-a', 1, 1), ('legacy-b', 2, 2)",
    );
    raw.execute('PRAGMA user_version = 116');
    expect(columnsOf(raw, 'profiles').contains('uid'), isFalse);
    raw.dispose();
  }

  test(
    'v116 → v117 adds profiles.uid (backfilled UUIDv7) and still builds the '
    'eight legacy srs tables with their indexes; reopening is idempotent',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync('srs117');
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = await createDbAt(directory);
      downgradeToV116(path);

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(migrated.schemaVersion, 140);
      await migrated.customSelect('SELECT 1').get();
      await migrated.close();

      final sqlite.Database probe = sqlite.sqlite3.open(path);
      expect(probe.select('PRAGMA user_version').first.values.first, 140);
      expect(columnsOf(probe, 'profiles'), contains('uid'));
      final Map<String, String> uidsByName = <String, String>{
        for (final sqlite.Row row in probe.select(
          'SELECT name, uid FROM profiles',
        ))
          row['name'] as String: row['uid'] as String,
      };
      expect(uidsByName.keys, containsAll(<String>['legacy-a', 'legacy-b']));
      for (final MapEntry<String, String> e in uidsByName.entries) {
        expect(e.value, matches(uuidV7), reason: '${e.key} 必须回填 UUIDv7');
      }
      expect(
        uidsByName.values.toSet(),
        hasLength(uidsByName.length),
        reason: 'uid 是全局身份，各行必须不同',
      );

      final Set<String> tables = namesOf(probe, 'table');
      expect(tables, containsAll(srsTables));
      expect(namesOf(probe, 'index'), containsAll(srsIndexes));

      expect(columnsOf(probe, 'srs_entities'), <String>{
        'id',
        'profile_uid',
        'kind',
        'payload_json',
        'created_at',
      });
      expect(
        columnsOf(probe, 'srs_field_edits'),
        containsAll(<String>[
          'id',
          'profile_uid',
          'entity_kind',
          'entity_id',
          'field_key',
          'writer_id',
          'seq',
          'json',
        ]),
      );
      expect(
        columnsOf(probe, 'srs_review_logs'),
        containsAll(<String>[
          'id',
          'profile_uid',
          'card_id',
          'occurred_at',
          'json',
        ]),
      );
      expect(columnsOf(probe, 'srs_unknown_events'), <String>{
        'id',
        'profile_uid',
        'json',
      });
      expect(columnsOf(probe, 'srs_event_local'), <String>{
        'event_id',
        'profile_uid',
        'outbox_seq',
        'server_time',
        'received_at',
      });
      expect(columnsOf(probe, 'srs_local_state'), <String>{
        'profile_uid',
        'json',
      });
      expect(
        columnsOf(probe, 'srs_notes_cache'),
        containsAll(<String>['id', 'profile_uid', 'term_key', 'reading_key']),
      );
      expect(
        columnsOf(probe, 'srs_cards_cache'),
        containsAll(<String>[
          'id',
          'profile_uid',
          'note_id',
          'deck_id',
          'queue',
          'due_day',
          'hidden',
        ]),
      );

      // 让下一次打开重跑 v117 步：表 / 列 / 索引都已在，必须不抛、且不改既有 uid。
      probe.execute('PRAGMA user_version = 116');
      probe.dispose();

      final FushiDatabase reopened = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      await reopened.customSelect('SELECT 1').get();
      await reopened.close();

      final sqlite.Database probe2 = sqlite.sqlite3.open(path);
      addTearDown(probe2.dispose);
      expect(probe2.select('PRAGMA user_version').first.values.first, 140);
      final Map<String, String> uidsAfter = <String, String>{
        for (final sqlite.Row row in probe2.select(
          'SELECT name, uid FROM profiles',
        ))
          row['name'] as String: row['uid'] as String,
      };
      expect(uidsAfter, uidsByName, reason: '重跑迁移步不得改写已有 uid');
      expect(namesOf(probe2, 'table'), containsAll(srsTables));
      expect(namesOf(probe2, 'index'), containsAll(srsIndexes));
    },
  );

  test(
    'a freshly created main database has no srs tables (they live in srs.db)',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'srs117new',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = await createDbAt(directory);
      final sqlite.Database probe = sqlite.sqlite3.open(path);
      addTearDown(probe.dispose);
      expect(
        namesOf(probe, 'table').where((String t) => t.startsWith('srs_')),
        isEmpty,
      );
      expect(columnsOf(probe, 'profiles'), contains('uid'));
      expect(namesOf(probe, 'index'), contains('idx_profiles_uid'));
    },
  );

  test(
    'profileUidOf lazily fills a missing uid once and then keeps it',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'srs117lazy',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = await createDbAt(directory);

      final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
      addTearDown(db.close);
      // 新插入的 profile 行（各处插入点不写 uid）。
      await db.customStatement(
        'INSERT INTO profiles (name, uid, created_at, updated_at) '
        "VALUES ('fresh', NULL, 1, 1), ('blank', '', 2, 2)",
      );
      final List<QueryRow> rows = await db
          .customSelect(
            "SELECT id, name FROM profiles WHERE name IN ('fresh', 'blank')",
          )
          .get();
      expect(rows, hasLength(2));

      final Set<String> seen = <String>{};
      for (final QueryRow row in rows) {
        final int id = row.read<int>('id');
        final String first = await db.profileUidOf(id);
        expect(first, matches(uuidV7));
        expect(await db.profileUidOf(id), first, reason: '补齐后再读必须稳定');
        final String stored =
            (await db
                    .customSelect(
                      'SELECT uid FROM profiles WHERE id = ?',
                      variables: <Variable<Object>>[Variable<int>(id)],
                    )
                    .getSingle())
                .read<String>('uid');
        expect(stored, first, reason: '补齐的 uid 必须写回库');
        seen.add(first);
      }
      expect(seen, hasLength(2));

      await expectLater(db.profileUidOf(987654), throwsStateError);
    },
  );
}
