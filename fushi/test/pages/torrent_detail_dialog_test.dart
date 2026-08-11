// TODO-2482：任务详情对话框 —— 能力探测降级与四 tab 数据渲染。
//
// 核心契约：
// - 后端不是 TorrentDetailBackend（或运行时能力位 false）→ Peers/Trackers
//   tab 显示「当前后端不支持」，绝不空白；文件 tab（基础能力）照常。
// - 详情后端 → peers/trackers/优先级下拉/会话状态如实渲染。
// 后端经 backendOverride 注入（不拉起 AppModel）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/pages/implementations/torrent_detail_dialog.dart';

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
  _BaseFakeBackend({
    this.failListTorrents = false,
    this.failListFiles = false,
  });

  /// 模拟「后端持续报错」（qb 掉线 / 内置引擎 session 已死）。
  final bool failListTorrents;
  final bool failListFiles;

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
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async {
    if (failListTorrents) throw StateError('backend offline');
    return <TorrentSnapshot>[_snapshot()];
  }

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async {
    if (failListFiles) throw StateError('backend offline');
    return const <TorrentFileEntry>[
      TorrentFileEntry(name: 'ep01.mkv', size: 2048, progress: 0.5, index: 0),
    ];
  }

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
  _DetailFakeBackend({
    this.peerGate,
    this.trackerGate,
    this.peersUnavailable = false,
    this.trackerUnavailable = false,
    this.trackerUnavailableAfterFirst = false,
  });

  final Future<void>? peerGate;
  final Future<void>? trackerGate;
  final bool peersUnavailable;
  final bool trackerUnavailable;

  /// 首轮成功、后续轮询返回 null：验证轮询偶发失败不把已渲染列表闪掉。
  final bool trackerUnavailableAfterFirst;
  final Completer<void> peerQueryStarted = Completer<void>();
  int trackerCalls = 0;
  final List<(String, int, TorrentFilePriority)> prioritySets =
      <(String, int, TorrentFilePriority)>[];

  @override
  bool get detailAvailable => true;

  @override
  Future<List<TorrentPeerDetail>?> listPeers(String torrentId) async {
    if (!peerQueryStarted.isCompleted) peerQueryStarted.complete();
    final Future<void>? gate = peerGate;
    if (gate != null) await gate;
    if (peersUnavailable) return null;
    return const <TorrentPeerDetail>[
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
  }

  @override
  Future<List<TorrentTrackerDetail>?> listTrackers(String torrentId) async {
    trackerCalls += 1;
    final Future<void>? gate = trackerGate;
    if (gate != null && trackerCalls == 1) await gate;
    if (trackerUnavailable) return null;
    if (trackerUnavailableAfterFirst && trackerCalls > 1) return null;
    return const <TorrentTrackerDetail>[
      TorrentTrackerDetail(
        url: 'http://tracker.example/announce',
        tier: 0,
        status: TorrentTrackerStatus.working,
        seeds: 30,
        leeches: 12,
        downloaded: 100,
      ),
    ];
  }

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

/// 切 tab：`tap` 只是**开始**切换动画。TabController 只有在动画落定
/// （`indexIsChanging` 变回 false）后才通知监听器，被测组件也才会发出该 tab
/// 的请求。所以断言前必须把这段动画泵完；在泵完之前 `await` 一个「还没有人
/// 发起的请求」会让 FakeAsync 时钟停在 await 上不再前进 —— 测试挂死到
/// 10 分钟超时（本文件曾因此必现 TimeoutException）。
Future<void> _switchTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 总览的「网络」区在 ListView 的底部：800×600 的测试视口装不下上面的
/// 任务 / 传输区，而 ListView 不构建屏幕外的孩子，直接断言必然 findsNothing。
/// 断言这些行之前先滚到它出现为止（真机上用户同样是滚动查看）。
Future<void> _scrollUntilFound(WidgetTester tester, Finder target) async {
  for (int i = 0; i < 12 && target.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -160));
    await tester.pump();
  }
}

Future<void> _dismiss(WidgetTester tester) async {
  // 卸载以取消周期定时器，避免测试尾部报 pending timer。
  await tester.pumpWidget(const SizedBox.shrink());
}

