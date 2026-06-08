import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// End-to-end interop for the Hibiki P2P path (the Windows-host server ↔
/// Android-client scenario): a REAL [HibikiSyncServer] and the REAL
/// [HibikiClientSyncBackend] do a full upload → download round-trip over a
/// loopback socket. Exercises the exact protocol both ends use; the only thing
/// it doesn't cover is the emulator's 10.0.2.2 network hop (checked separately).
void main() {
  test('P2P round-trip: client uploads then re-reads progress via the server',
      () async {
    final Directory tempDir =
        await Directory.systemTemp.createTemp('hibiki_p2p_');
    addTearDown(() => tempDir.delete(recursive: true));
    // The server serves <syncDataDir>/sync-data at '/'; it must exist so the
    // client's connection probe (PROPFIND on root) succeeds.
    await Directory('${tempDir.path}/sync-data').create(recursive: true);

    final String token = HibikiSyncServer.generateToken();
    final HibikiSyncServer server = HibikiSyncServer(
      syncDataDir: tempDir.path,
      port: 0, // ephemeral
      token: token,
      allowLan: false, // loopback is enough for the host round-trip
    );
    await server.start();
    addTearDown(server.stop);

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

    // ── Device A: connect + upload ──
    expect(await backend.restoreAuth(repo), isTrue,
        reason: 'configured client should report authenticated');
    final String root = await backend.findOrCreateRootFolder();
    final String folder = await backend.ensureBookFolder(
        bookTitle: 'TestBook', rootFolderId: root);
    await backend.updateProgressFile(
      folderId: folder,
      fileId: null,
      progress: TtuProgress(
        dataId: 0,
        exploredCharCount: 777,
        progress: 0.42,
        lastBookmarkModified: 1234,
      ),
    );

    // ── Device B: a fresh session re-resolves and reads it back ──
    backend.clearCache();
    expect(await backend.restoreAuth(repo), isTrue);
    final String root2 = await backend.findOrCreateRootFolder();
    final List<DriveFile> books = await backend.listBooks(root2);
    // sanitizeTtuFilename 不改大小写（只处理尾部空格/点、`*`、非法字符百分号编码），
    // 故文件夹名保持原标题大小写 'TestBook'。服务器对真实读写路径不再 canonicalize
    // 小写化（见 hibiki_sync_server 的 fsPath），跨平台一致。
    expect(books.map((DriveFile f) => f.name), contains('TestBook'),
        reason: 'the uploaded book folder should be visible to another device');
    final String folder2 = await backend.ensureBookFolder(
        bookTitle: 'TestBook', rootFolderId: root2);
    final DriveSyncFiles files = await backend.listSyncFiles(folder2);
    expect(files.progress, isNotNull,
        reason: 'the uploaded progress file should be listed');
    final TtuProgress got = await backend.getProgressFile(files.progress!.id);
    expect(got.exploredCharCount, 777);
    expect(got.progress, closeTo(0.42, 1e-6));
  });
}
