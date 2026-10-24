// 复习同步调度：用现有同步后端跑 SrsSyncEngine、成功后 anchorTime、后端不支持服务器
// 时间只提示一次、系统时间不准只提示一次、进复习 tab 的 60 秒节流、没配置后端时什么都
// 不做；以及「常规同步每条通道成功后调后置步骤」这条接线。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_asset_store_directory.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'srs_test_support.dart';

/// 列目录不带修改时间的后端（拿不到服务器时间）。
class _NoTimeStore implements SyncAssetStore {
  _NoTimeStore(this.inner);

  final SyncAssetStore inner;

  AssetEntry _strip(AssetEntry e) => AssetEntry(
    id: e.id,
    name: e.name,
    isFolder: e.isFolder,
    sizeBytes: e.sizeBytes,
  );

  @override
  Future<String> ensureNamespace(String name) => inner.ensureNamespace(name);
  @override
  Future<String> ensureFolder(String parentId, String name) =>
      inner.ensureFolder(parentId, name);
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      (await inner.listChildren(namespaceId)).map(_strip).toList();
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    final AssetEntry? e = await inner.findAsset(namespaceId, name);
    return e == null ? null : _strip(e);
  }

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    SyncTransferProgress? onProgress,
  }) => inner.putAsset(namespaceId, name, file, onProgress: onProgress);
  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    SyncTransferProgress? onProgress,
  }) => inner.getAsset(assetId, destination, onProgress: onProgress);
  @override
  Future<Object?> getJsonAsset(String assetId) => inner.getJsonAsset(assetId);
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      inner.putJsonAsset(namespaceId, name, json);
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      inner.deleteAsset(id, isFolder: isFolder);
}

/// 假同步通道后端：资产存取委托给本地目录，鉴权可配；其余成员被碰到就炸。
class _AssetBackend extends _NoTimeStore implements SyncBackend {
  _AssetBackend(super.inner, {this.authenticated = true});

  final bool authenticated;
  int restoreCalls = 0;

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      inner.listChildren(namespaceId);
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) =>
      inner.findAsset(namespaceId, name);

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    restoreCalls++;
    return authenticated;
  }

  @override
  Future<bool> get isAuthenticated async => authenticated;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

