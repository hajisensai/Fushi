import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/anime_download_service.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';

const String _kHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

const QbConnectionConfig _kConfig = QbConnectionConfig(
  backend: QbConnectionConfig.backendQbittorrent,
  baseUrl: 'http://127.0.0.1:8080',
);

/// 可编程快照的假后端（服务经 backendFactory 注入，不碰网络）。
class _FakeBackend implements TorrentBackend {
  List<TorrentSnapshot> torrents = <TorrentSnapshot>[];

  @override
  Future<String?> probeConnection() async => 'fake';

  @override
  Future<bool> prepareCategory(String category) async => true;

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async =>
      true;

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      torrents;

  /// 种子内文件清单；默认空（多数用例只关心进度表）。`importNow` 路径需要至少
  /// 一个可识别视频，否则服务在发布进度之前就提前返回。
  List<TorrentFileEntry> files = const <TorrentFileEntry>[];

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async => files;

  @override
  void close() {}

  // TODO-1961-c：本 fake 不测改名/移动路径，给出明确的「未实现」结果而不是
  // 假装成功——真要测这条链路的用例应当显式覆盖它。
  @override
  Future<TorrentStorageResult> renameFile(
          String torrentId, int fileIndex, String newPath) async =>
      const TorrentStorageResult.failure('not supported by fake');

  @override
  Future<TorrentStorageResult> moveStorage(
          String torrentId, String newSavePath) async =>
      const TorrentStorageResult.failure('not supported by fake');
}

TorrentSnapshot _snapshot({
  required double progress,
  required String state,
  int downRateBps = 0,
  int upRateBps = 0,
  int downloadedBytes = 0,
}) {
  return TorrentSnapshot(
    hash: _kHash,
    name: 'torrent',
    progress: progress,
    state: state,
    savePath: '',
    contentPath: '',
    amountLeft: state == 'downloading' ? 100 : 0,
    downRateBps: downRateBps,
    upRateBps: upRateBps,
    downloadedBytes: downloadedBytes,
  );
}

