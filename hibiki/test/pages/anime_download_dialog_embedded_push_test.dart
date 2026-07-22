import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki/src/media/video/anilist_client.dart';
import 'package:hibiki/src/media/torrent/nyaa_client.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/anime_download_dialog.dart';

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
  Future<void> save(AnimeDownloadPlan plan) async {
    plans[plan.id] = plan;
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
}

class _FakeAppModel extends AppModel {
  _FakeAppModel() : super(testPlatformServices());

  final _MemPlanStore store = _MemPlanStore();
  final _FakeBackend backend = _FakeBackend();

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
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((ref) => appModel),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: Center(child: Text('base-route'))),
        ),
      ),
    ));
    return (appModel, navKey);
  }

  testWidgets('embedded 推送成功不 pop 宿主路由，复位搜番阶段并刷新任务区',
      (WidgetTester tester) async {
    final (_FakeAppModel appModel, GlobalKey<NavigatorState> navKey) =
        await pumpHost(tester);

    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (BuildContext context) => const Scaffold(
        body: AnimeDownloadDialog(
          embedded: true,
          debugInitialMedia: _kMedia,
          debugInitialTorrent: _kTorrent,
        ),
      ),
    ));
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
    expect(appModel.store.plans[_kHash]?.status,
        AnimeDownloadPlan.statusDownloading);
    expect(appModel.backend.addCalls, 1);
    expect(find.text('${t.anime_download_tasks} (1)'), findsOneWidget);
  });

  testWidgets('独立对话框模式推送成功仍关闭自身（向后兼容）', (WidgetTester tester) async {
    final (_FakeAppModel appModel, GlobalKey<NavigatorState> navKey) =
        await pumpHost(tester);

    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (BuildContext context) => const Scaffold(
        body: AnimeDownloadDialog(
          debugInitialMedia: _kMedia,
          debugInitialTorrent: _kTorrent,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text(t.anime_download_push), findsOneWidget);

    await tester.tap(find.text(t.anime_download_push));
    await tester.pumpAndSettle();

    // 对话框路由已关闭，回到宿主。
    expect(find.byType(AnimeDownloadDialog), findsNothing);
    expect(find.text('base-route'), findsOneWidget);
    expect(appModel.store.plans[_kHash]?.status,
        AnimeDownloadPlan.statusDownloading);
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

    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (BuildContext context) => const Scaffold(
        body: AnimeDownloadDialog(embedded: true),
      ),
    ));
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
    expect(appModel.store.plans[_kHash]?.status,
        AnimeDownloadPlan.statusDownloading);
  });
}
