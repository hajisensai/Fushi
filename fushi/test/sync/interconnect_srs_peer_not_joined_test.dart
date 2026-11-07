import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_history_page.dart'
    show srsTimelineSummaryTitle;
import 'package:fushi/src/srs/srs_directory_key.dart';
import 'package:fushi/src/srs/srs_import_entry.dart' show srsSyncNowToast;
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_utils.dart' show kSyncRootFolderName;
import 'package:fushi/src/utils/misc/toast_severity.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_host_directory.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/srs_change_feed.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:path/path.dart' as p;

import '../srs/srs_test_support.dart' show openSrsTestStorage;

const String kProfile = '01928c3e-0000-7000-8000-0000000000ee';
const String kHostId = 'srs-peer-not-joined-host';
const String kToken = 'srs-peer-not-joined-token';

/// BUG-4232：host 还没点过一次性的「复习同步已升级 → 开始同步」时，它不跑本机目录那一轮（既不发布自己的复习
/// 数据，也不并入客户端写进来的段），客户端一轮却「成功」、摘要说「所有改动都已同步」，什么都没收到也没有任何
/// 提示。
///
/// 真 host（FushiSyncServer + 本机目录调度器，首次确认闸门与生产同一个判据）+ 真互联客户端
/// （InterconnectSyncBackend + 客户端调度器，`peerJoined` 用生产的 [srsChannelPeerJoined]）。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late FushiSyncServer server;
  late Directory dataDir;
  late FushiDatabase clientAppDb;
  late String base;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('fushi_srs_not_joined_srv');
    server = FushiSyncServer(
      syncDataDir: dataDir.path,
      port: 0,
      token: kToken,
      allowLan: false,
    );
    server.hostId = kHostId;
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
    clientAppDb = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
  });

  tearDown(() async {
    await server.stop();
    await clientAppDb.close();
    try {
      dataDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  Future<SrsDbStore> device(String id) async {
    final SrsStorage srs = await openSrsTestStorage();
    return SrsDbStore.open(
      db: srs.db,
      core: srs.core,
      profileUid: kProfile,
      deviceId: id,
    );
  }

  Future<String> addNote(SrsDbStore s, String expression) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kProfile, 'Expression'): expression,
    },
  );

  Future<InterconnectSyncBackend> connectClient(SyncRepository repo) async {
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: base, enabled: true),
    ]);
    await repo.setFushiClientToken(kToken);
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
      (String url, String tok) async => true,
    );
    expect(await backend.restoreAuth(repo), isTrue);
    await backend.authenticate(repo: repo);
    return backend;
  }

  test('host 没确认首次 v2 同步：客户端不说「已同步」，确认后两边互通、提示消失', () async {
    bool hostConfirmed = false;
    // 生产装配：app_model.dart `srsSync2Joined: () => srsSync2MergeConfirmed`。
    server.srsSync2Joined = () => hostConfirmed;

    final SyncRepository repo = SyncRepository(clientAppDb);
    final InterconnectSyncBackend backend = await connectClient(repo);
    final SrsDbStore phone = await device('phone');
    final SrsDbStore host = await device('host');
    final String fromPhone = await addNote(phone, '雨');
    final String fromHost = await addNote(host, '雪');

    final SrsSyncScheduler hostSync = SrsSyncScheduler(
      readStore: () async => host,
      channels: (Future<void> Function(SyncAssetStore) body) async =>
          (ran: 0, errors: const <Object>[]),
      directoryKeyOf: (SyncAssetStore b) async => null,
      // 与 srs_app_runtime.dart `_localDirectories` 同一块目录、同一个身份。
      localDirectories: () async => <SrsLocalDirectory>[
        SrsLocalDirectory(
          directoryKey: srsInterconnectDirectoryKey(kHostId),
          store: LocalDirectoryAssetStore(
            Directory(p.join(server.syncDataDir, kSyncRootFolderName)),
          ),
        ),
      ],
      firstSyncConfirmed: () => hostConfirmed,
      onDataChanged: () {},
      onNotice: (_) {},
    );
    addTearDown(hostSync.dispose);
    final SrsSyncScheduler phoneSync = SrsSyncScheduler(
      readStore: () async => phone,
      channels: (Future<void> Function(SyncAssetStore) body) async {
        await body(backend);
        return (ran: 1, errors: const <Object>[]);
      },
      directoryKeyOf: (SyncAssetStore b) => srsDirectoryKeyOf(b, repo),
      peerJoined: srsChannelPeerJoined,
      onDataChanged: () {},
      onNotice: (_) {},
    );
    addTearDown(phoneSync.dispose);
    final String? phoneKey = await srsDirectoryKeyOf(backend, repo);
    expect(phoneKey, isNotNull);

    // ① host 还没确认：它的本机目录那一轮被闸门挡住。
    final SrsSyncNowResult hostBefore = await hostSync.syncLocalDirectories();
    expect(hostBefore.ran, 0);
    expect(hostBefore.errors.single.toString(), kSrsSyncAwaitingConfirm);
    expect(await backend.hostSrsSyncJoined(), isFalse);

    final SrsSyncNowResult before = await phoneSync.syncNow();
    expect(before.errors, isEmpty, reason: '本机这一轮确实发出去了，不是失败');
    expect(before.ran, 1);
    expect(before.peersNotJoined, 1, reason: '对端报告还没加入复习同步');
    expect(phoneSync.peersNotJoined.value, <String>{phoneKey!});
    expect(await phone.note(fromHost), isNull, reason: 'host 没发布，客户端收不到');
    // 立即同步的提示与同步与历史页的摘要都不说「已同步」。
    final ({String msg, ToastSeverity severity}) toast = srsSyncNowToast(
      before,
    );
    expect(toast.msg, t.srs_sync_peer_not_joined);
    expect(toast.msg, isNot(t.srs_sync_done));
    expect(toast.severity, ToastSeverity.warning);
    expect(
      srsTimelineSummaryTitle(
        syncing: null,
        unpublished: 0,
        peerNotJoined: phoneSync.peersNotJoined.value.isNotEmpty,
      ),
      t.srs_sync_peer_not_joined,
    );

    // ② host 点了「开始同步」：本机目录那一轮并入客户端的段并发布自己的数据。
    hostConfirmed = true;
    final SrsSyncNowResult hostAfter = await hostSync.syncLocalDirectories();
    expect(hostAfter.errors, isEmpty);
    expect(hostAfter.ran, 1);
    expect(await host.note(fromPhone), isNotNull, reason: 'host 并入了客户端的笔记');

    final SrsSyncNowResult after = await phoneSync.syncNow();
    expect(after.errors, isEmpty);
    expect(after.peersNotJoined, 0);
    expect(phoneSync.peersNotJoined.value, isEmpty, reason: '对端加入后提示消失');
    expect(await phone.note(fromHost), isNotNull, reason: '客户端收到 host 的笔记');
    expect(srsSyncNowToast(after).msg, t.srs_sync_done);
    expect(
      srsTimelineSummaryTitle(
        syncing: null,
        unpublished: 0,
        peerNotJoined: phoneSync.peersNotJoined.value.isNotEmpty,
      ),
      t.srs_timeline_all_published,
    );
  });

  test('没有首次确认这一步的 host（无头服务端 / 老 host）：端点 404，客户端按「不报告」处理', () async {
    // 未注入 srsSync2Joined。
    final InterconnectSyncBackend backend = await connectClient(
      SyncRepository(clientAppDb),
    );
    expect(await backend.hostSrsSyncJoined(), isNull);
    expect(await srsChannelPeerJoined(backend), isNull);

    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    final HttpClientRequest req = await client.getUrl(
      Uri.parse('$base$kSrsSyncStatusPath'),
    );
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 401, reason: '状态端点同样要鉴权，不对未配对的人公开');
  });

  test('纯存储后端（本机目录 / 云盘）那头没有对端：不问、不报告', () async {
    expect(
      await srsChannelPeerJoined(LocalDirectoryAssetStore(dataDir)),
      isNull,
    );
  });
}
