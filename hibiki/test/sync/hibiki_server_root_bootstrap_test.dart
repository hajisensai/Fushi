import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Regression guard for BUG-035: a freshly started [HibikiSyncServer] serves
/// `<syncDataDir>/sync-data` as its WebDAV root, and the client's reachability
/// probe (PROPFIND on '/') gates EVERY other op. If `start()` does not create
/// that directory, the probe gets a 404 and reports the (reachable, correctly
/// authenticating) host as "No reachable Hibiki server address" — and the only
/// op that would lazily create the dir (MKCOL) is itself gated behind the
/// probe, so it can never bootstrap. The server must materialise its root on
/// start.
///
/// NOTE: unlike [hibiki_p2p_roundtrip_test.dart], this test deliberately does
/// NOT pre-create the sync-data directory — that pre-creation is precisely what
/// masked this bug in the existing suite.
void main() {
  test(
      'a freshly started server (no pre-created sync-data) is reachable by the '
      'client probe', () async {
    final Directory tempDir =
        await Directory.systemTemp.createTemp('hibiki_root_bootstrap_');
    addTearDown(() => tempDir.delete(recursive: true));

    final Directory servedRoot = Directory('${tempDir.path}/sync-data');
    expect(servedRoot.existsSync(), isFalse,
        reason: 'precondition: the served WebDAV root must not exist yet');

    final String token = HibikiSyncServer.generateToken();
    final HibikiSyncServer server = HibikiSyncServer(
      syncDataDir: tempDir.path,
      port: 0, // ephemeral
      token: token,
      allowLan: false, // loopback is enough for the reachability probe
    );
    await server.start();
    addTearDown(server.stop);

    // Server invariant: the served root collection exists after start(), so a
    // PROPFIND on '/' returns 207 (an empty collection) instead of 404.
    expect(servedRoot.existsSync(), isTrue,
        reason: 'start() must create the served root so PROPFIND / is 207');

    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await repo.setHibikiClientUrls(<HibikiClientUrl>[
      HibikiClientUrl(url: 'http://127.0.0.1:${server.port}'),
    ]);
    await repo.setHibikiClientToken(token);

    final HibikiClientSyncBackend backend = HibikiClientSyncBackend.instance;
    backend.clearCache();
    addTearDown(backend.clearCache);

    expect(await backend.restoreAuth(repo), isTrue,
        reason: 'configured client should report authenticated');
    // The reachability probe runs here. Before the fix it throws
    // SyncBackendError('No reachable Hibiki server address') because the probe
    // PROPFIND returns 404 on the missing served root.
    await backend.ensureResolved();
    expect(backend.activeBaseUrl, 'http://127.0.0.1:${server.port}',
        reason: 'client must settle on the reachable server URL');
  });
}
