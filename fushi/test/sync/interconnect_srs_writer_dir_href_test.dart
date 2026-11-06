import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';

import '../srs/srs_test_support.dart' show openSrsTestStorage;

/// BUG-3576：旧版复习同步的写入者目录名是 `<deviceId>#<化身号>`。host 的 PROPFIND href 曾用
/// `Uri.encodeFull`（不编码 `#`），客户端又 `Uri.decodeFull` 后把 href 原样当 URL 用，
/// `Uri.parse` 把 `#1/` 当成片段截掉——第一轮（建目录走 ensureFolder）正常，第二轮起列写入者
/// 目录 PROPFIND 404，「立即同步」失败（iOS / 桌面同样）。
///
/// 同步 v2 的设备目录名是 UUID 文本（`v2/devices/<DeviceId>/`，不含 `#`），旧的写入者目录语义已不存在；
/// `#` 的编解码回归仍由前两组（通用 WebDAV href）钉住。第三条改成 v2 的等价形态：每轮新建位置对象（生产里
/// 每轮同步都是空的文件夹缓存），第二轮起设备目录只能靠 PROPFIND 列出来。
void main() {
  group('decodedDavHref', () {
    test('解码后重新转义 URL 分隔符，其余字符保持可读', () {
      expect(WebDavOps.decodedDavHref('/d/a%3D%231/'), '/d/a=%231/');
      // 旧 host 直接吐裸 `#`：同样转义，客户端单边修复即可连旧 host。
      expect(WebDavOps.decodedDavHref('/d/a=#1/'), '/d/a=%231/');
      expect(WebDavOps.decodedDavHref('/d/%E6%9B%B8%20x/'), '/d/書 x/');
      expect(WebDavOps.decodedDavHref('/d/50%25%3Fq/'), '/d/50%25%3Fq/');
      expect(
        Uri.parse('http://h${WebDavOps.decodedDavHref('/d/a%3D%231/')}').path,
        '/d/a=%231/',
      );
    });
  });

  group('真 host + 真互联客户端', () {
    late FushiSyncServer server;
    late Directory dataDir;
    late FushiDatabase db;
    late String base;
    const String token = 'srs-href-token';

    setUp(() async {
      dataDir = Directory.systemTemp.createTempSync('fushi_srs_href_srv');
      server = FushiSyncServer(
        syncDataDir: dataDir.path,
        port: 0,
        token: token,
        allowLan: false,
      );
      server.hostId = 'srs-href-host';
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
    });

    tearDown(() async {
      await server.stop();
      await db.close();
      dataDir.deleteSync(recursive: true);
    });

    test('host 的 PROPFIND href 把 # 编码成 %23', () async {
      Directory(
        '${dataDir.path}/sync-data/fushi-data/w=#1',
      ).createSync(recursive: true);
      final HttpClient client = HttpClient();
      addTearDown(client.close);
      final HttpClientRequest req = await client.openUrl(
        'PROPFIND',
        Uri.parse('$base/fushi-data/'),
      );
      req.headers
        ..set(
          'Authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
        )
        ..set('Depth', '1');
      final HttpClientResponse res = await req.close();
      final String body = await res.transform(utf8.decoder).join();
      expect(res.statusCode, 207);
      expect(body, contains('w%3D%231/'));
      expect(body, isNot(contains('w=#1/')));
    });

    test('SRS 同步连跑两轮：第二轮能列到带 # 的写入者目录', () async {
      final SyncRepository repo = SyncRepository(db);
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: base, enabled: true),
      ]);
      await repo.setFushiClientToken(token);
      final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
        (String url, String tok) async => true,
      );
      expect(await backend.restoreAuth(repo), isTrue);
      await backend.authenticate(repo: repo);

      final SrsStorage srs = await openSrsTestStorage();
      final SrsDbStore store = await SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: 'href-profile',
        deviceId: 'probe_abc=',
      );
      for (int round = 1; round <= 3; round++) {
        // 每轮先有新操作：内容没变的一轮不写 head、也就不列设备目录取服务端时间（空 head 会唤醒连着同一 host
        // 的全部设备，见 srs_sync2_round.dart）。
        await store.createNote(
          noteTypeId: store.lapisNoteTypeId,
          fieldsById: <String, String>{
            srsLapisFieldId('href-profile', 'Expression'): '語$round',
          },
        );
        // 每轮新建位置对象 = 生产里每次同步的形态（文件夹缓存为空，只能靠 PROPFIND 找）。
        final SrsSync2Report r = await srsSync2Round(
          host: store,
          location: SrsAssetLocationStore(
            store: backend,
            profileUid: 'href-profile',
          ),
          locationId: 'interconnect:srs-href-host',
          nowMs: () => store.now().$1,
        );
        expect(r.error, isNull, reason: 'round $round');
        expect(r.errors, isEmpty, reason: 'round $round');
        // 写完 head 再列本机设备目录才拿得到服务端时间：PROPFIND 列不到设备目录时这里是 null。
        expect(r.serverTimeMs, isNotNull, reason: 'round $round');
      }
    });
  });
}
