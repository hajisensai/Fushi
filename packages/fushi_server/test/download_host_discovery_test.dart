import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_sweep_ledger.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/discovery_import_host.dart';
import 'package:fushi_server/src/download_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_server/src/video_scrape_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 服务端代下载的非视频域：能力位 `kinds` 与真实能执行的一致；小说从入队、
/// 「下载」（假后端报完成、文件就在磁盘上）到落进服务端书库一条龙；接不了的
/// 域 400、接不了的文件（PDF）以稳定原因码挡下而不是假装导入了。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late Directory saveRoot;
  late _CompletedTorrentBackend backend;
  late ServerDownloadHost host;

  const String hash = '0123456789abcdef0123456789abcdef01234567';
  const String magnet = 'magnet:?xt=urn:btih:$hash&dn=novel';

  Future<ServerDownloadHost> build(List<(String, List<int>)> files) async {
    saveRoot = Directory(p.join(tmp.path, 'torrent_save'))..createSync(recursive: true);
    final List<TorrentFileEntry> entries = <TorrentFileEntry>[];
    for (int i = 0; i < files.length; i++) {
      final (String rel, List<int> bytes) = files[i];
      File(p.join(saveRoot.path, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      entries.add(TorrentFileEntry(name: rel, size: bytes.length, progress: 1, index: i));
    }
    backend = _CompletedTorrentBackend(
      snapshot: TorrentSnapshot(
        hash: hash,
        name: 'Pack',
        progress: 1,
        state: 'uploading',
        savePath: saveRoot.path,
        contentPath: p.join(saveRoot.path, p.split(files.first.$1).first),
        amountLeft: 0,
      ),
      files: entries,
    );
    final ServerConfig config = ServerConfig.defaults(dataDir: p.join(tmp.path, 'data'));
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerDownloadHost built = ServerDownloadHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: await ServerIdentity.loadOrCreate(prefs),
      scrape: ServerVideoScrape(
        db: db,
        prefs: prefs,
        config: () => config,
        ledger: VideoScrapeSweepLedger(),
        coordinatorFactory: (scrapeConfig) => VideoSourceScrapeCoordinator(
          database: db,
          config: scrapeConfig,
          registry: VideoMetadataProviderRegistry(const <VideoMetadataProvider>[]),
        ),
      ),
      backendOverride: backend,
      pollInterval: const Duration(milliseconds: 20),
    );
    await built.start();
    return built;
  }

  Future<VideoDownloadJobRow> waitFor(String jobId, bool Function(VideoDownloadJobRow row) done) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final VideoDownloadJobRow? row = await db.getVideoDownloadJob(jobId);
      if (row != null && done(row)) return row;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('job $jobId stuck: ${await db.getVideoDownloadJob(jobId)}');
  }

  bool settled(VideoDownloadJobRow row) =>
      row.lifecycle == VideoDownloadJobLifecycle.completed ||
      row.lifecycle == VideoDownloadJobLifecycle.failed ||
      row.lifecycle == VideoDownloadJobLifecycle.needsAttention;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_dl_kinds_');
    enginePaths = ServerPaths(p.join(tmp.path, 'data'));
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await host.stop();
    await db.close();
    enginePaths = const UninstalledEnginePaths();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('能力位 kinds = video + 服务端真能入库的域；game 投了 400（ArgumentError）', () async {
    host = await build(<(String, List<int>)>[('Novel/book.txt', 'x'.codeUnits)]);
    final Map<String, Object?> cap = await host.capability();
    expect(cap['supported'], isTrue);
    expect(cap['kinds'], <String>['video', 'novel', 'manga', 'audiobook']);
    // 宣告的非视频域必须是协议里的合法值，且不含游戏。
    expect(kHostDownloadDiscoveryKinds.containsAll(kServerDownloadDiscoveryKinds), isTrue);
    expect(kServerDownloadDiscoveryKinds, isNot(contains('game')));
    await expectLater(
      host.add(HostDownloadAddRequest.magnet(magnetUri: magnet, title: 'Game', discoveryKind: 'game')),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      host.add(HostDownloadAddRequest.magnet(magnetUri: magnet, title: 'X', discoveryKind: 'nonsense')),
      throwsA(isA<ArgumentError>()),
    );
    expect(await db.getVideoDownloadJobs(), isEmpty, reason: '被拒的域不能留下任务行');
  });

  test('小说（txt）：入队 → 下载完成 → 转 EPUB 落进服务端书库', () async {
    host = await build(<(String, List<int>)>[
      ('Novel/吾輩は猫である.txt', utf8.encode('吾輩は猫である。名前はまだ無い。\n\nどこで生れたかとんと見当がつかぬ。\n')),
    ]);

    final String jobId = await host.add(HostDownloadAddRequest.magnet(magnetUri: magnet, title: '吾輩は猫である', discoveryKind: 'novel'));
    final VideoDownloadJobRow row = await waitFor(jobId, settled);
    expect(row.lifecycle, VideoDownloadJobLifecycle.completed, reason: '${row.lastError}');
    expect(row.organizationPolicy, 'discovery-novel');
    expect(row.targetSourceId, isNull, reason: '非视频任务不进受管视频来源');
    expect(backend.addCalls, 1);
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books, hasLength(1));
    expect(books.single.title, '吾輩は猫である');
  });

  test('小说包里的 PDF：服务端接不了，任务带 unsupportedOnThisHost 挡下、书库不动', () async {
    host = await build(<(String, List<int>)>[('Novel/scan.pdf', '%PDF-1.4\n'.codeUnits)]);
    final String jobId = await host.add(HostDownloadAddRequest.magnet(magnetUri: magnet, title: 'scan', discoveryKind: 'novel'));
    final VideoDownloadJobRow row = await waitFor(jobId, settled);
    expect(row.lifecycle, isNot(VideoDownloadJobLifecycle.completed));
    expect(row.lastError, contains('unsupportedOnThisHost'));
    expect(await db.getAllEpubBooks(), isEmpty);
  });
}

/// 永远「已下载完成」的假后端：文件已经在 [TorrentSnapshot.savePath] 下。
class _CompletedTorrentBackend implements TorrentBackend {
  _CompletedTorrentBackend({required this.snapshot, required this.files});

  final TorrentSnapshot snapshot;
  final List<TorrentFileEntry> files;
  int addCalls = 0;

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    String? savePath,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async {
    addCalls += 1;
    return true;
  }

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      addCalls == 0 ? const <TorrentSnapshot>[] : <TorrentSnapshot>[snapshot];

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async => files;

  @override
  Future<bool> prepareCategory(String category) async => true;

  @override
  Future<String?> probeConnection() async => 'fake';

  @override
  Future<TorrentStorageResult> renameFile(String torrentId, int fileIndex, String newPath) async =>
      TorrentStorageResult(ok: true, path: newPath);

  @override
  Future<TorrentStorageResult> moveStorage(String torrentId, String newSavePath) async =>
      TorrentStorageResult(ok: true, path: newSavePath);

  @override
  void close() {}
}
