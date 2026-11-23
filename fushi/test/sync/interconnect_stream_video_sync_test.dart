/// 互联流媒体书行对齐（拍板台 Z2OhxAjKVv：Mac 与 Android 的 YouTube 观看进度不同步）。
///
/// 端到端：真实 server / host / client，client 跑 [SyncOrchestrator.run]。流媒体书
/// （`video/stream/` 身份族 + http(s) URL）没有字节可传，此前永远只在本机；现在
/// 本机独有的注册给 host、host 新有的落到本机，两端都有之后进度照常同步。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/stream_video_sync.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 声明不认识流媒体书注册（老 host 的形状）：能力探测回空表。
class _NoStreamCapabilityBackend extends InterconnectSyncBackend {
  _NoStreamCapabilityBackend()
    : super.withProbe((String u, String t) async => true);

  int pushes = 0;

  @override
  Future<bool> hostAcceptsStreamVideos() async => false;

  @override
  Future<StreamVideoPushResult> putRemoteStreamVideo(
    String id,
    StreamVideoRegistration entry, {
    int? presentSinceAt,
  }) {
    pushes++;
    return super.putRemoteStreamVideo(
      id,
      entry,
      presentSinceAt: presentSinceAt,
    );
  }
}

/// 在网络往返的「中途」插入本机操作，复现 sweep 快照与用户删除的竞态
/// （HBK-AUDIT-213）：[onList] 在清单 GET 返回之前跑，[onCapability] 在能力探测
/// 返回之前跑（此时本机快照已读、PUT 还没发）。
class _RaceBackend extends InterconnectSyncBackend {
  _RaceBackend() : super.withProbe((String u, String t) async => true);

  Future<void> Function()? onList;
  Future<void> Function()? onCapability;
  int pushes = 0;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async {
    final List<RemoteVideoInfo> list = await super.listRemoteVideos();
    final Future<void> Function()? hook = onList;
    onList = null;
    if (hook != null) await hook();
    return list;
  }

  @override
  Future<bool> hostAcceptsStreamVideos() async {
    final bool accepts = await super.hostAcceptsStreamVideos();
    final Future<void> Function()? hook = onCapability;
    onCapability = null;
    if (hook != null) await hook();
    return accepts;
  }

  @override
  Future<StreamVideoPushResult> putRemoteStreamVideo(
    String id,
    StreamVideoRegistration entry, {
    int? presentSinceAt,
  }) {
    pushes++;
    return super.putRemoteStreamVideo(
      id,
      entry,
      presentSinceAt: presentSinceAt,
    );
  }
}

const String _streamUid = 'video/stream/0123456789ab';
const String _streamUrl = 'https://example.com/live/master.m3u8';
const String _spec = '{"referer":"https://example.com/"}';

