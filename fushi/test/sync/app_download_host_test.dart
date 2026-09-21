/// app 当互联 host 时的代下载 / 订阅面（设计 §3.3，「手机让电脑下」）。
///
/// 此前 `/api/downloads` 只在无头 fushi_server 接线，app 当 host 时对端探到的能力
/// 位里没有 `downloads`，手机端「下载到 电脑」根本不出现。这里对真实
/// [FushiSyncServer] 挂 [AppDownloadHost]（管线是真的、只是不 start），用真实
/// [InterconnectDownloadClient] 走一遍：能力位 → 点名探测 → 投磁链 → 本机
/// `video_download_jobs` 里出现按域入库 / 视频两种行。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/discovery/discovery_download_queue.dart'
    show DiscoveryImportOutcome;
import 'package:fushi_engine/media/discovery/discovery_models.dart'
    show DiscoveryMediaKind;
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/app_download_host.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';

const VideoDownloadBackendIdentity _identity = VideoDownloadBackendIdentity(
  kind: 'embedded',
  profileId: 'embedded',
  fingerprint: 'installation-fingerprint',
);
const VideoDownloadBackendTarget _target = VideoDownloadBackendTarget(
  identity: _identity,
  category: 'fushi',
);
const String _magnet =
    'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a&dn=Frieren';

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SyncRepository repo;
  late VideoDownloadPipelineService pipeline;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi-app-download-host-');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
    pipeline = VideoDownloadPipelineService(
      database: db,
      resourceRegistry: VideoResourceRegistry(const <VideoResourceProvider>[]),
      backendResolver: (_) async => throw StateError('pipeline not started'),
      scrapeCoordinator: VideoSourceScrapeCoordinator(
        database: db,
        config: const VideoSourceScrapeGlobalConfig(),
      ),
      discoveryImporter: (DiscoveryMediaKind kind, List<String> paths) async =>
          const DiscoveryImportOutcome(),
      workerId: 'app-host-test',
    );
  });

  tearDown(() async {
    await pipeline.dispose(drainTimeout: Duration.zero);
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  AppDownloadHost host({
    String? readyBackend = 'embedded',
    bool pipelineUp = true,
    int? sourceId,
  }) =>
      AppDownloadHost(
        database: () => db,
        pipeline: () => pipelineUp ? pipeline : null,
        backendTarget: () async => _target,
        readyBackend: () => readyBackend,
        targetSourceId: () async => sourceId,
        resourceRegistry: () => null,
        subscriptionService: () => null,
      );

  Future<FushiSyncServer> startHost(AppDownloadHost downloads) async {
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: p.join(tmp.path, 'sync'),
      port: 0,
      token: 'tok',
      downloads: downloads,
      subscriptions: downloads.subscriptions,
    );
    await server.start();
    addTearDown(server.stop);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}', deviceName: 'PC'),
    ]);
    await repo.setFushiClientToken('tok');
    return server;
  }

  InterconnectDownloadClient client() => InterconnectDownloadClient(repo: repo);

  test('能力位：后端就绪 → supported + 视频与四个发现域；未就绪 → 手机探不到', () async {
    final FushiSyncServer server = await startHost(host());
    final HostDownloadTarget? target = await client().probe();
    expect(target, isNotNull, reason: 'app 当 host 必须像无头服务端一样宣告代下载');
    expect(target!.deviceName, 'PC');
    expect(target.backend, 'embedded');
    expect(target.kinds,
        containsAll(<String>['video', 'novel', 'manga', 'audiobook', 'game']));
    expect(target.supportsKind(null), isTrue);
    expect(target.supportsKind('novel'), isTrue);
    await server.stop();

    // 本机没配下载后端：能力位如实报 supported=false，客户端当「没有 host」。
    await startHost(host(readyBackend: null));
    expect(await client().probe(), isNull);
  });

  test('probeUrl 只认点名那台，不退而求其次；probeAll 列全', () async {
    final FushiSyncServer server = await startHost(host());
    final InterconnectDownloadClient c = client();
    final String url = 'http://127.0.0.1:${server.port}';
    expect((await c.probeUrl(url))?.baseUrl, url);
    expect(await c.probeUrl('http://192.0.2.1:1'), isNull,
        reason: '用户点名的设备不在清单 / 连不上时不能悄悄换成别的 host');
    expect((await c.probeAll()).map((HostDownloadTarget t) => t.baseUrl),
        <String>[url]);
  });

  test('非视频域磁链 → 本机管线的按域入库行；无头式 kinds 校验走 400', () async {
    final FushiSyncServer server = await startHost(host());
    final InterconnectDownloadClient c = client();
    final HostDownloadTarget target =
        (await c.probeUrl('http://127.0.0.1:${server.port}'))!;
    final String jobId = await c.addMagnet(
      target,
      magnetUri: _magnet,
      title: 'A Novel',
      discoveryKind: DiscoveryMediaKind.novel.name,
    );
    final VideoDownloadJobRow? job = await db.getVideoDownloadJob(jobId);
    expect(job, isNotNull);
    expect(job!.title, 'A Novel');
    expect(job.organizationPolicy,
        manualDiscoveryOrganizationPolicy(DiscoveryMediaKind.novel));
    expect(job.targetSourceId, isNull, reason: '非视频域不需要受管视频来源');
    expect(job.fingerprint, _identity.fingerprint,
        reason: '后端落点是 host 自己的，不信客户端');

    await expectLater(
      c.addMagnet(target,
          magnetUri: _magnet, title: 'x', discoveryKind: 'bogus'),
      throwsA(isA<HostDownloadException>()
          .having((HostDownloadException e) => e.code, 'code', 'http_400')),
    );
  });

  test('视频磁链：没有受管来源 → 409 action_required；有 → library 行', () async {
    final FushiSyncServer server = await startHost(host());
    final InterconnectDownloadClient c = client();
    final String url = 'http://127.0.0.1:${server.port}';
    final HostDownloadTarget target = (await c.probeUrl(url))!;
    await expectLater(
      c.addMagnet(target,
          magnetUri: _magnet, title: 'Frieren', mediaKind: 'tv'),
      throwsA(isA<HostDownloadException>()
          .having((HostDownloadException e) => e.code, 'code', 'http_409')),
    );
    await server.stop();

    final Directory root = Directory(p.join(tmp.path, 'videos'))
      ..createSync(recursive: true);
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Managed videos',
        mediaKind: 'video',
        rootPath: root.path,
        createdAt: 1,
      ),
    );
    final FushiSyncServer second = await startHost(host(sourceId: sourceId));
    final HostDownloadTarget t2 =
        (await c.probeUrl('http://127.0.0.1:${second.port}'))!;
    final String jobId = await c.addMagnet(t2,
        magnetUri: _magnet, title: 'Frieren', mediaKind: 'tv');
    final VideoDownloadJobRow job = (await db.getVideoDownloadJob(jobId))!;
    expect(job.organizationPolicy, 'library');
    expect(job.mediaKind, VideoMetadataMediaKind.tv.name);
    expect(job.targetSourceId, sourceId);
    expect((await c.listJobs(t2)).map((HostDownloadJob j) => j.jobId),
        contains(jobId));
  });

  test('管线没起来 → 能力位不支持、投递 409，而不是 500', () async {
    final FushiSyncServer server = await startHost(host(pipelineUp: false));
    final InterconnectDownloadClient c = client();
    expect(await c.probe(), isNull);
    // 绕过能力位直接投（老客户端 / 竞态）：host 用 ActionRequired 拒绝。
    final HostDownloadTarget forced = HostDownloadTarget(
      baseUrl: 'http://127.0.0.1:${server.port}',
      deviceName: 'PC',
      backend: 'embedded',
    );
    await expectLater(
      c.addMagnet(forced, magnetUri: _magnet, title: 'x'),
      throwsA(isA<HostDownloadException>()
          .having((HostDownloadException e) => e.code, 'code', 'http_409')),
    );
  });

  test('对端删除远端任务：行没了，host 主人的磁盘文件还在', () async {
    // `listJobs` 返回的是本机**全表**（含 host 主人自己加的任务）。对端在「远端
    // 任务」卡片上点删除，语义只能是「别再占我的列表」；连磁盘文件一起删掉的是
    // 用户自己已经下载好的片子。无头 fushi_server 那边整台机器本就为对端服务，
    // 语义不同，不能照搬。
    final int now = DateTime.now().millisecondsSinceEpoch;
    final File downloaded = File(p.join(tmp.path, 'Frieren S01E01.mkv'))
      ..writeAsStringSync('payload');
    await db.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: 'job-remote-1',
        resourceProvider: 'nyaa:test',
        selectedResourceId: 'r1',
        mediaKind: 'tv',
        title: 'Frieren',
        backendKind: 'embedded',
        fingerprint: 'fp',
        lifecycle: const Value<String>(VideoDownloadJobLifecycle.completed),
        stage: const Value<String>(VideoDownloadJobStage.import),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: 'job-remote-1',
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: p.basename(downloaded.path),
        currentRelativePath: p.basename(downloaded.path),
        finalAbsolutePath: Value<String?>(downloaded.path),
        kind: const Value<String>('video'),
        status: const Value<String>(VideoDownloadJobFileStatus.imported),
        createdAt: now,
        updatedAt: now,
      ),
    );

    await host().deleteJob('job-remote-1');

    expect(await db.getVideoDownloadJob('job-remote-1'), isNull,
        reason: '行要删掉');
    expect(
      downloaded.existsSync(),
      isTrue,
      reason: '落盘文件的去留归 host 主人在本机下载中心决定',
    );
  });

  test('订阅面挂在同一组闭包上：registry 没起 → supported=false、列表照常', () async {
    final AppDownloadHost h = host();
    final Map<String, Object?> cap = await h.subscriptions.capability();
    expect(cap['supported'], isFalse);
    expect(cap['providers'], isEmpty);
    expect(await h.subscriptions.list(), isEmpty);
  });
}
