// 复习同步调度：用现有同步后端跑 SrsSyncEngine、成功后 anchorTime、后端不支持服务器
// 时间只提示一次、系统时间不准只提示一次、进复习 tab 的 60 秒节流、没配置后端时什么都
// 不做；以及「常规同步每条通道成功后调后置步骤」这条接线。
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
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
    DateTime Function()? clock,
  }) => SrsSyncScheduler(
    readStore: () async => s ?? store,
    channels:
        channels ??
        (Future<void> Function(SyncAssetStore) body) async {
          await body(LocalDirectoryAssetStore(root));
          return 1;
        },
    onDataChanged: () => changed++,
    onNotice: notices.add,
    clock: clock,
  );

  test('支持服务器时间的后端：同步成功、发布、校时；不提示', () async {
    final SrsSyncReport? r = await scheduler().syncWithBackend(
      LocalDirectoryAssetStore(root),
    );
    expect(r, isNotNull);
    expect(r!.error, isNull);
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
    final SrsSyncReport? r1 = await s.syncWithBackend(backend);
    final SrsSyncReport? r2 = await s.syncWithBackend(backend);
    expect(r1!.error, kSrsSyncServerTimeUnavailable);
    expect(r2!.error, kSrsSyncServerTimeUnavailable);
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

  test('进复习 tab 的节流：60 秒内第二次跳过', () async {
    DateTime now = DateTime(2026, 10, 15, 10);
    int runs = 0;
    final SrsSyncScheduler s = scheduler(
      clock: () => now,
      channels: (Future<void> Function(SyncAssetStore) body) async {
        runs++;
        return 0;
      },
    );
    expect(await s.syncThrottled(), isTrue);
    now = now.add(const Duration(seconds: 30));
    expect(await s.syncThrottled(), isFalse);
    now = now.add(const Duration(seconds: 31));
    expect(await s.syncThrottled(), isTrue);
    expect(runs, 2);
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
      expect(await s.syncNow(), 1);
      expect(cloud.restoreCalls, 1);
      expect(offline.restoreCalls, 1);
      expect(store.trustedClock.isAnchored, isTrue);
    });

    test('没配置任何同步后端：什么都不做', () async {
      debugSyncChannelsOverride = (SyncRepository _) async => <SyncChannel>[];
      int called = 0;
      final int n = await runOnAuthenticatedSyncChannels(
        db: FushiDatabase.forTesting(
          DatabaseConnection(NativeDatabase.memory()),
        ),
        body: (SyncBackend _) async => called++,
      );
      expect(n, 0);
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
}
