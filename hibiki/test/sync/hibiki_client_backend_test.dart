import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

Future<void> _seed(
  SyncRepository repo, {
  required List<HibikiClientUrl> urls,
  String token = 'tok',
}) async {
  await repo.setHibikiClientUrls(urls);
  await repo.setHibikiClientToken(token);
}

void main() {
  test('restoreAuth returns false when no urls are configured', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    final HibikiClientSyncBackend backend =
        HibikiClientSyncBackend.withProbe((String u, String t) async => true);

    expect(await backend.restoreAuth(repo), isFalse);
    expect(await backend.isAuthenticated, isFalse);
  });

  test('restoreAuth is authenticated when urls + token are configured',
      () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await _seed(repo,
        urls: const <HibikiClientUrl>[HibikiClientUrl(url: 'http://lan:8765')]);
    final HibikiClientSyncBackend backend =
        HibikiClientSyncBackend.withProbe((String u, String t) async => true);

    expect(await backend.restoreAuth(repo), isTrue);
    expect(await backend.isAuthenticated, isTrue);
  });

  test('ensureResolved selects the reachable url and clears cache on switch',
      () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await _seed(repo, urls: const <HibikiClientUrl>[
      HibikiClientUrl(url: 'http://lan:8765'),
      HibikiClientUrl(url: 'http://wan:8765'),
    ]);
    // LAN unreachable, WAN reachable.
    final HibikiClientSyncBackend backend = HibikiClientSyncBackend.withProbe(
        (String u, String t) async => u.contains('wan'));

    await backend.restoreAuth(repo);
    backend.restoreCache(rootFolderId: 'http://lan:8765/$kSyncRootFolderName/');
    await backend.ensureResolved();

    expect(backend.activeBaseUrl, WebDavOps.normalizeUrl('http://wan:8765'));
    expect(backend.cachedRootFolderId, isNull); // poisoned cache cleared
  });

  test('ensureResolved keeps cache when the first url is reachable', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await _seed(repo, urls: const <HibikiClientUrl>[
      HibikiClientUrl(url: 'http://lan:8765'),
      HibikiClientUrl(url: 'http://wan:8765'),
    ]);
    final HibikiClientSyncBackend backend =
        HibikiClientSyncBackend.withProbe((String u, String t) async => true);

    await backend.restoreAuth(repo);
    backend.restoreCache(rootFolderId: 'http://lan:8765/$kSyncRootFolderName/');
    await backend.ensureResolved();

    expect(backend.activeBaseUrl, WebDavOps.normalizeUrl('http://lan:8765'));
    expect(backend.cachedRootFolderId, 'http://lan:8765/$kSyncRootFolderName/');
  });

  test(
      'clearCache forces re-probe so failover works on a retry (HBK-AUDIT-157)',
      () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await _seed(repo, urls: const <HibikiClientUrl>[
      HibikiClientUrl(url: 'http://lan:8765'),
      HibikiClientUrl(url: 'http://wan:8765'),
    ]);
    bool lanUp = true;
    final HibikiClientSyncBackend backend = HibikiClientSyncBackend.withProbe(
      (String u, String t) async => u.contains('lan') ? lanUp : true,
    );

    await backend.restoreAuth(repo);
    await backend.ensureResolved();
    expect(backend.activeBaseUrl, WebDavOps.normalizeUrl('http://lan:8765'));

    // LAN drops mid-session; SyncManager clears the cache and retries. The
    // session must re-probe and fail over to WAN, not stay locked on LAN.
    lanUp = false;
    backend.clearCache();
    await backend.ensureResolved();
    expect(backend.activeBaseUrl, WebDavOps.normalizeUrl('http://wan:8765'));
  });
}
