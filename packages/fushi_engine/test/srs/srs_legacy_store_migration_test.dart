// 主库 SRS 表 → srs.db 的一次性搬迁（docs/specs/2026-10-23-srs-rust-store.md §3）。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_legacy_store_migration.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'support/srs_test_storage.dart';
import 'apkg/srs_apkg_import_test.dart'
    show
        crtSecs,
        kBasic,
        kDeckJp,
        kDeckLang,
        kFullOptions,
        legacyDconf,
        legacyDecks,
        legacyModels,
        ms;

Uint8List _apkg(int notes) {
  final int base = ms(2025, 1, 1);
  return zipOf(<String, List<int>>{
    'collection.anki21': buildLegacyCollection(
      crtSecs: crtSecs,
      conf: <String, Object?>{'rollover': 4, 'localOffset': 0, 'fsrs': true},
      models: legacyModels(),
      decks: legacyDecks(),
      dconf: legacyDconf(),
      notes: <FxNote>[
        for (int i = 0; i < notes; i++)
          FxNote(
            id: base + i,
            guid: 'mig-$i',
            mid: kBasic,
            fields: <String>['語$i', '例文😀$i'],
            tags: <String>['t'],
            cards: <FxCard>[
              for (int ord = 0; ord < 2; ord++)
                FxCard(
                  id: (base + i) * 2 + ord,
                  ord: ord,
                  did: ord == 0 ? kDeckJp : kDeckLang,
                  type: 2,
                  queue: 2,
                  due: 30,
                  ivl: 10,
                  factor: 2500,
                  reps: 3,
                  revlog: <FxRevlog>[
                    for (int k = 0; k < 3; k++)
                      FxRevlog(
                        base + i * 1000 + ord * 100 + k + 86400000 * k,
                        type: k == 0 ? 0 : 1,
                        ease: 3,
                        ivl: k == 0 ? -600 : 3 * k,
                      ),
                  ],
                ),
            ],
          ),
      ],
    ),
  });
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late FushiDatabase db;
  late SrsCore core;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('srs_legacy_mig_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    for (final String ddl in kLegacySrsTableDdl.values) {
      await db.customStatement(ddl);
    }
    core = SrsCore.open('${tmp.path}${Platform.pathSeparator}srs.db');
  });
  tearDown(() async {
    core.close();
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放。
    }
  });

  test('column lists match the Drift tables exactly', () async {
    for (final (String table, List<String> columns) in kSrsLegacyTables) {
      final List<QueryRow> info = await db
          .customSelect('PRAGMA table_info($table)')
          .get();
      expect(
        <String>[for (final QueryRow r in info) r.read<String>('name')],
        columns,
        reason: table,
      );
    }
  });

  test('copies every row byte-for-byte, then drops the old tables', () async {
    // 先在一份新的 srs.db 上造数据，再抄进主库的旧表形态。
    final SrsStorage gen = await openTestSrsStorage();
    final SrsDbStore store = await SrsDbStore.open(
      db: gen.db,
      core: gen.core,
      profileUid: '01928c3e-0000-7000-8000-00000000a11a',
      deviceId: 'mig',
      engine: const FakeFsrsEngine(),
      fallbackRolloverHour: () => 4,
    );
    await importAnkiPackage(
      store: store,
      bytes: _apkg(40),
      storeMedia: (String name, Uint8List b) async => name,
      options: kFullOptions,
      zstdDecompress: (Uint8List b) => null,
    );
    await store.setFlag((await store.allCardRows()).first.id, 2);
    await copySrsRowsToLegacyTables(gen.db, db);

    final Map<String, List<Map<String, Object?>>> before =
        <String, List<Map<String, Object?>>>{};
    for (final (String table, List<String> columns) in kSrsLegacyTables) {
      before[table] = <Map<String, Object?>>[
        for (final QueryRow r
            in await db
                .customSelect(
                  'SELECT ${columns.join(', ')} FROM $table ORDER BY 1, 2',
                )
                .get())
          r.data,
      ];
    }
    expect(before['srs_review_logs'], isNotEmpty);
    expect(before['srs_cards_cache'], isNotEmpty);
    expect(before['srs_local_state'], isNotEmpty);

    final SrsLegacyMigration result = await srsMigrateLegacyStore(
      db: db,
      core: core,
    );
    expect(result.migrated, isTrue);
    expect(core.legacyImported, isTrue);
    for (final (String table, List<String> columns) in kSrsLegacyTables) {
      final List<Map<String, Object?>> after = core.debugQuery(
        'SELECT ${columns.join(', ')} FROM $table ORDER BY 1, 2',
      );
      expect(after, before[table], reason: table);
      expect(result.rowsByTable[table], before[table]!.length, reason: table);
    }
    final List<QueryRow> left = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE name LIKE 'srs\\_%' ESCAPE '\\'",
        )
        .get();
    expect(left, isEmpty);

    // 再跑一次：标记已在、旧表已删，什么都不做。
    final SrsLegacyMigration again = await srsMigrateLegacyStore(
      db: db,
      core: core,
    );
    expect(again.migrated, isFalse);
  });

  test('fresh install: no legacy tables, only the marker is written', () async {
    for (final (String table, _) in kSrsLegacyTables) {
      await db.customStatement('DROP TABLE IF EXISTS $table');
    }
    final SrsLegacyMigration result = await srsMigrateLegacyStore(
      db: db,
      core: core,
    );
    expect(result.migrated, isFalse);
    expect(core.legacyImported, isTrue);
  });

  test('a failed page rolls the whole import back', () async {
    await db.customStatement(
      'INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) '
      "VALUES ('e', 'p', 'deck', '{}', 0)",
    );
    // 主键冲突：同一个事件 ID 两行（旧库不可能这样，这里只为让第二页失败）。
    await db.customStatement('DROP TABLE srs_unknown_events');
    await db.customStatement(
      'CREATE TABLE srs_unknown_events (id TEXT, profile_uid TEXT, json TEXT)',
    );
    await db.customStatement(
      "INSERT INTO srs_unknown_events VALUES ('u', 'p', '{}'), ('u', 'p', '{}')",
    );
    await expectLater(
      srsMigrateLegacyStore(db: db, core: core),
      throwsA(isA<SrsCoreException>()),
    );
    expect(core.legacyImported, isFalse);
    expect(
      core.debugQuery('SELECT COUNT(*) AS n FROM srs_entities'),
      <Map<String, Object?>>[
        <String, Object?>{'n': 0},
      ],
    );
    // 旧表原样还在（没删）。
    final List<QueryRow> still = await db
        .customSelect('SELECT COUNT(*) AS n FROM srs_entities')
        .get();
    expect(still.single.read<int>('n'), 1);
  });
}