Future<InterconnectSyncBackend> _clientBackend(
  String base,
  String token, {
  InterconnectSyncBackend? instance,
}) async {
  final FushiDatabase db = _memDb();
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setFushiClientToken(token);
  final InterconnectSyncBackend backend =
      instance ??
      InterconnectSyncBackend.withProbe((String u, String t) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

SyncOrchestrator _orchestrator(
  FushiDatabase db,
  SyncBackend backend,
  Directory tmp,
) => SyncOrchestrator(
  db: db,
  backend: backend,
  dictionaryResourceRoot: tmp,
  audioDatabaseRoot: tmp,
  tempDir: tmp,
  syncStats: false,
  syncAudioBookPosition: false,
  syncContent: false,
  syncMangaContent: false,
  syncAudioBookFiles: false,
  syncVideoFiles: false,
  syncDictionary: false,
);

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late String base;
  const String token = 'stream-video-sync-token';

  setUp(() async {
    work = await Directory.systemTemp.createTemp('stream_video_sync_');
    hostDb = _memDb();
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: LocalLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory(work.path),
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        videoCoversDirectory: Directory(p.join(work.path, 'host_covers')),
      ),
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.stop();
    await hostDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  test('isSyncableStreamVideo 只认 video/stream/ 身份族 + http(s) 地址', () {
    expect(
      isSyncableStreamVideo(bookUid: _streamUid, videoPath: _streamUrl),
      isTrue,
    );
    expect(
      isSyncableStreamVideo(
        bookUid: 'video/stream/yt:dQw4w9WgXcQ',
        videoPath: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      ),
      isTrue,
    );
    // 本地视频 / 不同身份族 / 非 http 协议都不在此列。
    expect(
      isSyncableStreamVideo(bookUid: 'video/movie', videoPath: _streamUrl),
      isFalse,
    );
    expect(
      isSyncableStreamVideo(bookUid: 'video/stream', videoPath: _streamUrl),
      isFalse,
    );
    expect(
      isSyncableStreamVideo(
        bookUid: 'video/stream/abc',
        videoPath: 'rtsp://10.0.0.1/live',
      ),
      isFalse,
    );
    expect(
      isSyncableStreamVideo(
        bookUid: 'video/stream/abc',
        videoPath: '/home/u/a.mp4',
      ),
      isFalse,
    );
  });

  test('本机独有的流媒体书注册给 host，进度随后推到 host；重复 sweep 不重复注册', () async {
    final FushiDatabase local = _memDb();
    addTearDown(local.close);
    await local.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: _streamUid,
        title: 'Korean Podcast 59',
        videoPath: _streamUrl,
        streamSpecJson: const Value<String?>(_spec),
        importedAt: const Value<int?>(1000),
      ),
    );
    // 本机看到 6:20（resume 路径写的位置 + 戳）。
    final int at = DateTime.now().millisecondsSinceEpoch - 60000;
    await local.updateVideoBookPosition(_streamUid, 380000, playedAt: at);
    await local.setPrefTyped<int>(
      videoRemotePositionPrefKey(_streamUid),
      380000,
    );
    await local.setPrefTyped<int>(videoRemotePositionAtPrefKey(_streamUid), at);

    final InterconnectSyncBackend backend = await _clientBackend(base, token);
    final SyncRunReport report = await _orchestrator(
      local,
      backend,
      work,
    ).run();
    expect(report.errors, isEmpty, reason: report.errors.join('\n'));
    expect(report.streamVideosPushed, 1);

    final VideoBookRow hosted = (await hostDb.allVideoBooks()).single;
    expect(hosted.bookUid, _streamUid);
    expect(hosted.title, 'Korean Podcast 59');
    expect(hosted.videoPath, _streamUrl);
    expect(hosted.streamSpecJson, _spec);
    // 同一轮里进度就对上了：host 断点 = 本机的 6:20。
    final RemoteVideoInfo info = (await backend.listRemoteVideos()).single;
    expect(info.positionMs, 380000);
    expect(info.stream?.url, _streamUrl);
    expect(info.peerPlayable, isFalse);

    final SyncRunReport again = await _orchestrator(local, backend, work).run();
    expect(again.errors, isEmpty, reason: again.errors.join('\n'));
    expect(again.streamVideosPushed, 0);
    expect((await hostDb.allVideoBooks()).length, 1);
  });

  // HBK-AUDIT-213：本机快照若在 host 清单 GET 之前读，GET 期间删掉的本机独有
  // 流媒体书仍会被注册给 host，随后在别的设备上复活。
  test('清单 GET 期间本机删掉的流媒体书不注册给 host', () async {
    final FushiDatabase local = _memDb();
    addTearDown(local.close);
    await local.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: _streamUid,
        title: 'Stream',
        videoPath: _streamUrl,
      ),
    );
    final _RaceBackend backend = _RaceBackend();
    await _clientBackend(base, token, instance: backend);
    backend.onList = () => local.deleteVideoBooks(<String>[_streamUid]);
    final SyncRunReport report = SyncRunReport();
    await _orchestrator(
      local,
      backend,
      work,
    ).syncVideoProgressLiveForTest(report, backend);
    expect(report.errors, isEmpty, reason: report.errors.join('\n'));
    expect(backend.pushes, 0);
    expect(report.streamVideosPushed, 0);
    expect(await hostDb.allVideoBooks(), isEmpty);
  });

  test('本机快照之后、注册 PUT 之前删掉的流媒体书不注册给 host', () async {
    final FushiDatabase local = _memDb();
    addTearDown(local.close);
    for (final String uid in <String>[_streamUid, '${_streamUid}x']) {
      await local.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: uid,
          videoPath: _streamUrl,
        ),
      );
    }
    final _RaceBackend backend = _RaceBackend();
    await _clientBackend(base, token, instance: backend);
    backend.onCapability = () => local.deleteVideoBooks(<String>[_streamUid]);
    final SyncRunReport report = SyncRunReport();
    await _orchestrator(
      local,
      backend,
      work,
    ).syncVideoProgressLiveForTest(report, backend);
    expect(report.errors, isEmpty, reason: report.errors.join('\n'));
    // 删掉的那条不发，还在的那条照常注册。
    expect(backend.pushes, 1);
    expect(report.streamVideosPushed, 1);
    expect(
      (await hostDb.allVideoBooks()).map((VideoBookRow r) => r.bookUid),
      <String>['${_streamUid}x'],
    );
  });

  test('host 新有的流媒体书落到本机并带上 host 进度；本机删掉后不再建回', () async {
    await hostDb.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: _streamUid,
        title: 'Korean Podcast 59',
        videoPath: _streamUrl,
        streamSpecJson: const Value<String?>(_spec),
        importedAt: const Value<int?>(2000),
      ),
    );
    final int at = DateTime.now().millisecondsSinceEpoch - 60000;
    await hostDb.setPrefTyped<int>(
      videoRemotePositionPrefKey(_streamUid),
      380000,
    );
    await hostDb.setPrefTyped<int>(
      videoRemotePositionAtPrefKey(_streamUid),
      at,
    );

    final FushiDatabase local = _memDb();
    addTearDown(local.close);
    final InterconnectSyncBackend backend = await _clientBackend(base, token);
    final SyncRunReport report = await _orchestrator(
      local,
      backend,
      work,
    ).run();
    expect(report.errors, isEmpty, reason: report.errors.join('\n'));
    expect(report.streamVideosPulled, 1);
    expect(report.needsLocalLibraryRefresh, isTrue);

    final VideoBookRow pulled = (await local.allVideoBooks()).single;
    expect(pulled.bookUid, _streamUid);
    expect(pulled.title, 'Korean Podcast 59');
    expect(pulled.videoPath, _streamUrl);
    expect(pulled.streamSpecJson, _spec);
    expect(pulled.importedAt, 2000);
    // 同一轮里 host 的 6:20 就写回了本机行。
    expect(pulled.lastPositionMs, 380000);

    // 仅本机删除（不写墓碑）：下一轮不建回来。
    await local.deleteVideoBooks(<String>[_streamUid]);
    final SyncRunReport after = await _orchestrator(local, backend, work).run();
    expect(after.errors, isEmpty, reason: after.errors.join('\n'));
    expect(after.streamVideosPulled, 0);
    expect(await local.allVideoBooks(), isEmpty);
  });

  // 本机推给 host 的那条也要进拉取基线：否则推完、下一轮之前「仅本机删除」，
  // 下一轮 host 清单里它的拥有时刻晚于基线（首轮基线还是 0），会被当成 host 新有的
  // 拉回本机。
  test('本机推给 host 的流媒体书仅本机删除后，下一轮不被拉回', () async {
    final FushiDatabase local = _memDb();
    addTearDown(local.close);
    await local.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: _streamUid,
        title: 'Stream',
        videoPath: _streamUrl,
      ),
    );
    final InterconnectSyncBackend backend = await _clientBackend(base, token);
    final SyncRunReport first = await _orchestrator(local, backend, work).run();
    expect(first.errors, isEmpty, reason: first.errors.join('\n'));
    expect(first.streamVideosPushed, 1);

    await local.deleteVideoBooks(<String>[_streamUid]);
    final SyncRunReport after = await _orchestrator(local, backend, work).run();
    expect(after.errors, isEmpty, reason: after.errors.join('\n'));
    expect(after.streamVideosPulled, 0);
    expect(await local.allVideoBooks(), isEmpty);
  });

  test('本机「从所有设备删除」的墓碑挡住拉取', () async {
    await hostDb.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: _streamUid,
        title: 'Stream',
        videoPath: _streamUrl,
      ),
    );
    final FushiDatabase local = _memDb();
    addTearDown(local.close);
    // 墓碑晚于 host 拥有时刻：删除之前 host 就有的那条。
    await local.writeSyncDeletionTombstones('video', <String>[
      _streamUid,
    ], DateTime.now().millisecondsSinceEpoch + 1000);
    final InterconnectSyncBackend backend = await _clientBackend(base, token);
    final SyncRunReport report = await _orchestrator(
      local,
      backend,
      work,
    ).run();
    expect(report.streamVideosPulled, 0);
    expect(await local.allVideoBooks(), isEmpty);
  });

  test('host 不声明 streamVideos 能力：一个注册请求都不发', () async {
    final FushiDatabase local = _memDb();
    addTearDown(local.close);
    await local.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: _streamUid,
        title: 'Stream',
        videoPath: _streamUrl,
      ),
    );
    final _NoStreamCapabilityBackend backend = _NoStreamCapabilityBackend();
    await _clientBackend(base, token, instance: backend);
    final SyncRunReport report = await _orchestrator(
      local,
      backend,
      work,
    ).run();
    expect(report.errors, isEmpty, reason: report.errors.join('\n'));
    expect(backend.pushes, 0);
    expect(await hostDb.allVideoBooks(), isEmpty);
  });

  test('注册端点拒收非流媒体身份 / 非 http 地址（400），也不建行', () async {
    final InterconnectSyncBackend backend = await _clientBackend(base, token);
    expect(await backend.hostAcceptsStreamVideos(), isTrue);
    await expectLater(
      backend.putRemoteStreamVideo(
        'video/movie',
        const StreamVideoRegistration(title: 'x', url: _streamUrl),
      ),
      throwsA(anything),
    );
    await expectLater(
      backend.putRemoteStreamVideo(
        _streamUid,
        const StreamVideoRegistration(title: 'x', url: 'file:///etc/passwd'),
      ),
      throwsA(anything),
    );
    expect(await hostDb.allVideoBooks(), isEmpty);
    // host 已有同 uid 的行不被覆盖。
    await hostDb.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: _streamUid,
        title: 'Host title',
        videoPath: _streamUrl,
      ),
    );
    expect(
      await backend.putRemoteStreamVideo(
        _streamUid,
        const StreamVideoRegistration(title: 'Client title', url: _streamUrl),
      ),
      StreamVideoPushResult.existed,
    );
    expect((await hostDb.allVideoBooks()).single.title, 'Host title');
  });
}
