// 「媒体服务器」分区对真 Jellyfin/Emby 服务器的端到端取证：
// 登录 → 视频页切到「媒体服务器」分区 → 服务器首页 → 进库网格 → 进剧详情 → 点集播放。
//
// 需要真实凭据，经 --dart-define 注入（runner 用 -DartDefine 转发）：
//   FUSHI_EMBY_URL / FUSHI_EMBY_USER / FUSHI_EMBY_PASS
// 缺任一项直接失败（不是 skip：本文件只在人工点名时跑，跑了就要给出结论）。
//
// 全程焦点驱动（Tab / 方向键 / Enter），不做坐标点击。证据是 observe-*.png。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _serverUrl = String.fromEnvironment('FUSHI_EMBY_URL');
const String _username = String.fromEnvironment('FUSHI_EMBY_USER');
const String _password = String.fromEnvironment('FUSHI_EMBY_PASS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('媒体服务器分区对真 Emby：登录→首页→库网格→剧详情→播放', (WidgetTester tester) async {
    expect(
      _serverUrl.isNotEmpty && _username.isNotEmpty && _password.isNotEmpty,
      isTrue,
      reason:
          '需要 --dart-define FUSHI_EMBY_URL / FUSHI_EMBY_USER / FUSHI_EMBY_PASS',
    );
    await runFushiItest(
      label: 'media-server-emby-live',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        final AppModel appModel = await enableFocusNavigation(tester);
        final FocusDriver driver = FocusDriver(tester);

        // ── 登录并落配置（走产品同一条 authenticateByName + upsert 路径）──
        final String url = JellyfinApi.normalizeServerUrl(_serverUrl);
        final JellyfinApi api = JellyfinApi(serverUrl: url);
        final JellyfinAuthResult auth = await api.authenticateByName(
          _username,
          _password,
        );
        debugPrint(
          '[ms-live] signed in: server=${auth.serverName} userId=${auth.userId}',
        );
        final SyncRepository syncRepo = SyncRepository(appModel.database);
        await syncRepo.upsertJellyfinServer(
          JellyfinServerConfig(
            serverUrl: url,
            username: _username,
            userId: auth.userId,
            accessToken: auth.accessToken,
            serverName: auth.serverName,
          ),
        );
        expect((await syncRepo.getJellyfinServers()).length, 1);

        // ── 视频页 → 「媒体服务器」分区 ──
        expect(HomePage.debugSelectTab, isNotNull);
        HomePage.debugSelectTab!(HomeTab.video);
        final Finder navigation = find.byType(
          FushiAdjustableSegmented<VideoLibrarySection>,
        );
        expect(
          await _waitFor(tester, () => navigation.evaluate().isNotEmpty),
          isTrue,
          reason: '视频库分区导航应出现',
        );
        for (final VideoLibrarySection section in const <VideoLibrarySection>[
          VideoLibrarySection.series,
          VideoLibrarySection.allVideos,
          VideoLibrarySection.mediaServers,
        ]) {
          expect(
            await driver.requestFocusInside(
              navigation,
              debugLabelContains: 'video-library-view-sections',
            ),
            isTrue,
          );
          await driver.adjust(steps: 1);
          expect(
            await _waitFor(
              tester,
              () =>
                  tester
                      .widget<FushiAdjustableSegmented<VideoLibrarySection>>(
                        navigation,
                      )
                      .selected ==
                  section,
            ),
            isTrue,
            reason: '分区导航应切到 $section',
          );
        }

        // 单台服务器 → 首帧后自动进首页；等媒体库行出现（真网络，给足时间）。
        final Finder libraryCards = _keyPrefix('media-server-library-');
        expect(
          await _waitFor(
            tester,
            () => libraryCards.evaluate().isNotEmpty,
            maxTicks: 240,
          ),
          isTrue,
          reason: '服务器首页应列出媒体库（60s 内）',
        );
        await tester.pump(const Duration(seconds: 4)); // 封面与装饰行加载
        final ObserveShot home = await captureFlutterFrame(
          tester,
          'ms-01-home',
        );
        expect(home.saved && home.nonBlank, isTrue);
        debugPrint(
          '[ms-live] libraries on screen: ${libraryCards.evaluate().length}; '
          'rows: ${_keyPrefix('media-server-home-row-').evaluate().length}',
        );

        // ── 进第一个剧集库的网格（挑 key 含 tvshows 语义做不到，取第 2 张：探针里第 2 个库是剧集库）──
        final List<Element> libs = libraryCards.evaluate().toList();
        final Element targetLib = libs.length > 1 ? libs[1] : libs.first;
        final Finder targetLibFinder = find.byWidget(targetLib.widget);
        expect(
          await driver.requestFocusInside(targetLibFinder) ||
              await driver.focusWidget(targetLibFinder),
          isTrue,
          reason: '媒体库卡应可获焦',
        );
        await driver.activate();
        final Finder gridCards = _keyPrefix('media-server-grid-card-');
        expect(
          await _waitFor(
            tester,
            () => gridCards.evaluate().isNotEmpty,
            maxTicks: 240,
          ),
          isTrue,
          reason: '库网格应加载出第一页',
        );
        await tester.pump(const Duration(seconds: 4));
        final ObserveShot grid = await captureFlutterFrame(
          tester,
          'ms-02-grid',
        );
        expect(grid.saved && grid.nonBlank, isTrue);
        debugPrint(
          '[ms-live] grid cards built: ${gridCards.evaluate().length}',
        );

        // ── 翻页：End 键滚到底触发追加 ──
        final int before = gridCards.evaluate().length;
        final Element firstCard = gridCards.evaluate().first;
        expect(
          await driver.requestFocusInside(find.byWidget(firstCard.widget)) ||
              await driver.focusWidget(find.byWidget(firstCard.widget)),
          isTrue,
        );
        for (int i = 0; i < 12; i++) {
          await driver.adjust(steps: 1, up: LogicalKeyboardKey.arrowDown);
        }
        await tester.pump(const Duration(seconds: 6));
        debugPrint(
          '[ms-live] grid cards after scrolling: '
          '$before -> ${gridCards.evaluate().length}',
        );
        final ObserveShot grid2 = await captureFlutterFrame(
          tester,
          'ms-03-grid-scrolled',
        );
        expect(grid2.saved, isTrue);

        // ── 进当前聚焦的卡（剧）→ 详情 ──
        await driver.activate();
        final Finder episodes = _keyPrefix('media-server-episode-');
        final Finder playButton = find.byKey(
          const ValueKey<String>('media-server-detail-play'),
        );
        expect(
          await _waitFor(
            tester,
            () => playButton.evaluate().isNotEmpty,
            maxTicks: 240,
          ),
          isTrue,
          reason: '详情页应出现播放按钮',
        );
        await _waitFor(
          tester,
          () => episodes.evaluate().isNotEmpty,
          maxTicks: 120,
        );
        await tester.pump(const Duration(seconds: 3));
        final ObserveShot detail = await captureFlutterFrame(
          tester,
          'ms-04-detail',
        );
        expect(detail.saved && detail.nonBlank, isTrue);
        debugPrint(
          '[ms-live] episodes listed: ${episodes.evaluate().length}; '
          'seasons: ${_keyPrefix('media-server-season-').evaluate().length}',
        );

        // ── 播放：优先点第一集，没有集（电影）就点播放按钮 ──
        if (episodes.evaluate().isNotEmpty) {
          final Element ep = episodes.evaluate().first;
          expect(
            await driver.requestFocusInside(find.byWidget(ep.widget)) ||
                await driver.focusWidget(find.byWidget(ep.widget)),
            isTrue,
            reason: '集行应可获焦',
          );
        } else {
          expect(await driver.focusWidget(playButton), isTrue);
        }
        await driver.activate();
        expect(
          await _waitFor(
            tester,
            () => find.byType(VideoFushiPage).evaluate().isNotEmpty,
            maxTicks: 120,
          ),
          isTrue,
          reason: '应打开播放页',
        );
        // 真网络起播：等 20s 抓两帧（首帧 + 稳定帧）。
        await tester.pump(const Duration(seconds: 8));
        final ObserveShot play1 = await captureFlutterFrame(
          tester,
          'ms-05-play-8s',
        );
        expect(play1.saved, isTrue);
        await tester.pump(const Duration(seconds: 12));
        final ObserveShot play2 = await captureFlutterFrame(
          tester,
          'ms-06-play-20s',
        );
        expect(play2.saved, isTrue);
        final Iterable<String> texts = find
            .byType(Text)
            .evaluate()
            .map((Element e) => (e.widget as Text).data ?? '')
            .where((String s) => s.isNotEmpty);
        debugPrint('[ms-live] player texts: ${texts.take(40).toList()}');

        // ── 返回：Escape 关播放页，再退到网格 ──
        await driver.back();
        expect(
          await _waitFor(
            tester,
            () => find.byType(VideoFushiPage).evaluate().isEmpty,
            maxTicks: 60,
          ),
          isTrue,
          reason: '返回应关闭播放页',
        );
        await tester.pump(const Duration(seconds: 2));
        final ObserveShot back = await captureFlutterFrame(
          tester,
          'ms-07-back-detail',
        );
        expect(back.saved, isTrue);
        await driver.back();
        expect(
          await _waitFor(
            tester,
            () => gridCards.evaluate().isNotEmpty,
            maxTicks: 60,
          ),
          isTrue,
          reason: '再返回应回到库网格（分区内嵌套栈）',
        );
        final ObserveShot back2 = await captureFlutterFrame(
          tester,
          'ms-08-back-grid',
        );
        expect(back2.saved, isTrue);
      },
    );
  });
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
