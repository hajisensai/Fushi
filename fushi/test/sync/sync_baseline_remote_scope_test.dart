/// BUG-4391（步骤 8）：文件箱进度基线的远端作用域工具。
///
/// 此前 `progressBaselineDimensionOf` 对全部云后端返回 `'progress'`、互联返回
/// `'progress__fushiServer'`，不带远端身份：换云类型 / 账号 / 服务器之后，旧远端上
/// 达成的共同祖先被拿去判新远端，本地停在基线 → 判「只远端动了」→ 新远端的旧值
/// 静默导入本机。这里直接驱动作用域工具与真后端类型：存储维度按「类型 + 账号 +
/// 服务器」（云）/ 会话 host（互联）分槽，OAuth 邮箱临时取不到时不换槽。
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/dropbox_sync_backend.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_baseline_scope.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_channel_scope.dart';

FushiDatabase _memDb() {
  final FushiDatabase db = FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
  addTearDown(db.close);
  return db;
}

/// 能报身份的假后端（其余成员一概不该被调到）。
class _IdentifiedBackend implements SyncBackend, SyncRemoteIdentified {
  _IdentifiedBackend(this.identity);

  final String identity;

  @override
  Future<String> syncRemoteIdentity() async => identity;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 认不出类型、也不报身份的假后端（大多数既有测试的 fake 就是这种）。
class _PlainBackend implements SyncBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<String> _cloudDimension(
  FushiDatabase db,
  SyncBackendType type,
  String? email,
) async => baselineStorageDimension(
  'progress',
  (await cloudRemoteScopeOf(db, type, currentEmail: email)).tag,
);

Future<InterconnectSyncBackend> _interconnect(
  FushiDatabase db,
  List<FushiClientUrl> candidates,
) async {
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(candidates);
  await repo.setFushiClientToken('scope-token');
  final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
    (String url, String token) async => true,
  );
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

void main() {
  group('cloud identity', () {
    test('a missing OAuth email for one round keeps the same slot', () async {
      final FushiDatabase db = _memDb();
      final String d1 = await _cloudDimension(
        db,
        SyncBackendType.dropbox,
        ' A@x.com ',
      );
      expect(d1, startsWith('progress@'));
      expect(
        await db.getPref(syncRemoteAccountPrefKey(SyncBackendType.dropbox)),
        'a@x.com',
      );

      // fetchUserEmail 失败一次：currentEmail 为空，仍落同一个槽。
      final String d2 = await _cloudDimension(
        db,
        SyncBackendType.dropbox,
        null,
      );
      expect(d2, d1);
    });

    // 评审 correctness-2：记下的账号是这台设备的登录事实，不随备份 / 设置同步走。
    test('remembered account keys are device-local for every backend type', () {
      for (final SyncBackendType type in SyncBackendType.values) {
        expect(
          SyncRepository.deviceLocalPrefKeys,
          contains(syncRemoteAccountPrefKey(type)),
          reason: type.name,
        );
      }
    });

    test('no account now and never seen before → identity unavailable', () {
      final FushiDatabase db = _memDb();
      expect(
        cloudRemoteScopeOf(db, SyncBackendType.oneDrive, currentEmail: ''),
        throwsA(isA<SyncRemoteIdentityUnavailableError>()),
      );
    });

    test('switching account moves to another slot', () async {
      final FushiDatabase db = _memDb();
      final String a = await _cloudDimension(
        db,
        SyncBackendType.dropbox,
        'A@x.com',
      );
      final String b = await _cloudDimension(
        db,
        SyncBackendType.dropbox,
        'B@x.com',
      );
      expect(b, isNot(a));
    });

    test('same WebDAV account on another server is another slot', () async {
      final FushiDatabase db = _memDb();
      final SyncRepository repo = SyncRepository(db);
      await repo.setWebDavUrl('https://dav-one.example/remote.php/dav');
      final String one = await _cloudDimension(
        db,
        SyncBackendType.webDav,
        'user',
      );
      await repo.setWebDavUrl('https://dav-two.example/remote.php/dav');
      final String two = await _cloudDimension(
        db,
        SyncBackendType.webDav,
        'user',
      );
      expect(two, isNot(one));
    });

    test('real Dropbox backend with no email falls back to the remembered '
        'account (the backend type is recognised)', () async {
      final FushiDatabase db = _memDb();
      final String remembered = await _cloudDimension(
        db,
        SyncBackendType.dropbox,
        'A@x.com',
      );
      // 未登录的单例：currentEmail 为 null。
      expect(await DropboxSyncBackend.instance.currentEmail, isNull);
      final ({String storageDimension, InterconnectHostPin? hostPin}) got =
          await progressBaselineStorageFor(db, DropboxSyncBackend.instance);
      expect(got.storageDimension, remembered);
      expect(got.hostPin, isNull);
    });

    test('signing a cloud backend out forgets its remembered account '
        'and clears only its own folder cache', () async {
      // 登出后下一次登录可能是另一个账号：邮箱恰好取失败时不能再落进旧账号的槽。
      final FushiDatabase db = _memDb();
      final SyncRepository repo = SyncRepository(db);
      final SyncChannelScope dropbox = SyncChannelScope.forBackendType(
        SyncBackendType.dropbox,
      );
      final SyncChannelScope oneDrive = SyncChannelScope.forBackendType(
        SyncBackendType.oneDrive,
      );
      await _cloudDimension(db, SyncBackendType.dropbox, 'A@x.com');
      await _cloudDimension(db, SyncBackendType.oneDrive, 'B@x.com');
      await repo.setFolderCache(dropbox, <String, String>{'book': 'id-d'});
      await repo.setFolderCache(oneDrive, <String, String>{'book': 'id-o'});

      await signOutSyncBackend(db, DropboxSyncBackend.instance);

      expect(
        cloudRemoteScopeOf(db, SyncBackendType.dropbox, currentEmail: null),
        throwsA(isA<SyncRemoteIdentityUnavailableError>()),
      );
      expect(await repo.getFolderCache(dropbox), isEmpty);
      // 别的云类型记下的账号与目录缓存都不动。
      expect(
        await db.getPref(syncRemoteAccountPrefKey(SyncBackendType.oneDrive)),
        'b@x.com',
      );
      expect(await repo.getFolderCache(oneDrive), <String, String>{
        'book': 'id-o',
      });
    });

    test('signing out a backend with no cloud account slot is a plain '
        'sign-out', () {
      expect(
        cloudBackendTypeOfChannel(
          SyncChannelScope.forBackendType(SyncBackendType.fushiServer),
        ),
        isNull,
      );
      expect(cloudBackendTypeOfChannel(SyncChannelScope.unscoped), isNull);
      for (final SyncBackendType type in SyncBackendType.values) {
        if (type == SyncBackendType.fushiServer) continue;
        expect(
          cloudBackendTypeOfChannel(SyncChannelScope.forBackendType(type)),
          type,
        );
      }
    });

    test('clearSyncRemoteAccount forgets the remembered account', () async {
      final FushiDatabase db = _memDb();
      await _cloudDimension(db, SyncBackendType.dropbox, 'A@x.com');
      await clearSyncRemoteAccount(db, SyncBackendType.dropbox);
      expect(
        cloudRemoteScopeOf(db, SyncBackendType.dropbox, currentEmail: null),
        throwsA(isA<SyncRemoteIdentityUnavailableError>()),
      );
    });
  });

  group('cloud adoption of the legacy unsuffixed row', () {
    test('only the current cloud type was ever used → rows move', () async {
      final FushiDatabase db = _memDb();
      await _cloudDimension(db, SyncBackendType.dropbox, 'A@x.com');
      await db.setPref(
        SyncChannelScope.forBackendType(
          SyncBackendType.dropbox,
        ).key('sync_last_sync_ms'),
        '1',
      );
      await db.setSyncBaseline('book-1', 'progress', 111);
      await db.setSyncBaseline('book-2', 'progress', 222);

      final String dim = (await progressBaselineStorageFor(
        db,
        DropboxSyncBackend.instance,
      )).storageDimension;
      expect(await db.getSyncBaselinesForDimension(dim), <String, int>{
        'book-1': 111,
        'book-2': 222,
      });
      expect(await db.getSyncBaselinesForDimension('progress'), isEmpty);
    });

    test('another cloud type was used too → rows are dropped', () async {
      final FushiDatabase db = _memDb();
      await _cloudDimension(db, SyncBackendType.dropbox, 'A@x.com');
      await db.setPref(
        SyncChannelScope.forBackendType(
          SyncBackendType.googleDrive,
        ).key('sync_last_sync_ms'),
        '1',
      );
      await db.setSyncBaseline('book-1', 'progress', 111);

      final String dim = (await progressBaselineStorageFor(
        db,
        DropboxSyncBackend.instance,
      )).storageDimension;
      expect(await db.getSyncBaselinesForDimension(dim), isEmpty);
      expect(await db.getSyncBaselinesForDimension('progress'), isEmpty);
    });
  });

  group('interconnect file box', () {
    test('a single host with hostId → scoped dimension + host pin', () async {
      final FushiDatabase db = _memDb();
      final InterconnectSyncBackend backend = await _interconnect(
        db,
        <FushiClientUrl>[
          const FushiClientUrl(url: 'http://127.0.0.1:9', hostId: 'a'),
        ],
      );
      final ({String storageDimension, InterconnectHostPin? hostPin}) got =
          await progressBaselineStorageFor(db, backend);
      expect(
        got.storageDimension,
        remoteScopedKey(
          'progress__fushiServer',
          syncRemoteTag('fushiServer\na'),
        ),
      );
      expect(got.hostPin, isNotNull);
      expect(got.hostPin!.hostId, 'a');
    });

    test('legacy candidate without hostId → unsuffixed dimension', () async {
      final FushiDatabase db = _memDb();
      final InterconnectSyncBackend backend = await _interconnect(
        db,
        <FushiClientUrl>[const FushiClientUrl(url: 'http://127.0.0.1:9')],
      );
      final ({String storageDimension, InterconnectHostPin? hostPin}) got =
          await progressBaselineStorageFor(db, backend);
      expect(got.storageDimension, 'progress__fushiServer');
      expect(got.hostPin, isNotNull);
      expect(got.hostPin!.hostId, isNull);
    });
  });

  group('other backends', () {
    test('SyncRemoteIdentified fake → suffixed dimension', () async {
      final FushiDatabase db = _memDb();
      final String dim = (await progressBaselineStorageFor(
        db,
        _IdentifiedBackend('remote-A'),
      )).storageDimension;
      expect(dim, remoteScopedKey('progress', syncRemoteTag('remote-A')));
    });

    test('unrecognised fake → logical dimension, nothing adopted', () async {
      final FushiDatabase db = _memDb();
      final _PlainBackend backend = _PlainBackend();
      await db.setSyncBaseline('book-1', 'progress', 5);
      final String dim = (await progressBaselineStorageFor(
        db,
        backend,
      )).storageDimension;
      expect(dim, progressBaselineDimensionOf(backend));
      expect(await db.getSyncBaselinesForDimension('progress'), <String, int>{
        'book-1': 5,
      });
    });
  });
}
