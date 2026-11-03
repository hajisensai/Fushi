// 打开 store 时旧库迁移之前先只拉不发一轮（BUG-4005）：调度器 [SrsSyncScheduler.pullInto] 经 [SrsDbStore.open] 的
// `beforeMigrate` 接进来（app 里由 srs_app_runtime.dart 装到 srs_providers.dart 的 [SrsBeforeMigrateHook]）。第二台
// 设备首次打开、位置上已有第一台迁出的同一份旧库：只包本机独有的旧行，且这一步不往位置写任何东西；位置卡住时
// 最多等预算这么久，照常迁移。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi_core/fushi_core.dart' show srsIdType;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';

import 'srs_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000e9';
const int kT0 = 1700000000000;
const List<String> kShared = <String>[
  '0193a1b2-0000-7000-8000-0000000010a1',
  '0193a1b2-0000-7000-8000-0000000010a2',
];
const String kOnlyB = '0193a1b2-0000-7000-8000-0000000010b1';

/// v2 之前的旧库：几条复习日志直接落在投影表里，没有操作。
Future<SrsStorage> _legacyStorage(List<String> logIds) async {
  final SrsStorage st = await openSrsTestStorage();
  st.core.execBatch(
    <String>[
      'INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, '
          'review_type, origin, duration_ms, jslim) VALUES (srs_id(?), srs_id(?), srs_id(?), ?, ?, ?, ?, ?, ?, ?)',
    ],
    <(int, List<Object?>)>[
      for (int i = 0; i < logIds.length; i++)
        (
          0,
          <Object?>[
            logIds[i],
            kProfile,
            'legacy-card',
            'review',
            3,
            kT0 + i * 1000,
            'review',
            'fushi',
            0,
            jsonEncode(<String, Object?>{
              'id': logIds[i],
              'p': kProfile,
              'card': 'legacy-card',
              'kind': 'review',
              'rating': 3,
              'hlc': '${kT0 + i * 1000}:0:old',
              'at': kT0 + i * 1000,
              'ts': 'anchored',
              'origin': 'fushi',
              'rtype': 'review',
              'utcOff': 0,
              'rollover': 4,
              'fv': 1,
            }),
          ],
        ),
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

Future<SrsDbStore> _open(
  SrsStorage st,
  String device, {
  Future<void> Function(SrsDbStore store)? beforeMigrate,
}) => SrsDbStore.open(
  db: st.db,
  core: st.core,
  profileUid: kProfile,
  deviceId: device,
  engine: const SrsTestEngine(),
  beforeMigrate: beforeMigrate,
);

List<String> _files(Directory root) => <String>[
  for (final FileSystemEntity e in root.listSync(recursive: true))
    if (e is File) e.path,
]..sort();

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_srs_pull_first_');
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄滞后。
    }
  });

  SrsSyncScheduler scheduler({
    SrsChannelRunner? channels,
    bool confirmed = true,
  }) => SrsSyncScheduler(
    readStore: () async => null,
    channels:
        channels ??
        (Future<void> Function(SyncAssetStore) body) async {
          await body(LocalDirectoryAssetStore(root));
          return (ran: 1, errors: const <Object>[]);
        },
    directoryKeyOf: (SyncAssetStore b) async => 'local:${root.path}',
    onDataChanged: () {},
    onNotice: (SrsSyncNotice _) {},
    firstSyncConfirmed: () => confirmed,
  );

  /// A 迁移自己的旧库（两条日志）并上传到 [root]。
  Future<void> seedA() async {
    final SrsStorage stA = await _legacyStorage(kShared);
    final SrsDbStore a = await _open(stA, 'A');
    expect(await _logOps(stA), 2);
    final SrsSync2Report r = await srsSync2Round(
      host: a,
      location: srsAssetLocation(LocalDirectoryAssetStore(root), kProfile),
      locationId: 'local:${root.path}',
      nowMs: () => a.now().$1,
    );
    expect(r.error, isNull);
  }

  test('第二台设备首次打开：迁移前先收，只包本机独有的旧行；这一步不写位置', () async {
    await seedA();
    final List<String> before = _files(root);
    final SrsStorage stB = await _legacyStorage(<String>[...kShared, kOnlyB]);
    final SrsSyncScheduler s = scheduler();
    int pulledBefore = -1;
    await _open(
      stB,
      'B',
      beforeMigrate: (SrsDbStore store) async {
        await s.pullInto(
          store,
          budget: const Duration(seconds: 30),
          purpose: 'migrate',
        );
        pulledBefore = await _logOps(stB);
      },
    );
    expect(pulledBefore, 2, reason: "A's two log ops arrive before migrating");
    expect(await _logOps(stB), 3, reason: 'only the log no device wrapped');
    expect(_files(root), before, reason: 'pull-first writes nothing');
  });

  test('位置卡住：最多等预算这么久，照常迁移；迟到的结果碰不到本机库', () async {
    final Completer<void> never = Completer<void>();
    final SrsStorage stB = await _legacyStorage(<String>[...kShared, kOnlyB]);
    final SrsSyncScheduler s = scheduler(
      channels: (Future<void> Function(SyncAssetStore) body) async {
        await never.future;
        return (ran: 0, errors: const <Object>[]);
      },
    );
    final Stopwatch watch = Stopwatch()..start();
    await _open(
      stB,
      'B',
      beforeMigrate: (SrsDbStore store) => s.pullInto(
        store,
        budget: const Duration(milliseconds: 300),
        purpose: 'migrate',
      ),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(await _logOps(stB), 3, reason: 'nothing pulled: migrate everything');
  });

  test('首次同步还没确认：不拉（与常规同步同一道门）', () async {
    await seedA();
    final SrsStorage stB = await _legacyStorage(<String>[...kShared, kOnlyB]);
    final SrsSyncScheduler s = scheduler(confirmed: false);
    await _open(
      stB,
      'B',
      beforeMigrate: (SrsDbStore store) => s.pullInto(
        store,
        budget: const Duration(seconds: 30),
        purpose: 'migrate',
      ),
    );
    expect(await _logOps(stB), 3);
  });
}
