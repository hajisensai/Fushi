// 两台设备迁移同一份旧库（BUG-4005：宿主与 01a173ca 各自把同一份旧库包成了自己的操作流，操作日志里每条旧记录
// 各有两份）：迁移只包还没有任何设备的操作代表的旧行（内核 store/sync2/mod.rs `enqueue_legacy_rows`）。B 打开时先经
// [SrsDbStore.open] 的 `beforeMigrate` 收一轮 A 已上传的操作，再迁移：A 迁出过的旧日志一条不再包，只包 B 独有的那条。
import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow, Variable, driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show srsIdType;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000e8';
const int kT0 = 1700000000000;

/// 旧库里的一条复习日志（v2 之前的行：直接落在投影表里，没有操作）。
List<Object?> _legacyLog(String id, int at) => <Object?>[
  id,
  kProfile,
  'legacy-card',
  'review',
  3,
  at,
  'review',
  'fushi',
  0,
  jsonEncode(<String, Object?>{
    'id': id,
    'p': kProfile,
    'card': 'legacy-card',
    'kind': 'review',
    'rating': 3,
    'hlc': '$at:0:old',
    'at': at,
    'ts': 'anchored',
    'origin': 'fushi',
    'rtype': 'review',
    'utcOff': 0,
    'rollover': 4,
    'fv': 1,
    'res': <String, Object?>{
      'queue': 'review',
      'dueDay': 19700,
      'ivl': 40,
      'step': 0,
      'reps': 2,
      'lapses': 0,
      'scheduler': 'fushi',
      'memory': <String, Object?>{'s': 41.5, 'd': 5.25, 'sf': 0.0},
      'lastReviewedAt': at,
    },
  }),
];

Future<SrsStorage> _legacyStorage(List<String> logIds) async {
  final SrsStorage st = await openTestSrsStorage();
  st.core.execBatch(
    <String>[
      'INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, '
          'review_type, origin, duration_ms, jslim) VALUES (srs_id(?), srs_id(?), srs_id(?), ?, ?, ?, ?, ?, ?, ?)',
    ],
    <(int, List<Object?>)>[
      for (int i = 0; i < logIds.length; i++)
        (0, _legacyLog(logIds[i], kT0 + i * 1000)),
    ],
  );
  return st;
}

Future<int> _logOps(SrsStorage st) async {
  final QueryRow r = await st.db
      .customSelect(
        'SELECT COUNT(*) AS c FROM sync2_ops WHERE profile_uid = ? AND kind = 3',
        variables: <Variable<Object>>[Variable<String>(kProfile, srsIdType)],
      )
      .getSingle();
  return r.read<int>('c');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsSync2Report> round(SrsDbStore s, SrsLocationStore loc) =>
      srsSync2Round(
        host: s,
        location: loc,
        locationId: 'loc',
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
      );

  test('第二台设备迁移同一份旧库：先收后迁，只包本机独有的旧行', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    const List<String> shared = <String>[
      '0193a1b2-0000-7000-8000-0000000010a1',
      '0193a1b2-0000-7000-8000-0000000010a2',
    ];
    const String onlyB = '0193a1b2-0000-7000-8000-0000000010b1';

    final SrsStorage stA = await _legacyStorage(shared);
    final SrsDbStore a = await SrsDbStore.open(
      db: stA.db,
      core: stA.core,
      profileUid: kProfile,
      deviceId: 'A',
    );
    expect(await _logOps(stA), 2);
    expect((await round(a, loc)).error, isNull);

    final SrsStorage stB = await _legacyStorage(<String>[...shared, onlyB]);
    int pulledBefore = -1;
    final SrsDbStore b = await SrsDbStore.open(
      db: stB.db,
      core: stB.core,
      profileUid: kProfile,
      deviceId: 'B',
      beforeMigrate: (SrsDbStore s) async {
        expect((await round(s, loc)).error, isNull);
        pulledBefore = await _logOps(stB);
      },
    );
    expect(pulledBefore, 2, reason: "B holds A's two log ops before migrating");
    expect(
      await _logOps(stB),
      3,
      reason: 'B wrapped only its own legacy log, not the two A already did',
    );

    for (int i = 0; i < 2; i++) {
      expect((await round(b, loc)).error, isNull);
      expect((await round(a, loc)).error, isNull);
    }
    expect(await _logOps(stA), 3);
    expect((await a.sync2Status())['pending'], 0);
    expect((await b.sync2Status())['pending'], 0);

    // 已迁移：重开不再调用 beforeMigrate、不再包。
    bool called = false;
    await SrsDbStore.open(
      db: stB.db,
      core: stB.core,
      profileUid: kProfile,
      deviceId: 'B',
      beforeMigrate: (SrsDbStore s) async => called = true,
    );
    expect(called, isFalse);
    expect(await _logOps(stB), 3);
  });
}
