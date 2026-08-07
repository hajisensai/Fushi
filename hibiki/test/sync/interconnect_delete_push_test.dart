/// 「从所有设备删除」在互联通道上的 **client→host 推送**端到端测试。
///
/// 覆盖 [SyncOrchestrator]._pushDeletionTombstonesLive + 新增的视频删除四层
/// （[VideoDeletionHost] / `DELETE /api/library/videos/<id>` /
/// [InterconnectSyncBackend.deleteRemoteVideo]）。
///
/// 此前互联通道是 GET-only：client 勾了「从所有设备删除」只在本地写一条墓碑，没有任何
/// 人发布，对端 host 完全不受影响。这些用例钉住修复后的行为，以及三条不能被后续改动
/// 破坏的不变量：
/// 1. host 用户**自己导入的原始视频文件不删**（只回收 app 自己拥有的字节）；
/// 2. 互联推送**不碰墓碑行的 `remotePublishedAt`**（那是云通道的账，污染它会让只连云的
///    第三台设备永远收不到这次删除）；
/// 3. host 删除后写自己的墓碑，链路能继续传播到第三台设备。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/app_model_library_host_service.dart';
import 'package:fushi/src/sync/hibiki_library_host_service.dart';
import 'package:fushi/src/sync/hibiki_sync_server.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 旧版本 host：实现主接口但**不**实现 [VideoDeletionHost]，用来钉能力探测降级。
/// DELETE 路由在调 deleteVideo 之前就 `is!` 判掉并返 404，故这里一个方法都不用真写。
class _LegacyHostWithoutVideoDelete implements FushiLibraryHostService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed here');
}