Future<void> _pumpPersistedFallback(
  WidgetTester tester, {
  bool backendTaskMissing = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Material(
          child: TorrentTaskDetailDialog.task(
            torrentId: _hash,
            title: 'Persisted Series',
            torrentTitle: 'Persisted release title',
            backendOverride: null,
            backendTaskMissing: backendTaskMissing,
            initialSnapshot: const TorrentSnapshot(
              hash: _hash,
              name: 'Persisted Series',
              progress: 1,
              state: 'completed',
              savePath: r'D:\downloads',
              contentPath: r'D:\downloads\a-very-long-library-folder\season-03\'
                  r'a-very-long-release-name-that-must-wrap-inside-the-dialog.mkv',
              amountLeft: 0,
              totalSizeBytes: 4096,
              downloadedBytes: 4096,
            ),
            initialFiles: const <TorrentFileEntry>[
              TorrentFileEntry(
                name: 'ep01.mkv',
                size: 4096,
                progress: 1,
                index: 0,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('后端在线但任务已不存在时明确说明节点无法恢复', (
    WidgetTester tester,
  ) async {
    await _pumpPersistedFallback(tester, backendTaskMissing: true);
    final Finder missingNote =
        find.textContaining('this torrent is no longer present');
    await _scrollUntilFound(tester, missingNote);
    expect(missingNote, findsOneWidget);
    await _switchTab(tester, 'Peers');
    expect(
      find.textContaining('Live peers and trackers cannot be recovered'),
      findsOneWidget,
    );
    await _dismiss(tester);
  });

  testWidgets('原后端离线时仍展示持久化总览和文件', (
    WidgetTester tester,
  ) async {
    await _pumpPersistedFallback(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Persisted Series'), findsOneWidget);
    expect(find.textContaining('100.0%'), findsOneWidget);
    final Finder offlineNote =
        find.textContaining('The original download backend is offline');
    await _scrollUntilFound(tester, offlineNote);
    expect(offlineNote, findsOneWidget);
    await _switchTab(tester, 'Files');
    expect(find.text('ep01.mkv'), findsOneWidget);
    await _dismiss(tester);
  });

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
    final Finder dhtRow = find.textContaining('DHT nodes: 128');
    await _scrollUntilFound(tester, dhtRow);
    expect(dhtRow, findsOneWidget);
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

  testWidgets('节点刷新未结束时切到Tracker会独立请求并立即渲染', (
    WidgetTester tester,
  ) async {
    final Completer<void> peerGate = Completer<void>();
    final _DetailFakeBackend backend = _DetailFakeBackend(
      peerGate: peerGate.future,
    );
    await _pump(tester, backend);

    // 节点请求已发出但被 gate 卡住（未 complete）。
    await _switchTab(tester, 'Peers');
    expect(backend.peerQueryStarted.isCompleted, isTrue);
    expect(peerGate.isCompleted, isFalse);

    // 此时切到 Trackers：Tracker 请求必须独立发出并立即渲染，不等 peers。
    await _switchTab(tester, 'Trackers');
    expect(backend.trackerCalls, greaterThan(0));
    expect(find.text('http://tracker.example/announce'), findsOneWidget);

    peerGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _dismiss(tester);
  });

  testWidgets('Tracker请求返回null会结束加载并显示失败态', (
    WidgetTester tester,
  ) async {
    final _DetailFakeBackend backend = _DetailFakeBackend(
      trackerUnavailable: true,
    );
    await _pump(tester, backend);
    await tester.tap(find.text('Trackers'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(backend.trackerCalls, greaterThan(0));
    expect(find.text('Something went wrong while loading'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _dismiss(tester);
  });

  testWidgets('总览：快照请求持续抛异常时显示失败态而不是永久转圈', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _BaseFakeBackend(failListTorrents: true));
    expect(find.text('Something went wrong while loading'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _dismiss(tester);
  });

  testWidgets('文件：listFiles 抛异常时显示失败态而不是永久转圈', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _BaseFakeBackend(failListFiles: true));
    await _switchTab(tester, 'Files');
    expect(find.text('Something went wrong while loading'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _dismiss(tester);
  });

  testWidgets('节点：listPeers 返回 null 时显示失败态而不是永久转圈', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _DetailFakeBackend(peersUnavailable: true));
    await _switchTab(tester, 'Peers');
    expect(find.text('Something went wrong while loading'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _dismiss(tester);
  });

  testWidgets('轮询里偶发一次失败不会把已渲染的Tracker列表闪成失败态', (
    WidgetTester tester,
  ) async {
    final _DetailFakeBackend backend = _DetailFakeBackend(
      trackerUnavailableAfterFirst: true,
    );
    await _pump(tester, backend);
    await _switchTab(tester, 'Trackers');
    expect(find.text('http://tracker.example/announce'), findsOneWidget);
    // 下一轮 2s 轮询返回 null（后端偶发抖动）：列表必须留着。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 50));
    expect(backend.trackerCalls, greaterThan(1));
    expect(find.text('http://tracker.example/announce'), findsOneWidget);
    expect(find.text('Something went wrong while loading'), findsNothing);
    await _dismiss(tester);
  });

  testWidgets('在途请求返回时用户已切走：不给不可见的tab补跑', (
    WidgetTester tester,
  ) async {
    final Completer<void> trackerGate = Completer<void>();
    final _DetailFakeBackend backend = _DetailFakeBackend(
      trackerGate: trackerGate.future,
    );
    await _pump(tester, backend);
    await _switchTab(tester, 'Trackers');
    expect(backend.trackerCalls, 1);
    // 首个 Tracker 请求还卡着，2s 轮询排了一次「待补跑」。
    await tester.pump(const Duration(seconds: 2));
    // 用户切走到 Peers，然后卡住的请求才返回。
    await _switchTab(tester, 'Peers');
    trackerGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(backend.trackerCalls, 1);
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
