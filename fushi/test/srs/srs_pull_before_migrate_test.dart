// 推迟的旧库迁移（BUG-4011）：app 打开 store 时 `deferMigration`（srs_providers.dart），首次同步确认弹框没回答前
// 不迁移、也不拉；确认之后、第一轮上传之前，调度器 [SrsSyncScheduler.ensureMigrated] 先从同步位置只拉不发收一轮再
// 迁移。第二台设备、位置上已有第一台迁出的同一份旧库：只包本机独有的旧行，且拉取这一步不往位置写任何东西；拉取
// 按进度判（一直有进展就等到收齐，哪怕远超旧的 2 分钟预算；连续停滞才放弃、照常迁移；位置上没有集合立即迁移，
// 计时器用可控时钟、不做真实等待）；一轮里（拿着通道锁）只从那条通道收、不重入通道锁；档案合并（冲突弹窗选定）在
// 候选所在那条通道的锁里做，并入前从它收，等多久与迁移之前同一套（按进度判：持续有进展就等到收齐、并入沿用目标的
// 写入者；停滞 / 到总上限才放弃、照常并入）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, ProfilesCompanion, srsIdType;
import 'package:fushi_engine/srs/srs_builtin.dart' show srsLapisFieldId;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_profile_merge.dart'
    show kSrsMergedWriterPrefix;
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_pull_first.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

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

/// 可控时钟：[create] 交给调度器当只拉不发的计时器工厂；[pace] 是假的网络耗时。
class _FakeTime {
  Duration now = Duration.zero;
  final List<_FakeTimer> _timers = <_FakeTimer>[];

  Timer create(Duration d, void Function() callback) =>
      _add(_FakeTimer(now + d, callback, pace: false));

  _FakeTimer _add(_FakeTimer t) {
    _timers.add(t);
    return t;
  }

  /// 一次读取要花 [d]（假时钟）。
  Future<void> pace(Duration d) {
    final Completer<void> c = Completer<void>();
    _add(_FakeTimer(now + d, c.complete, pace: true));
    return c.future;
  }

  /// 有读取在等假时钟：拨到最早的那个读取到点，途中到点的计时器（停滞 / 上限）按先后一并触发；返回 false = 此刻
  /// 没有读取在等（被测代码在做真实的本地 IO / 内核调用）。不在没有读取在等时拨钟：那时拨就是凭空制造停滞。
  bool step() {
    final List<_FakeTimer> paces = <_FakeTimer>[
      for (final _FakeTimer t in _timers)
        if (t.isActive && t.pace) t,
    ];
    if (paces.isEmpty) return false;
    final Duration to = paces
        .map((_FakeTimer t) => t.at)
        .reduce((Duration a, Duration b) => a < b ? a : b);
    final List<_FakeTimer> due =
        _timers.where((_FakeTimer t) => t.isActive && t.at <= to).toList()
          ..sort((_FakeTimer a, _FakeTimer b) => a.at.compareTo(b.at));
    for (final _FakeTimer t in due) {
      if (!t.isActive) continue;
      now = t.at;
      t.fire();
    }
    now = to;
    return true;
  }

  /// 把时钟拨到 [to]（只用于没有读取在等、要让停滞 / 上限到点的情形）。
  void jump(Duration to) {
    final List<_FakeTimer> due =
        _timers.where((_FakeTimer t) => t.isActive && t.at <= to).toList()
          ..sort((_FakeTimer a, _FakeTimer b) => a.at.compareTo(b.at));
    for (final _FakeTimer t in due) {
      if (!t.isActive) continue;
      now = t.at;
      t.fire();
    }
    now = to;
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.at, this._callback, {required this.pace});

  final Duration at;
  final bool pace;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// 每次读（列目录 / 找文件 / 下载）都要花假时钟 [each] 的位置；写入原样转发（只拉不发不该有写入）。
class _SlowStore implements SyncAssetStore {
  _SlowStore(this._inner, this._time, this.each);

