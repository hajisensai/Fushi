// 推迟的旧库迁移（BUG-4011）：app 打开 store 时 `deferMigration`（srs_providers.dart），首次同步确认弹框没回答前
// 不迁移、也不拉；确认之后、第一轮上传之前，调度器 [SrsSyncScheduler.ensureMigrated] 先从同步位置只拉不发收一轮再
// 迁移。第二台设备、位置上已有第一台迁出的同一份旧库：只包本机独有的旧行，且拉取这一步不往位置写任何东西；位置
// 卡住时最多等预算这么久，照常迁移；一轮里（拿着通道锁）只从那条通道收、不重入通道锁；档案合并（冲突弹窗选定）在
// 候选所在那条通道的锁里做，并入前从它收。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi_core/fushi_core.dart' show srsIdType;
import 'package:fushi_engine/srs/srs_builtin.dart' show srsLapisFieldId;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
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

/// 本 profile 的日志操作：条数与来自几台设备。
Future<({int ops, int devices})> _logOps(SrsStorage st) async {
  final QueryRow r = await st.db
      .customSelect(
        'SELECT COUNT(*) AS c, COUNT(DISTINCT device) AS d FROM sync2_ops '
        'WHERE profile_uid = ? AND kind = 3',
        variables: <Variable<Object>>[Variable<String>(kProfile, srsIdType)],
      )
      .getSingle();
  return (ops: r.read<int>('c'), devices: r.read<int>('d'));
}

Future<SrsDbStore> _open(
  SrsStorage st,
  String device, {
  bool deferMigration = false,
}) => SrsDbStore.open(
  db: st.db,
  core: st.core,
  profileUid: kProfile,
  deviceId: device,
  engine: const SrsTestEngine(),
  deferMigration: deferMigration,
);

List<String> _files(Directory root) => <String>[
  for (final FileSystemEntity e in root.listSync(recursive: true))
    if (e is File) e.path,
]..sort();

/// 只记下 [adopt] 收到的通道。
class _RecordingLinker implements SrsProfileLinker {
  final List<SyncAssetStore?> adoptedWithin = <SyncAssetStore?>[];

  @override
  Future<SrsProfileLinkOutcome> link(
    SyncAssetStore backend,
    SrsDbStore store,
  ) async => SrsProfileLinkOutcome(store);

  @override
  Future<SrsDbStore> adopt(
    SrsDbStore store,
    String uid, {
    SyncAssetStore? within,
  }) async {
    adoptedWithin.add(within);
    return store;
  }

  @override
  Future<void> publish(
    SyncAssetStore backend,
    SrsDbStore store,
    String directoryKey,
  ) async {}
}

