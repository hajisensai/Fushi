// 媒体服务器「标记未看」端到端（BUG-5201）：真 Jellyfin（一次性测试服务器）。
//
// 用户报：标记未看后刷新，卡片仍显示已看，过一会儿才消失。本用例：
//   1. 经 API 先把第一集标成已看（服务器侧前置状态）；
//   2. 视频页 → 媒体服务器 → 服务器 → 库网格 → 剧详情；
//   3. 经集卡菜单（与右键同一回调）选「标记未看」（焦点 + Enter）；
//   4. 集卡与服务器都变未看；退回网格，剧卡必须立即显示 3 集未看。
//
// 只在人工点名时跑，需要一台可随便改状态的 Jellyfin（一个剧集库、一部 3 集的剧），
// 例如 `docker run -d -p 8097:8096 -v <media>:/media:ro jellyfin/jellyfin` 后过
// 一遍初始化向导、建 tvshows 库。地址 / 账号经 --dart-define 覆盖：
// FUSHI_JF_URL / FUSHI_JF_USER / FUSHI_JF_PASS（缺省是本机 8097 上的测试账号）。

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/detail/media_poster_detail.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _serverUrl = String.fromEnvironment(
  'FUSHI_JF_URL',
  defaultValue: 'http://localhost:8097',
);
const String _username = String.fromEnvironment(
  'FUSHI_JF_USER',
  defaultValue: 'tester',
);
const String _password = String.fromEnvironment(
  'FUSHI_JF_PASS',
  defaultValue: 'testpass',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('媒体服务器详情页：标记未看后集卡立即更新', (WidgetTester tester) async {
    expect(_serverUrl.isNotEmpty && _username.isNotEmpty, isTrue);
    await runFushiItest(
      label: 'media-server-mark-unwatched',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue);
        final AppModel appModel = await enableFocusNavigation(tester);
        final FocusDriver driver = FocusDriver(tester);

        final String url = JellyfinApi.normalizeServerUrl(_serverUrl);
        final JellyfinAuthResult auth = await JellyfinApi(
          serverUrl: url,
        ).authenticateByName(_username, _password);
        final JellyfinApi api = JellyfinApi(
          serverUrl: url,
          accessToken: auth.accessToken,
        );
        await SyncRepository(appModel.database).upsertJellyfinServer(
          JellyfinServerConfig(
            serverUrl: url,
            username: _username,
            userId: auth.userId,
            accessToken: auth.accessToken,
            serverName: auth.serverName,
          ),
        );

        // 前置：第一集在服务器上标已看。
        final JellyfinRecursiveResult all = await api.recursiveVideoItems(
          userId: auth.userId,
          parentId: null,
        );
        final List<JellyfinItem> eps =
            all.items.where((JellyfinItem i) => i.type == 'Episode').toList()
              ..sort(
                (JellyfinItem a, JellyfinItem b) => a.name.compareTo(b.name),
              );
        expect(eps, isNotEmpty);
        final String firstId = eps.first.id;
        await api.setPlayed(userId: auth.userId, itemId: firstId, played: true);
        debugPrint('[jf-unwatched] pre: marked $firstId played on server');

        // 视频页 → 媒体服务器分区。
        HomePage.debugSelectTab!(HomeTab.video);
        Finder nav(String prefix) => find.byWidgetPredicate(
          (Widget w) =>
              w is FushiAdjustableSegmented<VideoLibrarySection> &&
              w.focusIdPrefix == prefix,
        );
        expect(
          await _waitFor(
            tester,
            () => nav('video-library-subview').evaluate().isNotEmpty,
          ),
          isTrue,
        );
        for (int i = 0; i < 6; i++) {
          final Finder sub = nav('video-library-subview');
          if (tester
                  .widget<FushiAdjustableSegmented<VideoLibrarySection>>(sub)
                  .selected ==
              VideoLibrarySection.mediaServers) {
            break;
          }
          await driver.requestFocusInside(
            sub,
            debugLabelContains: 'video-library-subview-sections',
          );
          await driver.adjust(steps: 1);
          await tester.pump(const Duration(milliseconds: 500));
        }

        // 服务器列表 → 进这台服务器（焦点 + Enter）。
        final Finder serverCard = _keyPrefix('media-server-card-');
        expect(
          await _waitFor(
            tester,
            () => serverCard.evaluate().isNotEmpty,
            maxTicks: 120,
          ),
          isTrue,
          reason: '服务器列表应列出测试服务器',
        );
        final Finder sc = find.byWidget(serverCard.evaluate().first.widget);
        expect(
          await driver.requestFocusInside(sc) || await driver.focusWidget(sc),
          isTrue,
        );
        await driver.activate();

        final Finder libraryCards = _keyPrefix('media-server-library-');
        final bool libsShown = await _waitFor(
          tester,
          () => libraryCards.evaluate().isNotEmpty,
          maxTicks: 240,
        );
        await captureFlutterFrame(tester, 'ju-00-section');
        expect(libsShown, isTrue, reason: '服务器首页应列出媒体库');
        final Finder lib = find.byWidget(libraryCards.evaluate().first.widget);
        expect(
          await driver.requestFocusInside(lib) || await driver.focusWidget(lib),
          isTrue,
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
        );
        await tester.pump(const Duration(seconds: 2));
        debugPrint('[jf-unwatched] grid before: ${_texts(gridCards.first)}');
        await captureFlutterFrame(tester, 'ju-01-grid-before');

        final Finder card = find.byWidget(gridCards.evaluate().first.widget);
        expect(
          await driver.requestFocusInside(card) ||
              await driver.focusWidget(card),
          isTrue,
        );
        await driver.activate();
        final Finder epKey = find.byKey(
          ValueKey<String>('media-server-episode-$firstId'),
        );
        expect(
          await _waitFor(
            tester,
            () => epKey.evaluate().isNotEmpty,
            maxTicks: 240,
          ),
          isTrue,
          reason: '详情页应列出第一集',
        );
        await tester.pump(const Duration(seconds: 2));
        _logEpisodes('detail-before');
        await captureFlutterFrame(tester, 'ju-02-detail-before');

        // 打开集卡菜单（与右键同一回调），焦点到「标记未看」，Enter。
        final ContextMenuTrigger trigger = tester.widget<ContextMenuTrigger>(
          find.descendant(of: epKey, matching: find.byType(ContextMenuTrigger)),
        );
        trigger.onInvoke!(Offset.zero);
        final Finder toggle = find.byKey(
          const ValueKey<String>('media-server-episode-mark-toggle'),
        );
        expect(
          await _waitFor(tester, () => toggle.evaluate().isNotEmpty),
          isTrue,
        );
        await tester.pump(const Duration(milliseconds: 600));
        debugPrint('[jf-unwatched] menu label: ${_texts(toggle)}');
        await captureFlutterFrame(tester, 'ju-03-menu');
        expect(
          await driver.requestFocusInside(toggle) ||
              await driver.focusWidget(toggle),
          isTrue,
        );
        await driver.activate();

        final Stopwatch sw = Stopwatch()..start();
        await tester.pump(const Duration(milliseconds: 300));
        _logEpisodes('after-0.3s');
        for (final int s in <int>[2, 10]) {
          await tester.pump(Duration(seconds: s == 2 ? 2 : 8));
          _logEpisodes('after-${sw.elapsed.inSeconds}s');
          await captureFlutterFrame(
            tester,
            'ju-04-detail-${sw.elapsed.inSeconds}s',
          );
        }
        final JellyfinItem server = await api.itemDetail(
          userId: auth.userId,
          itemId: firstId,
        );
        debugPrint('[jf-unwatched] server now: played=${server.played}');

        // 返回网格。
        await driver.back();
        await _waitFor(
          tester,
          () => gridCards.evaluate().isNotEmpty,
          maxTicks: 60,
        );
        await tester.pump(const Duration(seconds: 2));
        debugPrint(
          '[jf-unwatched] grid after back: ${_texts(gridCards.first)}',
        );
        await captureFlutterFrame(tester, 'ju-05-grid-after');
        // 剧卡角标必须跟上：3 集全未看（修复前一直停在「2 unwatched」直到整页重建）。
        expect(
          _texts(gridCards.first).any((String s) => s.startsWith('3 ')),
          isTrue,
          reason: '退回网格后剧卡应显示 3 集未看：${_texts(gridCards.first)}',
        );
      },
    );
  });
}

void _logEpisodes(String tag) {
  for (final Element e in _keyPrefix('media-server-episode-').evaluate()) {
    final String key = (e.widget.key! as ValueKey<String>).value;
    if (key.contains('mark')) continue;
    final Iterable<Widget> tiles = find
        .descendant(
          of: find.byWidget(e.widget),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is MediaPosterEpisodeTile || w is CollectionEpisodeCard,
          ),
        )
        .evaluate()
        .map((Element x) => x.widget);
    for (final Widget w in tiles) {
      if (w is MediaPosterEpisodeTile) {
        debugPrint(
          '[jf-unwatched] $tag $key completed=${w.completed} pos=${w.positionMs} progress=${w.progress}',
        );
      } else if (w is CollectionEpisodeCard) {
        debugPrint(
          '[jf-unwatched] $tag $key completed=${w.completed} pos=${w.positionMs} progress=${w.progress}',
        );
      }
    }
  }
}

List<String> _texts(Finder root) => find
    .descendant(of: root, matching: find.byType(Text))
    .evaluate()
    .map((Element e) => (e.widget as Text).data ?? '')
    .where((String s) => s.isNotEmpty)
    .toList();

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
