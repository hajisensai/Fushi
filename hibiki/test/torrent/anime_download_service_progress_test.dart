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

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async =>
      const <TorrentFileEntry>[];

  @override
  void close() {}
}

TorrentSnapshot _snapshot({required double progress, required String state}) {
  return TorrentSnapshot(
    hash: _kHash,
    name: 'torrent',
    progress: progress,
    state: state,
    savePath: '',
    contentPath: '',
    amountLeft: state == 'downloading' ? 100 : 0,
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