void main() {
  late Directory root;
  late LocalDirectoryAssetStore backend;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_srs_pull_first_');
    backend = LocalDirectoryAssetStore(root);
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄滞后。
    }
  });

  /// 通道运行器：同一时刻只许一个（与 app 的通道锁一样不可重入），重入直接抛。
  bool inChannels = false;
  Future<({int ran, List<Object> errors})> channelsOf(
    Future<void> Function(SyncAssetStore) body,
  ) async {
    if (inChannels) throw StateError('channel lock re-entered');
    inChannels = true;
    try {
      await body(backend);
      return (ran: 1, errors: const <Object>[]);
    } finally {
      inChannels = false;
    }
  }

  /// 假的一轮同步：只记下这一轮开跑时本机的迁移状态，不往位置写。
  final List<({bool migrated, int ops, int devices})> rounds =
      <({bool migrated, int ops, int devices})>[];
  SrsSyncRunner recordingRunner(SrsStorage st) =>
      (
        SyncAssetStore b,
        SrsDbStore store,
        String key, {
        SrsLocationKey? locationKey,
      }) async {
        final ({int ops, int devices}) l = await _logOps(st);
        rounds.add((
          migrated: store.sync2Migrated,
          ops: l.ops,
          devices: l.devices,
        ));
        return SrsSync2Report();
      };

  SrsSyncScheduler scheduler({
    required SrsDbStore? store,
    SrsChannelRunner? channels,
    bool Function()? confirmed,
    SrsSyncRunner? runner,
    SrsProfileLinker? linker,
    Duration migratePullBudget = const Duration(seconds: 30),
  }) => SrsSyncScheduler(
    readStore: () async => store,
    channels: channels ?? channelsOf,
    directoryKeyOf: (SyncAssetStore b) async => 'local:${root.path}',
    onDataChanged: () {},
    onNotice: (SrsSyncNotice _) {},
    firstSyncConfirmed: confirmed ?? () => true,
    runner: runner,
    profileLinker: linker,
    migratePullBudget: migratePullBudget,
  );

  /// A 迁移自己的旧库（两条日志）并上传到 [root]。
  Future<void> seedA() async {
    final SrsStorage stA = await _legacyStorage(kShared);
    final SrsDbStore a = await _open(stA, 'A');
    expect((await _logOps(stA)).ops, 2);
    final SrsSync2Report r = await srsSync2Round(
      host: a,
      location: srsAssetLocation(backend, kProfile),
      locationId: 'local:${root.path}',
      nowMs: () => a.now().$1,
    );
    expect(r.error, isNull);
  }

  setUp(() {
    inChannels = false;
    rounds.clear();
  });

  test('确认弹框没回答前：打开不迁移、同步不拉也不迁移；确认后那一轮先收再迁移、只包本机独有的', () async {
    await seedA();
    final List<String> before = _files(root);
    final SrsStorage stB = await _legacyStorage(<String>[...kShared, kOnlyB]);
    final SrsDbStore b = await _open(stB, 'B', deferMigration: true);
    expect(b.sync2Migrated, isFalse);
    expect((await _logOps(stB)).ops, 0, reason: 'open does not migrate');

    bool confirmed = false;
    final SrsSyncScheduler s = scheduler(
      store: b,
      confirmed: () => confirmed,
      runner: recordingRunner(stB),
    );
    await s.syncNow();
    expect(b.sync2Migrated, isFalse, reason: 'unanswered: no migration');
    expect((await _logOps(stB)).ops, 0, reason: 'unanswered: nothing pulled');
    expect(rounds, isEmpty);
    expect(_files(root), before);

    confirmed = true;
    await s.syncNow();
    expect(b.sync2Migrated, isTrue);
    expect(rounds, isNotEmpty);
    expect(
      rounds.first,
      (migrated: true, ops: 3, devices: 2),
      reason:
          "A's two ops pulled first, only B's own log wrapped, before "
          'any round uploads',
    );
    expect(_files(root), before, reason: 'pull-first writes nothing');
  });

  test('一轮里（拿着通道锁）遇到没迁移的库：只从这条通道收，不重入通道锁', () async {
    await seedA();
    final SrsStorage stB = await _legacyStorage(<String>[...kShared, kOnlyB]);
    final SrsDbStore b = await _open(stB, 'B', deferMigration: true);
    final SrsSyncScheduler s = scheduler(
      store: b,
      runner: recordingRunner(stB),
    );
    // 自动同步的一轮：通道锁里跑这条通道（app 的 runOnAuthenticatedSyncChannels → autoSyncWithBackend）。
    await channelsOf((SyncAssetStore x) async {
      final SrsSync2Report r = await s.syncWithBackend(x);
      expect(r.error, isNull);
    });
    expect(rounds.single, (migrated: true, ops: 3, devices: 2));
  });

  test('持锁的一轮与收全部通道的迁移并发：不互等、远在预算内做完，迁移前拉到了这条通道', () async {
    await seedA();
    final SrsStorage stB = await _legacyStorage(<String>[...kShared, kOnlyB]);
    final SrsDbStore b = await _open(stB, 'B', deferMigration: true);
    // 与 app 的通道锁一样：排队等、FIFO。第二个进来排队的（[syncNow] 开头那份迁移的拉取）到了就放开持锁的一轮。
    Future<void> lockTail = Future<void>.value();
    int entered = 0;
    final Completer<void> migrationQueued = Completer<void>();
    Future<({int ran, List<Object> errors})> lock(
      Future<void> Function(SyncAssetStore) body,
    ) async {
      final Future<void> prev = lockTail;
      final Completer<void> mine = Completer<void>();
      lockTail = mine.future;
      if (++entered == 2) migrationQueued.complete();
      try {
        await prev;
        await body(backend);
        return (ran: 1, errors: const <Object>[]);
      } finally {
        mine.complete();
      }
    }

    final SrsSyncScheduler s = scheduler(
      store: b,
      channels: lock,
      runner: recordingRunner(stB),
      // 预算远大于测试超时：靠预算到点解开的互等在这里就是超时失败。
      migratePullBudget: const Duration(hours: 1),
    );
    final Completer<void> go = Completer<void>();
    // 自动同步的后置步骤：拿着通道锁跑这条通道的一轮。
    final Future<void> held = lock((SyncAssetStore x) async {
      await go.future;
      final SrsSync2Report r = await s.syncWithBackend(x);
      expect(r.error, isNull);
    });
    // 「立即同步」：锁外发起收全部通道的迁移，它的拉取排在持锁的一轮后面。
    final Future<SrsSyncNowResult> all = s.syncNow();
    await migrationQueued.future;
    go.complete();
    await Future.wait(<Future<Object?>>[
      held,
      all,
    ]).timeout(const Duration(seconds: 30));
    expect(b.sync2Migrated, isTrue);
    expect(
      rounds.first,
      (migrated: true, ops: 3, devices: 2),
      reason:
          "the held round pulled A's two ops from its channel before "
          'migrating, so only B-only legacy log was wrapped',
    );
    expect(await _logOps(stB), (ops: 3, devices: 2));
  });

  test('推迟的迁移分批进出独占区：迁移中途发起的评分排在当前这一批之后，不等全部批次', () async {
    final List<String> ids = <String>[
      for (int i = 0; i < 6; i++) '0193a1b2-0000-7000-8000-0000000020a$i',
    ];
    final SrsStorage st = await _legacyStorage(ids);
    final SrsDbStore b = await _open(st, 'B', deferMigration: true);
    final String note = await b.createNote(
      noteTypeId: b.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '雪',
      },
    );
    final String card = (await b.cardsOfNote(note)).first.id;

    // 先占住独占区，让迁移的第一批、评分、探针按这个顺序排进 FIFO。
    final Completer<void> gate = Completer<void>();
    final Future<void> hold = b.runExclusive(() => gate.future);
    final Future<void> migration = b.migrateLegacy(batch: 1);
    bool? migratedWhenAnswered;
    final Future<void> answered = b.answer(card, 3).then((_) {
      migratedWhenAnswered = b.sync2Migrated;
    });
    int? queuedAfterAnswer;
    final Future<void> probe = b.runExclusive(() async {
      final QueryRow r = await st.db
          .customSelect('SELECT COUNT(*) AS c FROM sync2_migrate_queue')
          .getSingle();
      queuedAfterAnswer = r.read<int>('c');
    });
    gate.complete();
    await Future.wait(<Future<void>>[hold, migration, answered, probe]);

    expect(
      migratedWhenAnswered,
      isFalse,
      reason: 'the rating ran between batches, not after the whole migration',
    );
    expect(
      queuedAfterAnswer,
      ids.length - 1,
      reason: 'one batch of one row done before the rating',
    );
    expect(b.sync2Migrated, isTrue);
    expect(await _logOps(st), (
      ops: ids.length + 1,
      devices: 1,
    ), reason: 'every legacy log wrapped once, plus the interleaved rating');
  });

  test('位置卡住：最多等预算这么久，照常迁移；迟到的结果碰不到本机库', () async {
    final Completer<void> never = Completer<void>();
    final SrsStorage stB = await _legacyStorage(<String>[...kShared, kOnlyB]);
    final SrsDbStore b = await _open(stB, 'B', deferMigration: true);
    final SrsSyncScheduler s = scheduler(
      store: b,
      channels: (Future<void> Function(SyncAssetStore) body) async {
        await never.future;
        return (ran: 0, errors: const <Object>[]);
      },
      migratePullBudget: const Duration(milliseconds: 300),
    );
    final Stopwatch watch = Stopwatch()..start();
    await s.ensureMigrated(b);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(b.sync2Migrated, isTrue);
    expect(await _logOps(stB), (
      ops: 3,
      devices: 1,
    ), reason: 'nothing pulled: migrate everything');
  });

  test('冲突弹窗选定候选：在候选所在那条通道的锁里并入，并入拿得到那条通道', () async {
    final SrsStorage st = await _legacyStorage(kShared);
    final SrsDbStore store = await _open(st, 'B');
    final _RecordingLinker linker = _RecordingLinker();
    final SrsSyncScheduler s = scheduler(
      store: store,
      linker: linker,
      runner: recordingRunner(st),
    );
    await s.adoptProfile(
      SrsProfileConflict(
        directoryKey: 'local:${root.path}',
        localUid: kProfile,
        candidates: const <SrsRemoteProfile>[],
        localHasNotes: true,
      ),
      '01928c3e-0000-7000-8000-0000000000ea',
    );
    expect(linker.adoptedWithin, <SyncAssetStore?>[backend]);
  });
}
