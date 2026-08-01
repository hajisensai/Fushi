import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/anime_download_service.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki/src/media/video/anilist_client.dart';
import 'package:hibiki/src/media/torrent/nyaa_client.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/anime_download_dialog.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1006：番剧下载推送成功后的收尾在 embedded（下载页内联）模式下不得
/// `Navigator.pop`——内联模式没有对话框可关，pop 会把宿主路由（下载 tab 页）
/// 弹掉，Android 上等于整页退出/黑屏。独立对话框模式则必须照旧 pop 自己。
///
/// 用 [AnimeDownloadDialog.debugInitialMedia] / [debugInitialTorrent] 直达
/// 确认推送阶段（绕开 AniList/Nyaa 网络），后端/计划存储全 fake，走真实
/// [_push] 代码路径黑盒断言导航栈行为。

const String _kHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

const AniListMedia _kMedia = AniListMedia(
  id: 1,
  romaji: 'Test Anime',
  episodes: 12,
  seasonYear: 2026,
);

const NyaaTorrent _kTorrent = NyaaTorrent(
  title: '[Group] Test Anime - 01 [1080p]',
  torrentUrl: 'https://nyaa.si/download/1.torrent',
  pageUrl: 'https://nyaa.si/view/1',
  infoHash: _kHash,
  seeders: 100,
  leechers: 1,
  downloads: 1000,
  sizeText: '1.4 GiB',
  sizeBytes: 1503238553,
  categoryId: '1_2',
  trusted: false,
  remake: false,
  pubDate: null,
);

/// 纯内存计划存储：覆写全部 IO 方法，widget 测试的 FakeAsync 区不碰真实文件。
class _MemPlanStore extends AnimeDownloadPlanStore {
  _MemPlanStore() : super(baseDir: Directory('unused-mem-store'));

  final Map<String, AnimeDownloadPlan> plans = <String, AnimeDownloadPlan>{};

  @override
  Future<List<AnimeDownloadPlan>> loadAll() async {
    final List<AnimeDownloadPlan> out = plans.values.toList()
      ..sort((AnimeDownloadPlan a, AnimeDownloadPlan b) {
        final int byTime = a.createdAtMs.compareTo(b.createdAtMs);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    return out;
  }

  @override
  Future<bool> save(AnimeDownloadPlan plan) async {
    plans[plan.id] = plan;
    return true;
  }

  @override
  Future<void> delete(String id) async {
    plans.remove(id);
  }
}

/// 恒成功的假种子后端。
class _FakeBackend implements TorrentBackend {
  int addCalls = 0;

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
  }) async {
    addCalls++;
    return true;
  }

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      const <TorrentSnapshot>[];

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async =>
      const <TorrentFileEntry>[];

  @override
  void close() {}

  // TODO-1961-c：本 fake 不测改名/移动路径，给出明确的「未实现」结果而不是
  // 假装成功——真要测这条链路的用例应当显式覆盖它。
  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async =>
      const TorrentStorageResult.failure('not supported by fake');

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async =>
      const TorrentStorageResult.failure('not supported by fake');
}

class _FakeAppModel extends AppModel {
  _FakeAppModel() : super(testPlatformServices()) {
    service = AnimeDownloadService(
      store: store,
      configProvider: () => qbConnectionConfig,
      backendFactory: (_) => backend,
      importer: (_, __) async =>
          const AnimeDownloadImportOutcome(collectionId: 42),
    );
  }

  final _MemPlanStore store = _MemPlanStore();
  final _FakeBackend backend = _FakeBackend();
  late final AnimeDownloadService service;

  @override
  String get jimakuApiKey => 'key';

  @override
  QbConnectionConfig? get qbConnectionConfig => const QbConnectionConfig(
        backend: QbConnectionConfig.backendQbittorrent,
        baseUrl: 'http://127.0.0.1:1',
      );

  @override
  bool get torrentUploadIntroShown => true;

  @override
  AnimeDownloadPlanStore? get animeDownloadPlanStore => store;

  @override
  AnimeDownloadService? get animeDownloadService => service;

