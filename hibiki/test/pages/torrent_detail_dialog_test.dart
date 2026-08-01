// TODO-2482：任务详情对话框 —— 能力探测降级与四 tab 数据渲染。
//
// 核心契约：
// - 后端不是 TorrentDetailBackend（或运行时能力位 false）→ Peers/Trackers
//   tab 显示「当前后端不支持」，绝不空白；文件 tab（基础能力）照常。
// - 详情后端 → peers/trackers/优先级下拉/会话状态如实渲染。
// 后端经 backendOverride 注入（不拉起 AppModel）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki/src/pages/implementations/torrent_detail_dialog.dart';

const String _hash = 'aa11bb22cc33dd44ee55ff66aa77bb88cc99dd00';

AnimeDownloadPlan _plan() => const AnimeDownloadPlan(
      id: _hash,
      createdAtMs: 0,
      seriesTitle: 'Series X',
      torrentTitle: '[Sub] Series X - 01',
      magnet: 'magnet:?xt=urn:btih:$_hash',
      qbCategory: 'hibiki-anime',
    );

TorrentSnapshot _snapshot() => const TorrentSnapshot(
      hash: _hash,
      name: 'Series X',
      progress: 0.5,
      state: 'downloading',
      savePath: '/dl',
      contentPath: '/dl/x',
      amountLeft: 1024,
      downRateBps: 2048,
      upRateBps: 512,
      downloadedBytes: 4096,
      uploadedBytes: 1024,
      numPeers: 3,
      numSeeds: 2,
      numLeechs: 1,
      swarmSeeds: 30,
      swarmLeechs: 12,
      numConnections: 5,
      activeDurationSeconds: 90,
      seedingDurationSeconds: 0,
    );

/// 只有基础能力的假后端（非 TorrentDetailBackend）。
class _BaseFakeBackend implements TorrentBackend {
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
      false;

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      <TorrentSnapshot>[_snapshot()];

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async =>
      const <TorrentFileEntry>[
        TorrentFileEntry(name: 'ep01.mkv', size: 2048, progress: 0.5, index: 0),
      ];

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async =>
      const TorrentStorageResult.failure('unsupported');

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async =>
      const TorrentStorageResult.failure('unsupported');

  @override
  void close() {}
}

/// 全量详情能力的假后端。
class _DetailFakeBackend extends _BaseFakeBackend
    implements TorrentDetailBackend {
  final List<(String, int, TorrentFilePriority)> prioritySets =
      <(String, int, TorrentFilePriority)>[];

  @override
  bool get detailAvailable => true;

  @override
  Future<List<TorrentPeerDetail>?> listPeers(String torrentId) async =>
      const <TorrentPeerDetail>[
        TorrentPeerDetail(
          address: '10.0.0.9',
          port: 6881,
          client: 'qBittorrent/4.6.5',
          progress: 0.75,
          downSpeedBps: 1000,
          upSpeedBps: 200,
          downloadedBytes: 300000,
          uploadedBytes: 5000,
          flags: 'D U',
        ),
      ];

  @override
  Future<List<TorrentTrackerDetail>?> listTrackers(String torrentId) async =>
      const <TorrentTrackerDetail>[
        TorrentTrackerDetail(
          url: 'http://tracker.example/announce',
          tier: 0,
          status: TorrentTrackerStatus.working,
          seeds: 30,
          leeches: 12,
          downloaded: 100,
        ),
      ];

  @override
  Future<List<TorrentFilePriority>?> filePriorities(String torrentId) async =>
      const <TorrentFilePriority>[TorrentFilePriority.normal];

  @override
  Future<bool> setFilePriority(
    String torrentId,
    int fileIndex,
    TorrentFilePriority priority,
  ) async {
    prioritySets.add((torrentId, fileIndex, priority));
    return true;
  }

  @override
  Future<TorrentSessionStatusInfo?> sessionStatus() async =>
      const TorrentSessionStatusInfo(
        dhtEnabled: true,
        dhtNodes: 128,
        lsdEnabled: true,
        pexEnabled: true,
        listenPort: 6881,
        downRateBps: 4096,
        upRateBps: 1024,
        portMappings: <TorrentPortMappingInfo>[
          TorrentPortMappingInfo(
            transport: 'upnp',
            protocol: 'tcp',
            externalPort: 6881,
            ok: true,
          ),
        ],
      );

  @override
  Future<TorrentPieceStates?> pieceStates(String torrentId) async =>
      const TorrentPieceStates(states: <int>[2, 2, 1, 0]);
}

Future<void> _pump(WidgetTester tester, TorrentBackend backend) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Material(
          child: TorrentTaskDetailDialog(
            plan: _plan(),
            backendOverride: backend,
          ),
        ),
      ),
    ),
  );
  // 首轮 _refresh 是异步的；两拍让 setState 落地（不能 pumpAndSettle：
  // 进度条动画 + 周期轮询定时器永不 settle）。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _dismiss(WidgetTester tester) async {
  // 卸载以取消周期定时器，避免测试尾部报 pending timer。
  await tester.pumpWidget(const SizedBox.shrink());
}

void main() {
  testWidgets('基础后端：总览渲染快照，Peers/Trackers tab 显示不支持', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _BaseFakeBackend());
    // 总览：进度 + 拆分字段合成文本。
    expect(find.textContaining('50.0%'), findsOneWidget);
    expect(find.text('2 (30)'), findsOneWidget); // seeds 已连接 (swarm)
    expect(find.text('1 (12)'), findsOneWidget); // leechers
    // 切到 Peers tab → 不支持占位。
    await tester.tap(find.text('Peers'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.text('Not supported by current download backend'),
      findsWidgets,
    );
    await _dismiss(tester);
  });

  testWidgets('详情后端：Peers/Trackers/Files 优先级下拉如实渲染', (
    WidgetTester tester,
  ) async {
    final _DetailFakeBackend backend = _DetailFakeBackend();
    await _pump(tester, backend);
    // 总览网络区：DHT 节点数。
    expect(find.textContaining('DHT nodes: 128'), findsOneWidget);
    // Peers tab。
    await tester.tap(find.text('Peers'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('10.0.0.9:6881'), findsOneWidget);
    expect(find.textContaining('qBittorrent/4.6.5'), findsOneWidget);
    // Trackers tab。
    await tester.tap(find.text('Trackers'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('http://tracker.example/announce'), findsOneWidget);
    expect(find.textContaining('Working'), findsOneWidget);
    // Files tab：优先级下拉存在。
    await tester.tap(find.text('Files'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('ep01.mkv'), findsOneWidget);
    expect(find.byType(DropdownButton<TorrentFilePriority>), findsOneWidget);
    await _dismiss(tester);
  });

  testWidgets('详情后端：改文件优先级真调 setFilePriority', (
    WidgetTester tester,
  ) async {
    final _DetailFakeBackend backend = _DetailFakeBackend();
    await _pump(tester, backend);
    await tester.tap(find.text('Files'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(DropdownButton<TorrentFilePriority>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text("Don't download").last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(backend.prioritySets, isNotEmpty);
    expect(backend.prioritySets.single.$2, 0);
    expect(backend.prioritySets.single.$3, TorrentFilePriority.skip);
    await _dismiss(tester);
  });
}