void main() {
  late Directory root;
  late FushiDatabase db;
  late SrsDbStore store;
  final List<SrsSyncNotice> notices = <SrsSyncNotice>[];
  int changed = 0;

  setUp(() async {
    notices.clear();
    changed = 0;
    root = Directory.systemTemp.createTempSync('fushi_srs_sched_');
    (db, store) = await openSrsTestStore();
    await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): '雪',
      },
    );
  });

  tearDown(() async {
    debugSyncChannelsOverride = null;
    await db.close();
    root.deleteSync(recursive: true);
  });

  SrsSyncScheduler scheduler({
    SrsDbStore? s,
    SrsChannelRunner? channels,
    Future<List<SrsLocalDirectory>> Function()? localDirectories,
    DateTime Function()? clock,
  }) => SrsSyncScheduler(
    readStore: () async => s ?? store,
    channels:
        channels ??
        (Future<void> Function(SyncAssetStore) body) async {
          await body(LocalDirectoryAssetStore(root));
          return (ran: 1, errors: const <Object>[]);
        },
    // 测试里的目录都是 LocalDirectoryAssetStore：按根目录区分物理目录。
    directoryKeyOf: (SyncAssetStore b) async => b is LocalDirectoryAssetStore
        ? 'local:${b.root.path}'
        : 'store:${identityHashCode(b)}',
    localDirectories: localDirectories,
    onDataChanged: () => changed++,
    onNotice: notices.add,
    clock: clock,
  );

  String ownBatchPath(Directory r, SrsDbStore s, int no) => <String>[
    r.path,
    kSrsSyncNamespace,
    s.profileUid,
    s.writerId,
    srsBatchName(no),
  ].join(Platform.pathSeparator);

  test('支持服务器时间的后端：同步成功、发布、校时；不提示', () async {
    final SrsSyncReport r = await scheduler().syncWithBackend(
      LocalDirectoryAssetStore(root),
    );
    expect(r, isNotNull);
    expect(r.error, isNull);
    expect(r.serverTimeMs, isNotNull);
    expect(r.published, greaterThan(0));
    expect(store.trustedClock.isAnchored, isTrue, reason: 'anchorTime 被调用');
    expect(changed, greaterThan(0));
    expect(notices, isEmpty);
    expect(
      Directory(
        '${root.path}${Platform.pathSeparator}$kSrsSyncNamespace',
      ).existsSync(),
      isTrue,
    );
  });

  test('后端拿不到服务器时间：提示「不支持」只一次，不校时', () async {
    final SrsSyncScheduler s = scheduler();
    final _NoTimeStore backend = _NoTimeStore(LocalDirectoryAssetStore(root));
    final SrsSyncReport r1 = await s.syncWithBackend(backend);
    final SrsSyncReport r2 = await s.syncWithBackend(backend);
    expect(r1.error, kSrsSyncServerTimeUnavailable);
    expect(r2.error, kSrsSyncServerTimeUnavailable);
    expect(notices, <SrsSyncNotice>[SrsSyncNotice.backendUnsupported]);
    expect(store.trustedClock.isAnchored, isFalse);
  });

  test('系统时间与服务器时间差超过 10 分钟：提示一次', () async {
    final SrsTestClock clock = SrsTestClock(
      DateTime.now().millisecondsSinceEpoch -
          const Duration(days: 3).inMilliseconds,
    );
    final (FushiDatabase db2, SrsDbStore skewed) = await openSrsTestStore(
      deviceId: 'skew',
      clock: clock,
    );
    addTearDown(db2.close);
    final SrsSyncScheduler s = scheduler(s: skewed);
    await s.syncWithBackend(LocalDirectoryAssetStore(root));
    await s.syncWithBackend(LocalDirectoryAssetStore(root));
    expect(notices, <SrsSyncNotice>[SrsSyncNotice.clockSkew]);
  });

  test('一轮同步跑很久：系统时间准就不提示，可信时间不落后整轮耗时', () async {
    // 服务器时间是一轮开头的探针取到的；整轮跑完才校时。校时若用跑完时的单调时钟，
    // 30 分钟的一轮会被算成「墙钟超前 30 分钟」→ 误报「系统时间不准」。
    final SrsTestClock clock = SrsTestClock(
      DateTime.now().millisecondsSinceEpoch,
    );
    final (FushiDatabase db2, SrsDbStore slow) = await openSrsTestStore(
      deviceId: 'slow',
      clock: clock,
    );
    addTearDown(db2.close);
    const Duration roundTook = Duration(minutes: 30);
    final SrsSyncScheduler s = SrsSyncScheduler(
      readStore: () async => slow,
      channels: (Future<void> Function(SyncAssetStore) body) async {
        await body(LocalDirectoryAssetStore(root));
        return (ran: 1, errors: const <Object>[]);
      },
      directoryKeyOf: (SyncAssetStore b) async => 'local:${root.path}',
      onDataChanged: () => changed++,
      onNotice: notices.add,
      runner: (SyncAssetStore backend, SrsDbStore st, String key) async {
        final SrsSyncReport r = await srsDefaultSyncRunner(backend, st, key);
        clock.advance(roundTook);
        return r;
      },
    );
    final SrsSyncReport r = await s.syncWithBackend(
      LocalDirectoryAssetStore(root),
    );
    expect(r.error, isNull);
    expect(slow.trustedClock.isAnchored, isTrue);
    expect(notices, isEmpty);
    expect(
      slow.trustedClock.wallSkewMs!.abs(),
      lessThan(const Duration(minutes: 1).inMilliseconds),
    );
  });

  test('进复习 tab 的节流：60 秒内第二次跳过', () async {
    DateTime now = DateTime(2026, 10, 15, 10);
    int runs = 0;
    final SrsSyncScheduler s = scheduler(
      clock: () => now,
      channels: (Future<void> Function(SyncAssetStore) body) async {
        runs++;
        return (ran: 0, errors: const <Object>[]);
      },
    );
    expect(await s.syncThrottled(), isTrue);
    now = now.add(const Duration(seconds: 30));
    expect(await s.syncThrottled(), isFalse);
    now = now.add(const Duration(seconds: 31));
    expect(await s.syncThrottled(), isTrue);
    expect(runs, 2);
  });

  group('多个同步目录（云盘 + 互联同时开着）', () {
    test('同一批次传到每个目录；再同步不换化身（批次不再只到先跑的那个）', () async {
      final Directory cloudRoot = Directory.systemTemp.createTempSync(
        'fushi_srs_cloud_',
      );
      addTearDown(() => cloudRoot.deleteSync(recursive: true));
      final SrsSyncScheduler s = scheduler(
        channels: (Future<void> Function(SyncAssetStore) body) async {
          await body(LocalDirectoryAssetStore(cloudRoot));
          await body(LocalDirectoryAssetStore(root));
          return (ran: 2, errors: const <Object>[]);
        },
      );
      expect((await s.syncNow()).ran, 2);
      final String writer = store.writerId;
      expect(File(ownBatchPath(cloudRoot, store, 1)).existsSync(), isTrue);
      // 第二个目录这时还没同步过、不拖住本机留存：第 1 批由快照补齐（覆盖同一段前缀）。
      expect(
        File(ownBatchPath(root, store, 1)).existsSync() ||
            File(
              ownBatchPath(
                root,
                store,
                1,
              ).replaceFirst(srsBatchName(1), srsSnapshotName(1)),
            ).existsSync(),
        isTrue,
      );
      // 修复前：第二个目录里没有本写入者的批次 → 每轮把它当「被退役清理过」换一次化身。
      await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kSrsTestProfile, 'Expression'): '雨',
        },
      );
      expect((await s.syncNow()).ran, 2);
      expect(store.writerId, writer);
      expect(File(ownBatchPath(cloudRoot, store, 2)).existsSync(), isTrue);
      expect(File(ownBatchPath(root, store, 2)).existsSync(), isTrue);
    });

    test('本机开着互联服务：host 自己的同步目录也参与（没有任何通道也算同步过）', () async {
      final SrsSyncScheduler s = scheduler(
        channels: (Future<void> Function(SyncAssetStore) body) async =>
            (ran: 0, errors: const <Object>[]),
        localDirectories: () async => <SrsLocalDirectory>[
          SrsLocalDirectory(
            directoryKey: 'interconnect:host',
            store: LocalDirectoryAssetStore(root),
          ),
        ],
      );
      expect((await s.syncNow()).ran, 1);
      expect(File(ownBatchPath(root, store, 1)).existsSync(), isTrue);
      expect(store.trustedClock.isAnchored, isTrue);
    });

    test('立即同步：通道抛错与报告带错都记成失败，不算同步成功', () async {
      final StateError unreachable = StateError('host unreachable');
      final SrsSyncScheduler s = SrsSyncScheduler(
        readStore: () async => store,
        channels: (Future<void> Function(SyncAssetStore) body) async {
          // 第一条通道：引擎跑完但目录身份拿不到（报告带错，没抛）。
          await body(LocalDirectoryAssetStore(root));
          // 第二条通道：抛错，由通道 runner 记账。
          return (ran: 1, errors: <Object>[unreachable]);
        },
        directoryKeyOf: (SyncAssetStore b) async => null,
        onDataChanged: () {},
        onNotice: (SrsSyncNotice _) {},
      );
      final SrsSyncNowResult r = await s.syncNow();
      expect(r.ran, 0);
      expect(r.unconfigured, isFalse);
      expect(r.errors, hasLength(2));
      expect(
        (r.errors.first as SrsSyncReportError).message,
        kSrsSyncDirectoryIdentityUnavailable,
      );
      expect(r.errors.last, same(unreachable));
    });

    test('立即同步：本机 SRS 副本打不开时如实报未同步，不算成功、也不说成没配置', () async {
      final SrsSyncScheduler s = SrsSyncScheduler(
        readStore: () async => null,
        channels: (Future<void> Function(SyncAssetStore) body) async {
          await body(LocalDirectoryAssetStore(root));
          return (ran: 1, errors: const <Object>[]);
        },
        directoryKeyOf: (SyncAssetStore b) async => 'k',
        localDirectories: () async => <SrsLocalDirectory>[
          SrsLocalDirectory(
            directoryKey: 'interconnect:host',
            store: LocalDirectoryAssetStore(root),
          ),
        ],
        onDataChanged: () {},
        onNotice: (SrsSyncNotice _) {},
      );
      final SrsSyncNowResult r = await s.syncNow();
      expect(r.ran, 0);
      expect(r.unconfigured, isFalse);
      expect(
        r.errors.map((Object e) => (e as SrsSyncReportError).message),
        <String>[kSrsSyncStoreUnavailable, kSrsSyncStoreUnavailable],
      );
    });

    test('立即同步：没有通道也没有本机目录 = 没配置', () async {
      final SrsSyncNowResult r = await scheduler(
        channels: (Future<void> Function(SyncAssetStore) body) async =>
            (ran: 0, errors: const <Object>[]),
      ).syncNow();
      expect(r.unconfigured, isTrue);
    });

    test('目录身份拿不到（云盘账户还没认出来）：这一轮不跑，不当成新目录', () async {
      int runs = 0;
      final SrsSyncScheduler s = SrsSyncScheduler(
        readStore: () async => store,
        channels: (Future<void> Function(SyncAssetStore) body) async =>
            (ran: 0, errors: const <Object>[]),
        directoryKeyOf: (SyncAssetStore b) async => null,
        onDataChanged: () {},
        onNotice: (SrsSyncNotice _) {},
        runner: (SyncAssetStore b, SrsDbStore st, String key) async {
          runs++;
          return SrsSyncReport();
        },
      );
      final SrsSyncReport r = await s.syncWithBackend(
        LocalDirectoryAssetStore(root),
      );
      expect(r.error, kSrsSyncDirectoryIdentityUnavailable);
      expect(runs, 0);
      expect((await store.loadSyncState()).directories, isEmpty);
    });

    // 去抖是墙钟定时器：用真实 delay 驱动时，机器一忙 5 ms 的间隔就会拉长到超过去抖窗口，
    // 「去抖期间不跑」随负载随机失败。改用 fakeAsync 精确推进时间；runner 等依赖全是
    // 内存里的 Future，flushMicrotasks 即可跑完一轮。
    test('host 收到客户端写入：去抖后只跑一次本机目录，不跑通道', () {
      fakeAsync((FakeAsync async) {
        final List<String> keys = <String>[];
        int channelRuns = 0;
        final SrsSyncScheduler s = SrsSyncScheduler(
          readStore: () async => store,
          channels: (Future<void> Function(SyncAssetStore) body) async {
            channelRuns++;
            return (ran: 0, errors: const <Object>[]);
          },
          directoryKeyOf: (SyncAssetStore b) async => 'cloud',
          localDirectories: () async => <SrsLocalDirectory>[
            SrsLocalDirectory(
              directoryKey: 'interconnect:host',
              store: LocalDirectoryAssetStore(root),
            ),
          ],
          onDataChanged: () {},
          onNotice: (SrsSyncNotice _) {},
          hostWriteDebounce: const Duration(milliseconds: 30),
          runner: (SyncAssetStore b, SrsDbStore st, String key) async {
            keys.add(key);
            return SrsSyncReport();
          },
        );
        addTearDown(s.dispose);
        for (int i = 0; i < 5; i++) {
          s.notifyLocalDirectoryWritten();
          async.elapse(const Duration(milliseconds: 5));
        }
        expect(keys, isEmpty, reason: '去抖期间不跑');
        // 最后一次写入后已过 5 ms；再推 24 ms 正好差 1 ms 满 30 ms 去抖窗口。
        async.elapse(const Duration(milliseconds: 24));
        expect(keys, isEmpty, reason: '最后一次写入后还没满去抖窗口');
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(keys, <String>['interconnect:host']);
        expect(channelRuns, 0);
        // 销毁后再来的写入不再触发。
        s.dispose();
        s.notifyLocalDirectoryWritten();
        async.elapse(const Duration(milliseconds: 80));
        async.flushMicrotasks();
        expect(keys, hasLength(1));
      });
    });

    test('坏文件只记一次日志，不影响结果', () async {
      final SrsSyncScheduler s = SrsSyncScheduler(
        readStore: () async => store,
        channels: (Future<void> Function(SyncAssetStore) body) async =>
            (ran: 0, errors: const <Object>[]),
        directoryKeyOf: (SyncAssetStore b) async => 'k',
        onDataChanged: () {},
        onNotice: (SrsSyncNotice _) {},
        runner: (SyncAssetStore b, SrsDbStore st, String key) async =>
            SrsSyncReport()..skippedFiles.add('w#1/batch-0000000002: bad'),
      );
      final SrsSyncReport r = await s.syncWithBackend(
        LocalDirectoryAssetStore(root),
      );
      expect(r.error, isNull);
      expect(r.skippedFiles, hasLength(1));
    });

    test('同时触发的几轮依次跑，不交错改同一份本机同步状态', () async {
      int running = 0;
      int maxRunning = 0;
      final SrsSyncScheduler s = SrsSyncScheduler(
        readStore: () async => store,
        channels: (Future<void> Function(SyncAssetStore) body) async =>
            (ran: 0, errors: const <Object>[]),
        directoryKeyOf: (SyncAssetStore b) async => 'k',
        onDataChanged: () {},
        onNotice: (SrsSyncNotice _) {},
        runner: (SyncAssetStore b, SrsDbStore st, String key) async {
          running++;
          if (running > maxRunning) maxRunning = running;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          running--;
          return SrsSyncReport();
        },
      );
      await Future.wait(<Future<SrsSyncReport?>>[
        for (int i = 0; i < 4; i++)
          s.syncWithBackend(LocalDirectoryAssetStore(root)),
      ]);
      expect(maxRunning, 1);
    });
  });

  group('runOnAuthenticatedSyncChannels', () {
    test('只对已认证通道跑；SRS 数据经通道后端落盘', () async {
      final _AssetBackend cloud = _AssetBackend(LocalDirectoryAssetStore(root));
      final _AssetBackend offline = _AssetBackend(
        LocalDirectoryAssetStore(root),
        authenticated: false,
      );
      debugSyncChannelsOverride = (SyncRepository _) async => <SyncChannel>[
        SyncChannel(cloud, type: SyncBackendType.webDav, isInterconnect: false),
        SyncChannel(
          offline,
          type: SyncBackendType.fushiServer,
          isInterconnect: true,
        ),
      ];
      final SrsSyncScheduler s = scheduler(
        channels: (Future<void> Function(SyncAssetStore) body) =>
            runOnAuthenticatedSyncChannels(
              db: db,
              body: (SyncBackend b) => body(b),
            ),
      );
      expect((await s.syncNow()).ran, 1);
      expect(cloud.restoreCalls, 1);
      expect(offline.restoreCalls, 1);
      expect(store.trustedClock.isAnchored, isTrue);
    });

    test('已认证通道这轮抛错：不算跑过，异常带回给调用方（不能说成没配置）', () async {
      final _AssetBackend interconnect = _AssetBackend(
        LocalDirectoryAssetStore(root),
      );
      debugSyncChannelsOverride = (SyncRepository _) async => <SyncChannel>[
        SyncChannel(
          interconnect,
          type: SyncBackendType.fushiServer,
          isInterconnect: true,
        ),
      ];
      final StateError unreachable = StateError('host unreachable');
      final ({int ran, List<Object> errors}) n =
          await runOnAuthenticatedSyncChannels(
            db: db,
            body: (SyncBackend _) async => throw unreachable,
          );
      expect(n.ran, 0);
      expect(n.errors, <Object>[unreachable]);
    });

    test('没配置任何同步后端：什么都不做', () async {
      debugSyncChannelsOverride = (SyncRepository _) async => <SyncChannel>[];
      int called = 0;
      final ({int ran, List<Object> errors}) n =
          await runOnAuthenticatedSyncChannels(
            db: FushiDatabase.forTesting(
              DatabaseConnection(NativeDatabase.memory()),
            ),
            body: (SyncBackend _) async => called++,
          );
      expect(n.ran, 0);
      expect(n.errors, isEmpty);
      expect(called, 0);
    });
  });

  test('接线守卫：常规同步每条通道 orchestrator.run() 之后调通道后置步骤', () {
    final String src = File(
      'lib/src/sync/sync_auto_trigger.dart',
    ).readAsStringSync();
    final int fn = src.indexOf('Future<SyncRunReport?> _runSyncChannelInner(');
    expect(fn, greaterThanOrEqualTo(0));
    final int end = src.indexOf('\n}\n', fn);
    final String body = src.substring(fn, end);
    final int run = body.indexOf('await orchestrator.run()');
    final int hook = body.indexOf('syncChannelPostRunHook');
    expect(run, greaterThanOrEqualTo(0));
    expect(hook, greaterThan(run), reason: 'SRS 同步必须在常规同步成功之后跑');
    // 模块关着时没有任何钩子：默认为 null。
    expect(syncChannelPostRunHook, isNull);
  });

  // 反馈 OMWOurRQKb：关库（退出 / 备份恢复 / 数据根迁移）时 SRS 同步还在跑，半截同步打在
  // 已关闭的连接上（`SrsDbStore._loadLocal`「connection was closed」）。关库前先让 canRun
  // 变 false 再 quiesce：新一轮不开，在跑的一轮等它收尾。
  group('关库协作', () {
    test('canRun 为 false：不开新一轮、不碰 runner，报 store 不可用', () async {
      int runs = 0;
      final SrsSyncScheduler s = SrsSyncScheduler(
        readStore: () async => store,
        channels: (Future<void> Function(SyncAssetStore) body) async =>
            (ran: 0, errors: const <Object>[]),
        directoryKeyOf: (SyncAssetStore b) async => 'k',
        onDataChanged: () {},
        onNotice: notices.add,
        runner: (SyncAssetStore b, SrsDbStore st, String key) async {
          runs++;
          return SrsSyncReport();
        },
        canRun: () => false,
      );
      final SrsSyncReport r = await s.syncWithBackend(
        LocalDirectoryAssetStore(root),
      );
      expect(r.error, kSrsSyncStoreUnavailable);
      expect(runs, 0);
    });

    test('quiesce 等在跑的一轮结束；之后排进来的轮次在库关着时直接收手', () async {
      bool open = true;
      int runs = 0;
      final Completer<void> release = Completer<void>();
      final Completer<void> started = Completer<void>();
      final SrsSyncScheduler s = SrsSyncScheduler(
        readStore: () async => store,
        channels: (Future<void> Function(SyncAssetStore) body) async =>
            (ran: 0, errors: const <Object>[]),
        directoryKeyOf: (SyncAssetStore b) async => 'k',
        onDataChanged: () {},
        onNotice: notices.add,
        runner: (SyncAssetStore b, SrsDbStore st, String key) async {
          runs++;
          started.complete();
          await release.future;
          return SrsSyncReport();
        },
        canRun: () => open,
      );
      final Future<SrsSyncReport> inFlight = s.syncWithBackend(
        LocalDirectoryAssetStore(root),
      );
      await started.future;
      // 关库开始：先标成不可用，再等。
      open = false;
      final Future<SrsSyncReport> queued = s.syncWithBackend(
        LocalDirectoryAssetStore(root),
      );
      bool quiesced = false;
      final Future<void> q = s.quiesce().then((_) => quiesced = true);
      await Future<void>.delayed(Duration.zero);
      expect(quiesced, isFalse, reason: '在跑的一轮没结束前 quiesce 不能返回');
      release.complete();
      await q;
      expect((await inFlight).error, isNull);
      expect((await queued).error, kSrsSyncStoreUnavailable);
      expect(runs, 1, reason: '排队的一轮在库关着时不该跑');
    });
  });
}