  @override
  TorrentBackend createTorrentBackend(QbConnectionConfig config) => backend;
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Future<(_FakeAppModel, GlobalKey<NavigatorState>)> pumpHost(
    WidgetTester tester,
  ) async {
    final _FakeAppModel appModel = _FakeAppModel();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: const Scaffold(body: Center(child: Text('base-route'))),
          ),
        ),
      ),
    );
    return (appModel, navKey);
  }

  testWidgets('embedded 推送成功不 pop 宿主路由，复位搜番阶段并刷新任务区', (
    WidgetTester tester,
  ) async {
    final (_FakeAppModel appModel, GlobalKey<NavigatorState> navKey) =
        await pumpHost(tester);

    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const Scaffold(
          body: AnimeDownloadDialog(
            embedded: true,
            debugInitialMedia: _kMedia,
            debugInitialTorrent: _kTorrent,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 直达确认推送阶段。
    expect(find.text(t.anime_download_push), findsOneWidget);

    await tester.tap(find.text(t.anime_download_push));
    await tester.pumpAndSettle();

    // 宿主路由未被弹掉（BUG-1006 回归断言）：内联页仍在栈顶。
    expect(find.byType(AnimeDownloadDialog), findsOneWidget);
    expect(find.text('base-route'), findsNothing);

    // 已复位回搜番初始阶段（推送按钮消失、搜番输入框出现）。
    expect(find.text(t.anime_download_push), findsNothing);
    expect(find.text(t.anime_download_search_hint), findsOneWidget);

    // 计划已落盘且任务区计数刷新。
    expect(
      appModel.store.plans[_kHash]?.status,
      AnimeDownloadPlan.statusDownloading,
    );
    expect(appModel.backend.addCalls, 1);
    expect(find.text('${t.anime_download_tasks} (1)'), findsOneWidget);
  });

  testWidgets('early task 在 800x600/窄屏保留真实进度与生命周期语义，隐藏重复 import', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    for (final Size size in <Size>[
      const Size(800, 600),
      const Size(360, 600),
    ]) {
      tester.view.physicalSize = size;
      final (_FakeAppModel appModel, GlobalKey<NavigatorState> navKey) =
          await pumpHost(tester);
      appModel.store.plans[_kHash] = AnimeDownloadPlan(
        id: _kHash,
        createdAtMs: 1,
        seriesTitle:
            'A deliberately long translated series title that must remain usable',
        torrentTitle:
            '[Group] A deliberately long torrent title - 01 [2160p HDR]',
        magnet: 'magnet:?xt=urn:btih:$_kHash',
        qbCategory: 'hibiki',
        importedEarly: true,
        collectionId: 42,
      );
      appModel.service.downloadProgress.value = <String, double>{_kHash: 0.55};

      navKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => const Scaffold(
            body: AnimeDownloadDialog(
              embedded: true,
              tasksOnly: true,
              showTasks: false,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.takeException(), isNull);
      expect(find.text('55%'), findsOneWidget);
      expect(find.text(t.anime_download_streaming_ready), findsOneWidget);
      expect(find.byTooltip(t.anime_download_play_now), findsNothing);
      expect(find.byTooltip(t.anime_download_relocate), findsOneWidget);
      expect(find.byTooltip(t.anime_download_delete), findsOneWidget);
      final HibikiIconButton deleteButton = tester.widget<HibikiIconButton>(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is HibikiIconButton &&
              widget.tooltip == t.anime_download_delete,
        ),
      );
      expect(deleteButton.icon, Icons.delete_outline);
      expect(deleteButton.onTap, isNotNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  // BUG-1296：百分比与确定进度环的存活条件必须是「有进度」，不是「有完整观测
  // 值」。BUG-1294 把任务行整个搬到 downloadStats 之后，任何只发布进度不发布观测
  // 值的路径（`importNow`）都会让百分比直接消失。这里正反两面各钉一次。
  testWidgets('任务行：只有进度也渲染百分比；有观测值才追加速度/流量（BUG-1296）', (
    WidgetTester tester,
  ) async {
    final (_FakeAppModel appModel, GlobalKey<NavigatorState> navKey) =
        await pumpHost(tester);
    appModel.store.plans[_kHash] = AnimeDownloadPlan(
      id: _kHash,
      createdAtMs: 1,
      seriesTitle: 'Test Anime',
      torrentTitle: '[Group] Test Anime - 01 [1080p]',
      magnet: 'magnet:?xt=urn:btih:$_kHash',
      qbCategory: 'hibiki',
      status: AnimeDownloadPlan.statusDownloading,
    );
    // 只有进度、没有观测值（= importNow 刚发布完的那一瞬间）。
    appModel.service.downloadProgress.value = <String, double>{_kHash: 0.55};

    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const Scaffold(
          body: AnimeDownloadDialog(
            embedded: true,
            tasksOnly: true,
            showTasks: false,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('55%'),
      findsOneWidget,
      reason: '观测值缺席时百分比不能跟着消失（只少速度/流量后缀）',
    );
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .value,
      0.55,
      reason: '确定进度环同样只依赖进度',
    );

    // 观测值到位 → 同一行追加速度与累计流量，百分比仍在最前。
    appModel.service.downloadStats.value = <String, DownloadTaskStats>{
      _kHash: const DownloadTaskStats(
        progress: 0.55,
        downRateBps: 1048576,
        upRateBps: 0,
        downloadedBytes: 0,
        uploadedBytes: 0,
        numPeers: 0,
        // TODO-2481：state 未知词 → 状态段不渲染，本用例仍只看速度段。
        state: '',
        amountLeft: -1,
      ),
    };
    await tester.pump();

    expect(find.text('55%'), findsNothing);
    expect(
      find.textContaining('55% · ↓ '),
      findsOneWidget,
      reason: 'BUG-1294 的速度/流量是百分比之后的追加段，不是替换',
    );
  });

  testWidgets('独立对话框模式推送成功仍关闭自身（向后兼容）', (WidgetTester tester) async {
    final (_FakeAppModel appModel, GlobalKey<NavigatorState> navKey) =
        await pumpHost(tester);

    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const Scaffold(
          body: AnimeDownloadDialog(
            debugInitialMedia: _kMedia,
            debugInitialTorrent: _kTorrent,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.anime_download_push), findsOneWidget);

    await tester.tap(find.text(t.anime_download_push));
    await tester.pumpAndSettle();

    // 对话框路由已关闭，回到宿主。
    expect(find.byType(AnimeDownloadDialog), findsNothing);
    expect(find.text('base-route'), findsOneWidget);
    expect(
      appModel.store.plans[_kHash]?.status,
      AnimeDownloadPlan.statusDownloading,
    );
  });

  testWidgets('失败任务行直显失败原因并可重试（复位 downloading）', (WidgetTester tester) async {
    final (_FakeAppModel appModel, GlobalKey<NavigatorState> navKey) =
        await pumpHost(tester);
    appModel.store.plans[_kHash] = AnimeDownloadPlan(
      id: _kHash,
      createdAtMs: 1,
      seriesTitle: 'Test Anime',
      torrentTitle: '[Group] Test Anime - 01 [1080p]',
      magnet: 'magnet:?xt=urn:btih:$_kHash',
      qbCategory: 'hibiki',
      status: AnimeDownloadPlan.statusFailed,
      failReason: 'video import failed: boom',
    );

    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            const Scaffold(body: AnimeDownloadDialog(embedded: true)),
      ),
    );
    await tester.pumpAndSettle();

    // 展开任务折叠区。
    await tester.tap(find.text('${t.anime_download_tasks} (1)'));
    await tester.pumpAndSettle();

    // 失败原因直接可见（不再只藏 hover Tooltip）。
    expect(find.text('video import failed: boom'), findsOneWidget);

    // 点重试 → 重推 magnet + 计划复位 downloading。
    // 注意：复位后任务行变下载中，出现**不定进度**转圈（无轮询服务=进度未知），
    // 动画永不停 → pumpAndSettle 会超时，这里用有界 pump。
    await tester.tap(find.byTooltip(t.anime_download_retry));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(appModel.backend.addCalls, 1);
    expect(
      appModel.store.plans[_kHash]?.status,
      AnimeDownloadPlan.statusDownloading,
    );
  });
}
