// 「加入 / 移出媒体库」对真 Jellyfin 服务器的端到端取证（feat/media-server-library-remove）：
//
//   1. 服务器详情页（剧）：「+」加入 → 按钮翻成「−」+「已在库」chip；
//   2. 库首页：剧名合集卡出现；右键菜单有「移出媒体库」→ 执行 → 卡与入库行消失；
//   3. 电影：详情页加入 → 库首页电影卡右键「移出媒体库」→ 消失；
//   4. 库内合集详情页的「−」按钮 → 移出并退出详情页；
//   5. 详情页开着时从别处移出 → 本页自己翻回「+」（不重开）。
//
// 只读服务器、不写服务器：加入媒体库只落本机库（runner 隔离的干净库）。
//
// 凭据经 --dart-define 注入（runner 用 -DartDefine 转发）：
//   FUSHI_JELLYFIN_URL / FUSHI_JELLYFIN_USER / FUSHI_JELLYFIN_PASS
// 可选：FUSHI_JELLYFIN_SERIES / FUSHI_JELLYFIN_MOVIE（搜索词，指定用哪部；缺省自动
// 挑集数最少的剧和第一部电影）。缺凭据直接失败（本文件只在人工点名时跑）。
//
// 打开详情页：直接以与 home_page 同形的 [MediaServerSession] 推真 [MediaServerDetailView]
// （服务器网格按位置找卡太脆）。库首页的右键菜单：调卡片自己的 onSecondaryTap（真右键
// 走的就是它；项目规矩禁坐标点击），菜单内一律焦点 + Enter。证据是 observe-*.png。

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/media_server/media_server_library.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_detail_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _serverUrl = String.fromEnvironment('FUSHI_JELLYFIN_URL');
const String _username = String.fromEnvironment('FUSHI_JELLYFIN_USER');
const String _password = String.fromEnvironment('FUSHI_JELLYFIN_PASS');
const String _seriesQuery = String.fromEnvironment('FUSHI_JELLYFIN_SERIES');
const String _movieQuery = String.fromEnvironment('FUSHI_JELLYFIN_MOVIE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('媒体服务器作品加入 / 移出媒体库：详情页 ± 、库首页右键、合集详情页 −、'
      '跨页状态同步', (WidgetTester tester) async {
    expect(
      _serverUrl.isNotEmpty && _username.isNotEmpty,
      isTrue,
      reason: '需要 --dart-define FUSHI_JELLYFIN_URL / FUSHI_JELLYFIN_USER',
    );
    await runFushiItest(
      label: 'media-server-library-remove',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        final AppModel appModel = await enableFocusNavigation(tester);
        final FocusDriver driver = FocusDriver(tester);
        final FushiDatabase db = appModel.database;

        // ── 登录并落配置（产品同一条 authenticateByName + upsert 路径）──
        final String url = JellyfinApi.normalizeServerUrl(_serverUrl);
        final JellyfinAuthResult auth = await JellyfinApi(
          serverUrl: url,
        ).authenticateByName(_username, _password);
        final SyncRepository syncRepo = SyncRepository(db);
        await syncRepo.upsertJellyfinServer(
          JellyfinServerConfig(
            serverUrl: url,
            username: _username,
            userId: auth.userId,
            accessToken: auth.accessToken,
            serverName: auth.serverName,
          ),
        );
        final List<MediaServerConfig> configs = await syncRepo
            .getMediaServers();
        expect(configs, hasLength(1));
        final MediaServerBrowser browser = configs.single.buildBrowser();
        final MediaServerVideoLibrary library = MediaServerVideoLibrary(
          database: db,
        );
        final MediaServerSession session = MediaServerSession(
          browser: browser,
          play: (BuildContext _, MediaServerPlayRequest _) {},
          library: library,
        );
        debugPrint('[ms-lib] signed in: ${auth.serverName}');

        final ({MediaServerItem? series, MediaServerItem? movie}) targets =
            await _pickTargets(browser);
        final MediaServerItem series = targets.series!;
        debugPrint(
          '[ms-lib] series="${series.name}" (${series.id}, '
          'episodes=${series.episodeCount}); '
          'movie="${targets.movie?.name}"',
        );

        HomePage.debugSelectTab!(HomeTab.video);
        await tester.pump(const Duration(seconds: 2));
        final NavigatorState rootNav = Navigator.of(
          tester.element(find.byType(HomePage)),
          rootNavigator: true,
        );

        Finder addButton() => find.byKey(
          const ValueKey<String>('media-server-detail-library-add'),
        );
        Finder removeButton() => find.byKey(
          const ValueKey<String>('media-server-detail-library-remove'),
        );

        Future<void> openDetail(MediaServerItem item) async {
          unawaited(
            rootNav.push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    MediaServerDetailView(session: session, item: item),
              ),
            ),
          );
          expect(
            await _waitFor(
              tester,
              () =>
                  addButton().evaluate().isNotEmpty ||
                  removeButton().evaluate().isNotEmpty,
              maxTicks: 240,
            ),
            isTrue,
            reason: '详情页应出现加入 / 移出按钮',
          );
          // 剧的「加入」在集清单回来前禁用：等集卡出来。
          await _waitFor(
            tester,
            () => _keyPrefix('media-server-episode-').evaluate().isNotEmpty,
            maxTicks: 120,
          );
          await tester.pump(const Duration(seconds: 2));
        }

        Future<void> pressAdd() async {
          expect(await driver.focusWidget(addButton()), isTrue);
          await driver.activate();
          expect(
            await _waitFor(
              tester,
              () =>
                  removeButton().evaluate().isNotEmpty &&
                  addButton().evaluate().isEmpty,
              maxTicks: 480,
            ),
            isTrue,
            reason: '加入后按钮应翻成「−」',
          );
          await tester.pump(const Duration(seconds: 1));
        }

        Future<void> closeDetail() async {
          rootNav.pop();
          await tester.pump(const Duration(seconds: 2));
        }

        Future<List<VideoBookRow>> rowsOf(MediaServerItem work) async =>
            <VideoBookRow>[
              for (final VideoBookRow r in await db.allVideoBooks())
                if (mediaServerWorkOfRow(r)?.workId == work.id) r,
            ];

        // 卡片右键：调卡片自己的 onSecondaryTap（与真右键同一回调）。
        Future<void> rightClick(Finder card) async {
          final Finder fushiCard = find.descendant(
            of: card,
            matching: find.byType(FushiCard),
            matchRoot: true,
          );
          final FushiCard widget = tester.widget<FushiCard>(fushiCard.first);
          expect(widget.onSecondaryTap, isNotNull, reason: '卡片应接了右键菜单');
          widget.onSecondaryTap!();
          await tester.pump(const Duration(seconds: 2));
        }

        Future<void> chooseMenu(String label) async {
          final Finder entry = find.text(label);
          expect(
            await _waitFor(tester, () => entry.evaluate().isNotEmpty),
            isTrue,
            reason: '菜单里应有「$label」',
          );
          expect(await driver.focusWidget(entry.first), isTrue);
          await driver.activate();
          await tester.pump(const Duration(seconds: 2));
        }

        // ── 1. 剧：详情页「+」→「−」──
        await openDetail(series);
        expect(addButton(), findsOneWidget, reason: '干净库里应显示「+」');
        await captureFlutterFrame(tester, 'lib-01-series-detail-plus');
        await pressAdd();
        expect(find.text(t.video_discovery_in_library), findsOneWidget);
        await captureFlutterFrame(tester, 'lib-02-series-detail-minus');
        final int seriesRows = (await rowsOf(series)).length;
        expect(seriesRows, greaterThan(0));
        debugPrint('[ms-lib] series rows added: $seriesRows');

        // 重复加入：剧已全在库时「+」不再出现，库里行数不变。
        expect(addButton(), findsNothing);
        await closeDetail();

        // ── 2. 库首页：合集卡 → 右键「移出媒体库」──
        final MediaCollectionRow collection = (await db
            .getMediaCollectionByNaturalKey(series.name, 'playlist'))!;
        final Finder seriesCard = find.byKey(
          ValueKey<String>('home_video_recent_collection_${collection.id}'),
        );
        expect(
          await _waitFor(
            tester,
            () => seriesCard.evaluate().isNotEmpty,
            maxTicks: 120,
          ),
          isTrue,
          reason: '库首页「最近添加」应出现这部剧的合集卡',
        );
        await tester.pump(const Duration(seconds: 2));
        await captureFlutterFrame(tester, 'lib-03-home-series-card');
        await rightClick(seriesCard);
        await captureFlutterFrame(tester, 'lib-04-home-series-menu');
        await chooseMenu(t.video_online_library_remove);
        expect(
          await _waitFor(
            tester,
            () => seriesCard.evaluate().isEmpty,
            maxTicks: 120,
          ),
          isTrue,
          reason: '移出后合集卡应消失',
        );
        expect(await rowsOf(series), isEmpty);
        expect(await db.getMediaCollectionById(collection.id), isNull);
        await captureFlutterFrame(tester, 'lib-05-home-series-removed');

        // ── 3. 电影：详情页加入 → 库首页电影卡右键移出 ──
        final MediaServerItem? movie = targets.movie;
        if (movie == null) {
          debugPrint('[ms-lib] no movie on this server; movie path skipped');
        } else {
          await openDetail(movie);
          await pressAdd();
          await captureFlutterFrame(tester, 'lib-06-movie-detail-minus');
          await closeDetail();
          final String uid = (await rowsOf(movie)).single.bookUid;
          final Finder movieCard = find.byKey(
            ValueKey<String>('home_video_recent_$uid'),
          );
          expect(
            await _waitFor(
              tester,
              () => movieCard.evaluate().isNotEmpty,
              maxTicks: 120,
            ),
            isTrue,
            reason: '库首页应出现电影卡',
          );
          await rightClick(movieCard);
          expect(
            find.text(t.video_online_library_remove_series),
            findsNothing,
            reason: '电影卡用「移出媒体库」，不是「把整部剧移出」',
          );
          await captureFlutterFrame(tester, 'lib-07-home-movie-menu');
          await chooseMenu(t.video_online_library_remove);
          expect(
            await _waitFor(
              tester,
              () => movieCard.evaluate().isEmpty,
              maxTicks: 120,
            ),
            isTrue,
            reason: '移出后电影卡应消失',
          );
          expect(await rowsOf(movie), isEmpty);
          await captureFlutterFrame(tester, 'lib-08-home-movie-removed');
        }

        // ── 4. 库内合集详情页的「−」──
        await openDetail(series);
        await pressAdd();
        await closeDetail();
        final MediaCollectionRow collection2 = (await db
            .getMediaCollectionByNaturalKey(series.name, 'playlist'))!;
        final Finder seriesCard2 = find.byKey(
          ValueKey<String>('home_video_recent_collection_${collection2.id}'),
        );
        expect(
          await _waitFor(
            tester,
            () => seriesCard2.evaluate().isNotEmpty,
            maxTicks: 120,
          ),
          isTrue,
        );
        expect(
          await driver.requestFocusInside(seriesCard2) ||
              await driver.focusWidget(seriesCard2),
          isTrue,
          reason: '合集卡应可获焦',
        );
        await driver.activate();
        final Finder collectionRemove = find.byKey(
          const ValueKey<String>('collection-hero-library-remove'),
        );
        expect(
          await _waitFor(
            tester,
            () => collectionRemove.evaluate().isNotEmpty,
            maxTicks: 120,
          ),
          isTrue,
          reason: '库内合集详情页应有「−」移出按钮',
        );
        await tester.pump(const Duration(seconds: 2));
        await captureFlutterFrame(tester, 'lib-09-collection-detail-minus');
        expect(await driver.focusWidget(collectionRemove), isTrue);
        await driver.activate();
        expect(
          await _waitFor(
            tester,
            () => collectionRemove.evaluate().isEmpty,
            maxTicks: 120,
          ),
          isTrue,
          reason: '合集被删空后应退出详情页',
        );
        expect(await rowsOf(series), isEmpty);
        await tester.pump(const Duration(seconds: 2));
        await captureFlutterFrame(tester, 'lib-10-collection-removed');

        // ── 5. 详情页开着时从别处移出：本页自己翻回「+」──
        await openDetail(series);
        await pressAdd();
        final int removed = await library.removeWorks(<MediaServerLibraryWork>{
          (serverId: browser.serverId, workId: series.id),
        });
        expect(removed, seriesRows);
        expect(
          await _waitFor(
            tester,
            () =>
                addButton().evaluate().isNotEmpty &&
                removeButton().evaluate().isEmpty,
            maxTicks: 120,
          ),
          isTrue,
          reason: '别处移出后，开着的详情页应自己翻回「+」',
        );
        expect(find.text(t.video_discovery_in_library), findsNothing);
        await captureFlutterFrame(tester, 'lib-11-detail-synced-plus');
        await closeDetail();
      },
    );
  });
}