  final SyncAssetStore _inner;
  final _FakeTime _time;
  final Duration each;
  int reads = 0;

  Future<T> _slow<T>(Future<T> Function() body) async {
    reads++;
    await _time.pace(each);
    return body();
  }

  @override
  Future<String> ensureNamespace(String name) =>
      _slow(() => _inner.ensureNamespace(name));

  @override
  Future<String> ensureFolder(String parentId, String name) =>
      _slow(() => _inner.ensureFolder(parentId, name));

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _slow(() => _inner.listChildren(namespaceId));

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) =>
      _slow(() => _inner.findAsset(namespaceId, name));

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    SyncTransferProgress? onProgress,
  }) => _slow(
    () => _inner.getAsset(assetId, destination, onProgress: onProgress),
  );

  @override
  Future<Object?> getJsonAsset(String assetId) =>
      _slow(() => _inner.getJsonAsset(assetId));

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    SyncTransferProgress? onProgress,
  }) => _inner.putAsset(namespaceId, name, file, onProgress: onProgress);

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _inner.putJsonAsset(namespaceId, name, json);

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      _inner.deleteAsset(id, isFolder: isFolder);
}

/// 读取永远不返回的位置（卡死的网络）；第一次读取进来时 [entered] 完成。
class _HangingStore implements SyncAssetStore {
  final Completer<void> entered = Completer<void>();

  Future<T> _hang<T>() {
    if (!entered.isCompleted) entered.complete();
    return Completer<T>().future;
  }

  @override
  Future<String> ensureNamespace(String name) => _hang();

  @override
  Future<String> ensureFolder(String parentId, String name) => _hang();

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) => _hang();

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) => _hang();

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    SyncTransferProgress? onProgress,
  }) => _hang();

  @override
  Future<Object?> getJsonAsset(String assetId) => _hang();

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    SyncTransferProgress? onProgress,
  }) => throw StateError('pull-only must not write');

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      throw StateError('pull-only must not write');

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      throw StateError('pull-only must not delete');
}

/// 驱动 [f] 做完：有读取在等假时钟就拨钟，否则让出一下给真实的本地 IO（不是等预算：假时钟不因此前进）。
Future<void> _drive(_FakeTime time, Future<void> f) async {
  bool done = false;
  unawaited(f.whenComplete(() => done = true));
  final Stopwatch guard = Stopwatch()..start();
  while (!done) {
    if (guard.elapsed > const Duration(seconds: 60)) {
      fail('did not finish (virtual time ${time.now})');
    }
    if (!time.step()) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }
  await f;
}

/// 只记下 [adopt] 收到的通道。
class _RecordingLinker implements SrsProfileLinker {
  final List<SyncAssetStore?> adoptedWithin = <SyncAssetStore?>[];

  /// 位置上判出冲突时的候选（[SrsSyncScheduler.adoptProfile] 采用之前按位置现状重判，候选里得有选的那个）。
  List<SrsRemoteProfile>? candidates;

  @override
  Future<SrsProfileLinkOutcome> link(
    SyncAssetStore backend,
    SrsDbStore store, {
    String? directoryKey,
  }) async => SrsProfileLinkOutcome(
    store,
    choose: candidates,
    localHasNotes: candidates != null,
  );

  @override
  Future<SrsProfileAdoptResult> adopt(
    SrsDbStore store,
    String uid, {
    SyncAssetStore? within,
    String? directoryKey,
  }) async {
    adoptedWithin.add(within);
    return SrsProfileAdopted(store);
  }