Future<InterconnectSyncBackend> _buildClientBackend({
  required String base,
  required String token,
}) async {
  final FushiDatabase db = _memDb();
  addTearDown(db.close);
  final SyncRepository repo = SyncRepository(db);
  await repo.setHibikiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setHibikiClientToken(token);
  final InterconnectSyncBackend backend =
      InterconnectSyncBackend.withProbe((String u, String t) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

SyncOrchestrator _orchestrator({
  required FushiDatabase db,
  required SyncBackend backend,
  required Directory tmp,
}) =>
    SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: tmp,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncAudioBookFiles: false,
      syncVideoFiles: false,
      syncDictionary: false,
      syncLocalAudio: false,
    );

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late Directory hostUploads;
  late String base;
  const String token = 'delete-push-token';

  /// host 用户自己导入的原片（**不在** uploadedVideoRoot 下）。
  late File hostOwnVideo;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('delete_push_');
    hostDb = _memDb();
    hostUploads = Directory(p.join(work.path, 'host_uploads'))
      ..createSync(recursive: true);
    hostOwnVideo = File(p.join(work.path, 'my_own_movie.mp4'))
      ..writeAsBytesSync(<int>[9, 9, 9, 9]);
    final AppModelLibraryHostService libSvc = AppModelLibraryHostService(
      db: hostDb,
      dictionaryResourceRoot: Directory(work.path),
      packages: SyncAssetPackageService(db: hostDb),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
      uploadedVideoRoot: hostUploads,
    );
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: libSvc,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.stop();
    await hostDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  test('client 删视频（syncEverywhere）推送到 host：库里没了，原始视频文件保留', () async {
    // host 库里有这个视频，videoPath 指向 host 用户自己的原片。
    await hostDb.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/mine',
      title: 'Mine',
      videoPath: hostOwnVideo.path,
    ));

    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    // 用户在 client 上选「从所有设备删除」→ 各删除路径写下这条墓碑。
    final int deletedAt = DateTime.now().millisecondsSinceEpoch - 1000;
    await localDb.writeSyncDeletionTombstone(
      SyncTombstoneKind.video.dbValue,
      'video/mine',
      deletedAt,
    );

    final InterconnectSyncBackend backend =
        await _buildClientBackend(base: base, token: token);
    final SyncRunReport report = SyncRunReport();
    await _orchestrator(db: localDb, backend: backend, tmp: work)
        .syncDeletionTombstonesLiveForTest(report, backend);

    // host 库里这条真的没了。
    expect(await hostDb.allVideoBooks(), isEmpty);
    // 不变量 ①：host 用户自己的原片一个字节都没动。删的是库条目，不是用户的媒体文件。
    expect(hostOwnVideo.existsSync(), isTrue,
        reason: '远端删除绝不能删掉 host 用户自己导入的原始视频文件');
    expect(hostOwnVideo.readAsBytesSync(), <int>[9, 9, 9, 9]);
    // 不变量 ③：host 写了自己的墓碑，第三台设备下轮同步照常收到确认提示。
    final List<SyncDeletionTombstoneRow> hostTombs =
        await hostDb.getSyncDeletionTombstones();
    expect(
      hostTombs
          .where((SyncDeletionTombstoneRow r) =>
              r.mediaType == SyncTombstoneKind.video.dbValue &&
              r.itemKey == 'video/mine')
          .length,
      1,
      reason: 'host 删除后必须记墓碑，否则删除传播在 host 这里断链',
    );
  });

  test('推送不碰 remotePublishedAt：云通道的账不被互联污染', () async {
    await hostDb.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/mine',
      title: 'Mine',
      videoPath: hostOwnVideo.path,
    ));

    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await localDb.writeSyncDeletionTombstone(
      SyncTombstoneKind.video.dbValue,
      'video/mine',
      DateTime.now().millisecondsSinceEpoch - 1000,
    );

    final InterconnectSyncBackend backend =
        await _buildClientBackend(base: base, token: token);
    await _orchestrator(db: localDb, backend: backend, tmp: work)
        .syncDeletionTombstonesLiveForTest(SyncRunReport(), backend);

    // 不变量 ②：互联推送成功后，墓碑行的 remotePublishedAt 必须仍是 0。
    // 它一旦被标非 0，云通道 syncDeletionTombstones 的 `remotePublishedAt == 0` 过滤
    // 就会永远跳过这条 —— 只连云备份的第三台设备再也收不到这次删除。
    final List<SyncDeletionTombstoneRow> local =
        await localDb.getSyncDeletionTombstones();
    expect(local.single.remotePublishedAt, 0,
        reason: '互联推送与云发布必须各记各的账（推送基线走 preferences）');
    // 互联自己的账：推送基线已推进（下轮不再重推这条）。
    expect(
      await SyncRepository(localDb).getDeletionTombstonesPushBaselineMs(),
      greaterThan(0),
    );
  });

  test('推送后基线推进：第二轮不再重复删（host 已空也不报错）', () async {
    await hostDb.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/mine',
      title: 'Mine',
      videoPath: hostOwnVideo.path,
    ));
    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await localDb.writeSyncDeletionTombstone(
      SyncTombstoneKind.video.dbValue,
      'video/mine',
      DateTime.now().millisecondsSinceEpoch - 1000,
    );
    final InterconnectSyncBackend backend =
        await _buildClientBackend(base: base, token: token);
    final SyncOrchestrator orch =
        _orchestrator(db: localDb, backend: backend, tmp: work);

    await orch.syncDeletionTombstonesLiveForTest(SyncRunReport(), backend);
    final int firstBaseline =
        await SyncRepository(localDb).getDeletionTombstonesPushBaselineMs();
    expect(firstBaseline, greaterThan(0));

    // host 这时又自己导入了同 uid 的视频（模拟「删后重加」）。第二轮推送必须**不**再删它
    // ——那条墓碑的 deletedAt 已在基线之下，不再是新闻。
    await hostDb.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/mine',
      title: 'Mine Again',
      videoPath: hostOwnVideo.path,
    ));
    final SyncRunReport second = SyncRunReport();
    await orch.syncDeletionTombstonesLiveForTest(second, backend);
    expect((await hostDb.allVideoBooks()).length, 1,
        reason: '基线之下的旧墓碑不该反复删掉 host 上重新加回来的条目');
  });

  test('收藏词/收藏句墓碑无互联删除通道：跳过且不阻塞基线推进', () async {
    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await localDb.writeSyncDeletionTombstone(
      SyncTombstoneKind.favoriteword.dbValue,
      'ねこ',
      DateTime.now().millisecondsSinceEpoch - 1000,
    );

    final InterconnectSyncBackend backend =
        await _buildClientBackend(base: base, token: token);
    final SyncRunReport report = SyncRunReport();
    await _orchestrator(db: localDb, backend: backend, tmp: work)
        .syncDeletionTombstonesLiveForTest(report, backend);

    // 聚合通道按设计不传播删除，这里如实跳过：不报错，也不为一件永远做不成的事
    // 把基线永久卡住（那会让书/视频的删除每轮无谓重推）。
    expect(report.errors, isEmpty);
    expect(
      await SyncRepository(localDb).getDeletionTombstonesPushBaselineMs(),
      greaterThan(0),
    );
  });

  test('旧 host 不支持视频删除：DELETE 返 404，client 判 false，基线仍推进', () async {
    // 换一台「旧版本」host（不实现 VideoDeletionHost）。
    final FushiSyncServer legacy = FushiSyncServer(
      syncDataDir: p.join(work.path, 'legacy_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: _LegacyHostWithoutVideoDelete(),
    );
    await legacy.start();
    addTearDown(legacy.stop);
    final String legacyBase = 'http://127.0.0.1:${legacy.port}';

    final InterconnectSyncBackend backend =
        await _buildClientBackend(base: legacyBase, token: token);

    // client 侧能力探测：404 → false（而不是抛异常）。
    expect(await backend.deleteRemoteVideo('video/whatever'), isFalse);

    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await localDb.writeSyncDeletionTombstone(
      SyncTombstoneKind.video.dbValue,
      'video/mine',
      DateTime.now().millisecondsSinceEpoch - 1000,
    );
    final SyncRunReport report = SyncRunReport();
    await _orchestrator(db: localDb, backend: backend, tmp: work)
        .syncDeletionTombstonesLiveForTest(report, backend);

    // 能力缺失如实记进 report（用户/日志可见），但不是暂时性故障，故不阻塞基线：
    // 否则书/有声书的删除会被一条永远推不成的视频删除拖着每轮重推。
    expect(report.errors.any((String e) => e.contains('too old')), isTrue,
        reason: '对端不支持必须留下可见记录，不能静默吞掉');
    expect(
      await SyncRepository(localDb).getDeletionTombstonesPushBaselineMs(),
      greaterThan(0),
    );
  });

  test('DELETE /api/library/videos/<id> 路径穿越拒绝', () async {
    final HttpClient client = HttpClient();
    addTearDown(client.close);
    final HttpClientRequest req = await client.deleteUrl(
      Uri.parse('$base/api/library/videos/..%2Fetc%2Fpasswd'),
    );
    req.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
    );
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 400);
  });
}
