// BUG-3245：「已从本机移除的远端书」设置页核对书还在不在时，只读解析远端来源——不在
// 云盘上建同步根（以前走 findOrCreateRootFolder，光打开设置页就在远端建目录 / 跑旧根
// 改名迁移）。云盘根只用本会话已解析过的或上次同步落盘的那个。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/cloud_remote_book_client.dart';
import 'package:fushi/src/sync/hidden_remote_books.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/webdav_sync_backend.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
    WebDavSyncBackend.instance.clearCache();
    await repo.setBackendType(SyncBackendType.webDav);
    // 端口 9 不会有人应答：凡是真去碰远端（PROPFIND / MKCOL）都会抛连接错误。
    await repo.setWebDavUrl('http://127.0.0.1:9/dav');
    await repo.setWebDavUsername('u');
    await repo.setWebDavPassword('p');
  });
  tearDown(() async {
    WebDavSyncBackend.instance.clearCache();
    await db.close();
  });

  test('没有已知的同步根：返回 null，不去远端建根目录', () async {
    final RemoteBookClient? client = await resolveShelfRemoteBookClient(
      db,
      createRootFolder: false,
    );
    expect(client, isNull);
    expect(WebDavSyncBackend.instance.cachedRootFolderId, isNull);
  });

  test('上次同步落盘的同步根：直接用它，不碰远端', () async {
    const String root = 'http://127.0.0.1:9/dav/fushi-data/';
    await repo.setRootFolderId(
      SyncChannelScope.forBackendType(SyncBackendType.webDav),
      root,
    );
    final RemoteBookClient? client = await resolveShelfRemoteBookClient(
      db,
      createRootFolder: false,
    );
    expect(client, isA<CloudRemoteBookClient>());
    expect((client! as CloudRemoteBookClient).rootFolderId, root);
  });

  test('本会话已解析过的同步根优先', () async {
    WebDavSyncBackend.instance.restoreCache(
      rootFolderId: 'http://127.0.0.1:9/dav/fushi-data/',
    );
    final RemoteBookClient? client = await resolveShelfRemoteBookClient(
      db,
      createRootFolder: false,
    );
    expect(
      (client! as CloudRemoteBookClient).rootFolderId,
      'http://127.0.0.1:9/dav/fushi-data/',
    );
  });

  test('对照：书架照旧 findOrCreateRootFolder（会去远端）', () async {
    await expectLater(resolveShelfRemoteBookClient(db), throwsA(anything));
  });
}