  @override
  Future<SrsDeferredProfileMerge?> deferredMerge(SrsDbStore store) async =>
      null;

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
    SrsPullBound migratePullBound = const SrsPullBound.progress(
      stall: kSrsPullBeforeMigrateStall,
      cap: kSrsPullBeforeMigrateCap,
    ),
    SrsPullTimerFactory pullTimer = Timer.new,
  }) => SrsSyncScheduler(
    readStore: () async => store,
    channels: channels ?? channelsOf,
    directoryKeyOf: (SyncAssetStore b) async => 'local:${root.path}',
    onDataChanged: () {},
    onNotice: (SrsSyncNotice _) {},
    firstSyncConfirmed: confirmed ?? () => true,
    runner: runner,
    profileLinker: linker,
    migratePullBound: migratePullBound,
    pullTimer: pullTimer,
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
      // 停滞判定与上限远大于测试超时：靠到点解开的互等在这里就是超时失败。
      migratePullBound: const SrsPullBound.progress(
        stall: Duration(hours: 1),
        cap: Duration(hours: 1),
      ),
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

  test('一直有进展、总时长远超旧的 2 分钟预算：等到收齐再迁移，只包本机独有的', () async {
    await seedA();
    final _FakeTime time = _FakeTime();
    // 每次后端调用 20 秒（假时钟）：位置上的一次读取是好几次后端调用（逐级找目录 / 找文件 / 下载），远小于停滞判定。
    final _SlowStore slow = _SlowStore(
      backend,
      time,
      const Duration(seconds: 20),
    );
    final SrsStorage stB = await _legacyStorage(<String>[...kShared, kOnlyB]);
    final SrsDbStore b = await _open(stB, 'B', deferMigration: true);
    final SrsSyncScheduler s = scheduler(
      store: b,
      channels: (Future<void> Function(SyncAssetStore) body) async {
        await body(slow);
        return (ran: 1, errors: const <Object>[]);
      },
      pullTimer: time.create,
    );
    await _drive(time, s.ensureMigrated(b));
    expect(
      time.now,
      greaterThan(const Duration(minutes: 2)),
      reason:
          'the pull took longer than the old fixed budget '
          '(${slow.reads} reads)',
    );
    expect(b.sync2Migrated, isTrue);
    expect(await _logOps(stB), (
      ops: 3,
      devices: 2,
    ), reason: "A's two ops pulled before migrating; only B's own log wrapped");
  });

  test('位置卡住（停滞）：最后一次进展之后整整 stall 才放弃，照常迁移；迟到的结果碰不到本机库', () async {
    final _FakeTime time = _FakeTime();
    final Completer<void> never = Completer<void>();
    final SrsStorage stB = await _legacyStorage(<String>[...kShared, kOnlyB]);
    final SrsDbStore b = await _open(stB, 'B', deferMigration: true);
    bool entered = false;
    final SrsSyncScheduler s = scheduler(
      store: b,
      channels: (Future<void> Function(SyncAssetStore) body) async {
        entered = true;
        await never.future;
        return (ran: 0, errors: const <Object>[]);
      },
      pullTimer: time.create,
    );
    bool done = false;
    final Future<void> migrating = s.ensureMigrated(b).whenComplete(() {
      done = true;
    });
    while (!entered) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    // 开跑那一刻算一次进展（内核 identity 之前就卡住：一次进展都没有）。
    time.jump(kSrsPullBeforeMigrateStall - const Duration(seconds: 1));
    await pumpEventQueue();
    expect(done, isFalse, reason: 'one second before the stall: still waiting');
    expect(b.sync2Migrated, isFalse);
    time.jump(kSrsPullBeforeMigrateStall);
    await migrating;
    expect(b.sync2Migrated, isTrue);
    expect(await _logOps(stB), (
      ops: 3,
      devices: 1,
    ), reason: 'nothing pulled: migrate everything');
  });

  test('位置上没有集合：不等任何计时器，立即迁移', () async {
    final _FakeTime time = _FakeTime();
    final SrsStorage stB = await _legacyStorage(<String>[...kShared, kOnlyB]);
    final SrsDbStore b = await _open(stB, 'B', deferMigration: true);
    final SrsSyncScheduler s = scheduler(store: b, pullTimer: time.create);
    await s.ensureMigrated(b);
    expect(time.now, Duration.zero, reason: 'no fake time had to pass');
    expect(b.sync2Migrated, isTrue);
    expect(await _logOps(stB), (ops: 3, devices: 1));
  });

  test('冲突弹窗选定候选：在候选所在那条通道的锁里并入，并入拿得到那条通道', () async {
    final SrsStorage st = await _legacyStorage(kShared);
    final SrsDbStore store = await _open(st, 'B');
    const String candidate = '01928c3e-0000-7000-8000-0000000000ea';
    final _RecordingLinker linker = _RecordingLinker()
      ..candidates = const <SrsRemoteProfile>[
        SrsRemoteProfile(uid: candidate, writers: <String>['v2:other']),
      ];
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
      candidate,
    );
    expect(linker.adoptedWithin, <SyncAssetStore?>[backend]);
  });

  // BUG-4387：`SrsDbStore.open` 在任何同步之前就写下内置身份记录，以前的判据（操作日志与投影全空）让新设备收段通道
  // 在生产里一次都不开。app 的顺序是「只拉不发 → 迁移 → 正式一轮」：第一次收段发生在只拉不发那一步。
  test('新装的设备确认后的第一轮：只拉不发那一步走收段通道，迁移与正式一轮照常，收敛', () async {
    Future<SrsSync2Report> roundOf(SrsDbStore s) => srsSync2Round(
      host: s,
      location: srsAssetLocation(backend, kProfile),
      locationId: 'local:${root.path}',
      nowMs: () => s.now().$1,
    );
    final SrsStorage stA = await openSrsTestStorage();
    final SrsDbStore a = await _open(stA, 'A');
    final List<String> notes = <String>[];
    for (int i = 0; i < 12; i++) {
      final String n = await a.createNote(
        noteTypeId: a.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kProfile, 'Expression'): '語$i',
        },
      );
      notes.add(n);
      await a.answer((await a.cardsOfNote(n)).first.id, 3);
    }
    expect((await roundOf(a)).error, isNull);

    final SrsStorage stB = await openSrsTestStorage();
    final SrsDbStore b = await _open(stB, 'B', deferMigration: true);
    expect(b.sync2Migrated, isFalse);
    // 收段的每一片开投之前：这个会话走不走通道（`ingest_begin` 的回报）。
    final List<bool> slices = <bool>[];
    b.debugOnIngestSlice = () => slices.add(b.debugChannelLive);
    // 正式一轮开跑时：迁移做了没有、A 的复习收到了没有、之前投过几片。
    final List<({bool migrated, int ops, int slices})> formal =
        <({bool migrated, int ops, int slices})>[];
    final SrsSyncScheduler s = scheduler(
      store: b,
      runner:
          (
            SyncAssetStore x,
            SrsDbStore store,
            String key, {
            SrsLocationKey? locationKey,
          }) async {
            formal.add((
              migrated: store.sync2Migrated,
              ops: (await _logOps(stB)).ops,
              slices: slices.length,
            ));
            return roundOf(store);
          },
    );
    await s.syncNow();

    expect(formal, isNotEmpty);
    expect(formal.first.migrated, isTrue);
    expect(
      formal.first.ops,
      12,
      reason: "A's reviews were pulled before the formal round",
    );
    expect(formal.first.slices, greaterThan(0));
    expect(
      slices.take(formal.first.slices),
      everyElement(isTrue),
      reason: 'the pull-first ingest of a new device takes the channel',
    );
    final QueryRow boot = await stB.db
        .customSelect('SELECT COUNT(*) AS c FROM sync2_boot')
        .getSingle();
    expect(boot.read<int>('c'), 0, reason: 'the channel is done');
    expect(await b.note(notes.first), isNotNull);

    expect((await roundOf(a)).error, isNull);
    expect((await roundOf(b)).error, isNull);
    expect(
      (await b.sync2Digest())['digest'],
      (await a.sync2Digest())['digest'],
    );
  });
  // 档案合并之前收目标 uid 的数据（BUG-4011）：真 [SrsDbProfileLinker] + 真并入，拉取经调度器的
  // [SrsSyncScheduler.pullBeforeMerge]（app 的接法，srs_app_runtime.dart）。目标 uid 的三条修改记录只在同步位置上
  // （设备 A 写的），本机 B 自己有同一批修改记录（另一个写入者）和一条笔记：并入前收齐了就沿用目标的写入者，没收到
  // 就改名成 `merged-…` 落第二份。
  group('档案合并之前的拉取按进度判', () {
    const int t0 = 1700000000000;
    SrsEditEvent edit(String uid, String writer, int seq) => SrsEditEvent(
      SrsFieldEdit(
        profileUid: uid,
        entityKind: SrsEntityKind.deck,
        entityId: SrsIds.builtinDefaultDeck(uid),
        fieldKey: 'x/$seq',
        dot: SrsDot(writer, seq),
        ctx: SrsCausalContext.empty(),
        value: 'v$seq',
        hlc: Hlc(t0 + seq, 0, writer),
        timeSource: SrsTimeSource.wall,
      ),
    );

    /// A 在目标 uid 下写三条修改记录并上传到 [root]；交回目标 uid。
    Future<String> seedTarget() async {
      final SrsStorage stA = await openSrsTestStorage();
      final SrsDbStore a = await _open(stA, 'A');
      await a.applyRemote(<SrsEvent>[
        for (int i = 1; i <= 3; i++) edit(kProfile, 'their#1', i),
      ]);
      final SrsSync2Report r = await srsSync2Round(
        host: a,
        location: srsAssetLocation(backend, kProfile),
        locationId: 'local:${root.path}',
        nowMs: () => a.now().$1,
      );
      expect(r.error, isNull);
      return kProfile;
    }

    /// 本机 B：主库一个 profile（自己的 uid）、一条笔记、同一批修改记录（写入者 `host-old#1`）；linker 的并入前
    /// 拉取接调度器（假时钟），每次拉取返回时的假时钟记在 [_DeviceB.pullEnded]。
    ///
    /// 放弃的时刻只能在拉取返回的那一刻读：放弃之后那次在途的读取照常回来、后面的读取继续花假时钟（结果被闸门
    /// 挡在本机库之外），并入做完时假时钟已经走到整个传输的终点。
    Future<_DeviceB> deviceB(
      _FakeTime time, {
      SrsPullBound? mergePullBound,
    }) async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final SrsStorage srs = await openSrsTestStorage();
      final int now = DateTime.now().millisecondsSinceEpoch;
      final int profileId = await db.insertProfile(
        ProfilesCompanion.insert(
          name: 'Default',
          createdAt: now,
          updatedAt: now,
        ),
      );
      Future<SrsDbStore> open() async => SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: await db.profileUidOf(profileId),
        deviceId: 'B',
        engine: const SrsTestEngine(),
      );
      SrsDbStore store = await open();
      final String oldUid = store.profileUid;
      await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(oldUid, 'Expression'): '雪',
        },
      );
      await store.applyRemote(<SrsEvent>[
        for (int i = 1; i <= 3; i++) edit(oldUid, 'host-old#1', i),
      ]);
      final SrsSyncScheduler s = SrsSyncScheduler(
        readStore: () async => store,
        channels: channelsOf,
        directoryKeyOf: (SyncAssetStore b) async => 'local:${root.path}',
        onDataChanged: () {},
        onNotice: (SrsSyncNotice _) {},
        firstSyncConfirmed: () => true,
        mergePullBound:
            mergePullBound ??
            const SrsPullBound.progress(
              stall: kSrsPullBeforeMergeStall,
              cap: kSrsPullBeforeMergeCap,
            ),
        pullTimer: time.create,
      );
      final List<Duration> pullEnded = <Duration>[];
      final SrsDbProfileLinker linker = SrsDbProfileLinker(
        db: db,
        activeProfileId: () async => profileId,
        reopenStore: () async => store = await open(),
        writeLock: SrsCurrentStoreWriteLock(() => store),
        onError: (String where, Object e, StackTrace _) => fail('$where: $e'),
        pullBeforeMerge: (SrsDbStore target, SyncAssetStore? within) async {
          await s.pullBeforeMerge(target, within);
          pullEnded.add(time.now);
        },
      );
      return _DeviceB(db, srs, profileId, oldUid, store, linker, pullEnded);
    }

    /// 并入之后目标 uid 下那批修改记录的写入者。
    Future<List<String>> writersOf(SrsStorage srs, String uid) async {
      final List<QueryRow> rows = await srs.db
          .customSelect(
            'SELECT srs_idt(writer_id) AS w FROM srs_field_edits '
            "WHERE profile_uid = ? AND field_key LIKE 'x/%' "
            'ORDER BY field_key, w',
            variables: <Variable<Object>>[Variable<String>(uid, srsIdType)],
          )
          .get();
      return <String>[for (final QueryRow r in rows) r.read<String>('w')];
    }

    int mergedIn(List<String> writers) => writers
        .where((String w) => w.startsWith(kSrsMergedWriterPrefix))
        .length;

    test('一直有进展、总时长远超旧的 2 分钟预算：等到收齐再并入，沿用目标的写入者', () async {
      final String target = await seedTarget();
      final _FakeTime time = _FakeTime();
      final _SlowStore slow = _SlowStore(
        backend,
        time,
        const Duration(seconds: 20),
      );
      final _DeviceB b = await deviceB(time);
      final Future<SrsProfileAdoptResult> adopting = b.linker.adopt(
        b.store,
        target,
        within: slow,
      );
      await _drive(time, adopting);
      expect(
        b.pullEnded.single,
        greaterThan(const Duration(minutes: 2)),
        reason:
            'the pull took longer than the old fixed budget '
            '(${slow.reads} reads)',
      );
      expect(await adopting, isA<SrsProfileAdopted>());
      expect(await b.db.profileUidOf(b.profileId), target);
      final List<String> writers = await writersOf(b.srs, target);
      expect(writers, <String>['their#1', 'their#1', 'their#1']);
    });

    test('对照：同样的传输，总上限只有 2 分钟（旧的固定预算）到点就并入，同一批修改记录改名成 merged-', () async {
      final String target = await seedTarget();
      final _FakeTime time = _FakeTime();
      final _SlowStore slow = _SlowStore(
        backend,
        time,
        const Duration(seconds: 20),
      );
      final _DeviceB b = await deviceB(
        time,
        mergePullBound: const SrsPullBound.progress(
          stall: Duration(minutes: 2),
          cap: Duration(minutes: 2),
        ),
      );
      await _drive(time, b.linker.adopt(b.store, target, within: slow));
      // 到点（2 分钟）就返回：不等在途的那次读取，更不等整个传输（上一条测试里它要 3 分多钟）。
      expect(
        b.pullEnded.single,
        allOf(
          greaterThanOrEqualTo(const Duration(minutes: 2)),
          lessThan(const Duration(minutes: 3)),
        ),
        reason: 'gave up at the cap',
      );
      expect(await b.db.profileUidOf(b.profileId), target);
      final List<String> writers = await writersOf(b.srs, target);
      expect(mergedIn(writers), 3, reason: '$writers');
    });

    test('一直有进展但到了总上限：放弃、照常并入', () async {
      final String target = await seedTarget();
      final _FakeTime time = _FakeTime();
      // 与第一条同样的传输（每次后端调用 20 秒，整轮 3 分 20 秒；位置上的一次读取是几次后端调用，相邻两次进展
      // 都在停滞判定的 2 分钟之内，停滞不会到点）。这个小集合凑不满默认的 30 分钟，所以总上限注入成 2 分半——
      // 比停滞判定长、比收齐短，到点时拉取还在进展中（默认取值由引擎侧的取值测试钉住）。
      const Duration cap = Duration(minutes: 2, seconds: 30);
      final _SlowStore slow = _SlowStore(
        backend,
        time,
        const Duration(seconds: 20),
      );
      final _DeviceB b = await deviceB(
        time,
        mergePullBound: const SrsPullBound.progress(
          stall: kSrsPullBeforeMergeStall,
          cap: cap,
        ),
      );
      await _drive(time, b.linker.adopt(b.store, target, within: slow));
      expect(
        b.pullEnded.single,
        // 停滞放弃会落在 2 分钟那一格，收齐要到 3 分 20 秒。
        allOf(
          greaterThanOrEqualTo(cap),
          lessThan(const Duration(minutes: 3, seconds: 20)),
        ),
        reason: 'gave up at the cap, not at a stall (${slow.reads} reads)',
      );
      // 放弃之后照常并入：换到了目标 uid，那批修改记录都在（到上限时已经收进来的沿用目标的写入者，没收到的
      // 改名，各占多少取决于截断落在哪一次读取上，这里不钉）。
      expect(await b.db.profileUidOf(b.profileId), target);
      expect(await writersOf(b.srs, target), hasLength(3));
    });

    test('位置卡住（停滞）：最后一次进展之后整整 stall 才放弃，照常并入', () async {
      final String target = await seedTarget();
      final _FakeTime time = _FakeTime();
      final _HangingStore hung = _HangingStore();
      final _DeviceB b = await deviceB(time);
      bool done = false;
      final Future<SrsProfileAdoptResult> adopting = b.linker
          .adopt(b.store, target, within: hung)
          .whenComplete(() => done = true);
      await hung.entered.future;
      await pumpEventQueue();
      // 卡住之前唯一的进展是开头那次内核调用（假时钟 0）。
      time.jump(kSrsPullBeforeMergeStall - const Duration(seconds: 1));
      await pumpEventQueue();
      expect(done, isFalse, reason: 'one second before the stall: waiting');
      expect(
        await b.db.profileUidOf(b.profileId),
        b.oldUid,
        reason: 'not merged yet',
      );
      time.jump(kSrsPullBeforeMergeStall);
      expect(await adopting, isA<SrsProfileAdopted>());
      expect(b.pullEnded.single, kSrsPullBeforeMergeStall);
      expect(await b.db.profileUidOf(b.profileId), target);
      final List<String> writers = await writersOf(b.srs, target);
      expect(mergedIn(writers), 3, reason: 'nothing pulled: $writers');
    });

    test('位置上没有目标的集合：不等任何计时器，立即并入', () async {
      const String target = '01928c3e-0000-7000-8000-0000000000ea';
      final _FakeTime time = _FakeTime();
      final _DeviceB b = await deviceB(time);
      final SrsProfileAdoptResult adopted = await b.linker.adopt(
        b.store,
        target,
        within: backend,
      );
      expect(adopted, isA<SrsProfileAdopted>());
      expect(
        b.pullEnded.single,
        Duration.zero,
        reason: 'no fake time had to pass',
      );
      expect(await b.db.profileUidOf(b.profileId), target);
    });
  });
}

/// 并入测试里的本机 B。
class _DeviceB {
  _DeviceB(
    this.db,
    this.srs,
    this.profileId,
    this.oldUid,
    this.store,
    this.linker,
    this.pullEnded,
  );

  final FushiDatabase db;
  final SrsStorage srs;
  final int profileId;
  final String oldUid;

  /// 并入之前（旧 uid）的 store。
  final SrsDbStore store;
  final SrsDbProfileLinker linker;

  /// 并入之前的每一次拉取返回时的假时钟。
  final List<Duration> pullEnded;
}