/// 挑测试用的剧（集数最少，加入最快）和电影；可用搜索词指定。
Future<({MediaServerItem? series, MediaServerItem? movie})> _pickTargets(
  MediaServerBrowser browser,
) async {
  MediaServerItem? series;
  MediaServerItem? movie;
  Future<MediaServerItem?> searchOne(
    String query,
    MediaServerItemType type,
  ) async {
    for (final MediaServerItem item in (await browser.search(query)).items) {
      if (item.type == type) return item;
    }
    return null;
  }

  if (_seriesQuery.isNotEmpty) {
    series = await searchOne(_seriesQuery, MediaServerItemType.series);
  }
  if (_movieQuery.isNotEmpty) {
    movie = await searchOne(_movieQuery, MediaServerItemType.movie);
  }
  // 服务器报 0 集（空壳剧）的不要：详情页没有集，「加入」按钮按设计禁用。
  int count(MediaServerItem item) {
    final int? n = item.episodeCount;
    return n == null || n <= 0 ? 1 << 30 : n;
  }

  final List<MediaServerItem> seriesCandidates = <MediaServerItem>[];
  if (series == null || movie == null) {
    for (final MediaServerLibrary lib in await browser.listLibraries()) {
      final MediaServerPage page = browser is MediaServerLibraryItems
          ? await (browser as MediaServerLibraryItems).listLibraryItems(
              library: lib,
              limit: 100,
            )
          : await browser.listChildren(parentId: lib.id, limit: 100);
      for (final MediaServerItem item in page.items) {
        if (_seriesQuery.isEmpty && item.type == MediaServerItemType.series) {
          seriesCandidates.add(item);
        }
        if (_movieQuery.isEmpty &&
            movie == null &&
            item.type == MediaServerItemType.movie) {
          movie = item;
        }
      }
    }
  }
  // 集数从少到多，取第一部真的列得出集的（报的集数可能不准）。
  seriesCandidates.sort(
    (MediaServerItem a, MediaServerItem b) => count(a).compareTo(count(b)),
  );
  for (final MediaServerItem candidate in seriesCandidates) {
    if (series != null) break;
    final MediaServerPage episodes = await browser.listEpisodes(
      seriesId: candidate.id,
      limit: 1,
    );
    if (episodes.items.any((MediaServerItem e) => e.isPlayable)) {
      series = candidate;
    }
  }
  expect(series, isNotNull, reason: '服务器上应至少有一部列得出集的剧');
  return (series: series, movie: movie);
}

Finder _keyPrefix(String prefix) => find.byWidgetPredicate(
  (Widget w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith(prefix),
);

Future<bool> _waitFor(
  WidgetTester tester,
  FutureOr<bool> Function() predicate, {
  int maxTicks = 80,
}) async {
  for (int i = 0; i < maxTicks; i++) {
    if (await predicate()) return true;
    await tester.pump(const Duration(milliseconds: 250));
  }
  return false;
}