void main() {
  late Directory tempDir;
  late AnimeDownloadPlanStore store;
  late _FakeBackend backend;
  late AnimeDownloadService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('anime-progress-test');
    store = AnimeDownloadPlanStore(
        baseDir: Directory(p.join(tempDir.path, 'anime_downloads')));
    backend = _FakeBackend();
    service = AnimeDownloadService(
      store: store,
      configProvider: () => _kConfig,
      importer: (AnimeDownloadPlan plan, List<String> videos) async =>
          const AnimeDownloadImportOutcome(collectionId: 1),
      backendFactory: (QbConnectionConfig config) => backend,
    );
    await store.save(AnimeDownloadPlan(
      id: _kHash,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      seriesTitle: 'series',
      torrentTitle: 'torrent',
      magnet: 'magnet:?xt=urn:btih:$_kHash',
      qbCategory: 'hibiki',
    ));
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('tick 把后端快照进度透传到 downloadProgress（planId → 0~1）', () async {
    backend.torrents = <TorrentSnapshot>[
      _snapshot(progress: 0.42, state: 'downloading'),
    ];
    await service.tick();
    expect(service.downloadProgress.value, <String, double>{_kHash: 0.42});

    // 下一轮进度前进 → 快照更新。
    backend.torrents = <TorrentSnapshot>[
      _snapshot(progress: 0.9, state: 'downloading'),
    ];
    await service.tick();
    expect(service.downloadProgress.value, <String, double>{_kHash: 0.9});
  });

  test('种子未上后端列表时不产生进度条目（UI 回退不定态）', () async {
    backend.torrents = <TorrentSnapshot>[];
    await service.tick();
    expect(service.downloadProgress.value, isEmpty);
  });

  test('完成入库后条目移出；无 pending 计划时清空', () async {
    backend.torrents = <TorrentSnapshot>[
      _snapshot(progress: 1.0, state: 'stalledUP'),
    ];
    // 完成态不进进度表（listFiles 空 + kindVideo → 入库失败标 failed，
    // 但无论 imported/failed 都不再是 downloading）。
    await service.tick();
    expect(service.downloadProgress.value, isEmpty);

    // pending 清零后，下一轮 tick 保持空表。
    await service.tick();
    expect(service.downloadProgress.value, isEmpty);
  });

  test('tick 同步发布速度/流量观测值到 downloadStats（BUG-1294）', () async {
    backend.torrents = <TorrentSnapshot>[
      _snapshot(
        progress: 0.42,
        state: 'downloading',
        downRateBps: 1048576,
        upRateBps: 2048,
        downloadedBytes: 4096,
      ),
    ];
    await service.tick();
    final DownloadTaskStats stats = service.downloadStats.value[_kHash]!;
    expect(stats.progress, 0.42);
    expect(stats.downRateBps, 1048576);
    expect(stats.upRateBps, 2048);
    expect(stats.downloadedBytes, 4096);

    // 种子从后端消失 → stats 同步清空（与 downloadProgress 键集合一致）。
    backend.torrents = <TorrentSnapshot>[];
    await service.tick();
    expect(service.downloadStats.value, isEmpty);
  });

  // BUG-1296：`_publishProgress` 是**无条件覆盖** downloadStats，而 importNow 那条
  // 路径此前只传进度、stats 走默认空 map → 一次「立即导入」把全表观测值抹掉，
  // 任务行退成不定进度环（UI 侧的百分比也一并没了）直到下一轮 tick 才恢复。
  // 契约：任何发布点都不得把别处刚发布的观测值降级成空。
  test('importNow 发布进度时不清空 downloadStats（BUG-1296）', () async {
    backend.torrents = <TorrentSnapshot>[
      _snapshot(
        progress: 0.42,
        state: 'downloading',
        downRateBps: 1048576,
        upRateBps: 2048,
        downloadedBytes: 4096,
      ),
    ];
    await service.tick();
    expect(service.downloadStats.value[_kHash]?.downRateBps, 1048576);

    // 种子里有可识别视频 → importNow 会走到「未完成也先发进度」那一支。
    backend.files = const <TorrentFileEntry>[
      TorrentFileEntry(
          name: 'Test Anime - 01.mkv', size: 100, progress: 0.42, index: 0),
    ];
    await service.importNow(_kHash);

    expect(
      service.downloadProgress.value[_kHash],
      0.42,
      reason: 'importNow 仍应发布进度',
    );
    expect(
      service.downloadStats.value[_kHash]?.downRateBps,
      1048576,
      reason: 'importNow 手上就有 TorrentSnapshot，不得把观测值清成空表',
    );
  });

  test('轮询周期决策：内置引擎 + 有活跃下载才提频（BUG-1294）', () {
    const QbConnectionConfig embedded =
        QbConnectionConfig(backend: QbConnectionConfig.backendEmbedded);
    const Duration idle = Duration(seconds: 20);

    expect(
      AnimeDownloadService.resolvePollInterval(
        config: embedded,
        hasActiveDownloads: true,
        isDesktop: true,
        idle: idle,
      ),
      AnimeDownloadService.activeInterval,
    );
    // 无活跃下载 → 保持常规周期。
    expect(
      AnimeDownloadService.resolvePollInterval(
        config: embedded,
        hasActiveDownloads: false,
        isDesktop: true,
        idle: idle,
      ),
      idle,
    );
    // 外接 qb：每 tick 都是一次全新 WebUI 登录，提频会放大失败计数
    // （qb 默认 5 次封 IP），恒用常规周期。
    expect(
      AnimeDownloadService.resolvePollInterval(
        config: _kConfig,
        hasActiveDownloads: true,
        isDesktop: true,
        idle: idle,
      ),
      idle,
    );
    // 未配置 → 常规周期。
    expect(
      AnimeDownloadService.resolvePollInterval(
        config: null,
        hasActiveDownloads: true,
        isDesktop: true,
        idle: idle,
      ),
      idle,
    );
  });

  test('后端未配置时清空进度表', () async {
    backend.torrents = <TorrentSnapshot>[
      _snapshot(progress: 0.5, state: 'downloading'),
    ];
    await service.tick();
    expect(service.downloadProgress.value, isNotEmpty);

    final AnimeDownloadService unconfigured = AnimeDownloadService(
      store: store,
      configProvider: () => null,
      importer: (AnimeDownloadPlan plan, List<String> videos) async => null,
      backendFactory: (QbConnectionConfig config) => backend,
    );
    await unconfigured.tick();
    expect(unconfigured.downloadProgress.value, isEmpty);
  });
}
