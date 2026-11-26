import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/leaderboard/leaderboard_deep_link.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_tab.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_user_page.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_work_page.dart';
import 'package:fushi/src/platform/source_url_channel.dart';

/// BUG-5549：排行榜分享页「在 Fushi 中打开」（`fushi://leaderboard/user|work/<id>`）
/// 在 App 一侧没有接收端——Android 清单没注册 host、handleIncomingUrl 没有分支。
void main() {
  group('LeaderboardDeepLink.tryParse', () {
    test('user and work links from the share page', () {
      expect(
        LeaderboardDeepLink.tryParse(
          'fushi://leaderboard/user/wBtFO05mSuEKt1Iq',
        ),
        const LeaderboardUserLink('wBtFO05mSuEKt1Iq'),
      );
      expect(
        LeaderboardDeepLink.tryParse('fushi://leaderboard/work/ab_c-9'),
        const LeaderboardWorkLink('ab_c-9'),
      );
    });

    test('tolerates case in scheme / host / kind, whitespace, trailing slash '
        'and a query', () {
      expect(
        LeaderboardDeepLink.tryParse(' FUSHI://Leaderboard/User/abc/ '),
        const LeaderboardUserLink('abc'),
      );
      expect(
        LeaderboardDeepLink.tryParse('fushi://leaderboard/work/abc?x=1'),
        const LeaderboardWorkLink('abc'),
      );
      expect(
        LeaderboardDeepLink.fromUri(Uri.parse('fushi://leaderboard/user/a')),
        const LeaderboardUserLink('a'),
      );
    });

    test('rejects other hosts, schemes, shapes and ids outside PAGE_ID', () {
      for (final String? url in <String?>[
        null,
        '',
        'https://rank.fushi.moe/u/abc',
        'fushi://pair/user/abc',
        'other://leaderboard/user/abc',
        'fushi://leaderboard',
        'fushi://leaderboard/user',
        'fushi://leaderboard/user/',
        'fushi://leaderboard/rank/abc',
        'fushi://leaderboard/user/abc/extra',
        'fushi://leaderboard/user/a%20b',
        'fushi://leaderboard/user/${'x' * 33}',
      ]) {
        expect(LeaderboardDeepLink.tryParse(url), isNull, reason: '$url');
      }
    });
  });

  group('platform registration guards', () {
    final String pagesJs = File(
      '../services/leaderboard/src/pages.js',
    ).readAsStringSync();

    test('every fushi://leaderboard link the share pages emit parses', () {
      final Iterable<RegExpMatch> links = RegExp(
        r'fushi://leaderboard/([a-z]+)/\$\{',
      ).allMatches(pagesJs);
      expect(links, isNotEmpty);
      for (final RegExpMatch m in links) {
        expect(
          LeaderboardDeepLink.tryParse('fushi://leaderboard/${m.group(1)}/id1'),
          isNotNull,
          reason: m.group(0),
        );
      }
    });

    test('every fushi:// host the share pages emit is registered in the '
        'Android manifest and routed on macOS', () {
      final Set<String> hosts = RegExp(
        r'fushi://([a-z]+)',
      ).allMatches(pagesJs).map((RegExpMatch m) => m.group(1)!).toSet();
      expect(hosts, contains('leaderboard'));
      final String manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      for (final String host in hosts) {
        expect(
          manifest,
          contains('<data android:scheme="fushi" android:host="$host" />'),
          reason: 'Android has no VIEW intent-filter for fushi://$host',
        );
        expect(
          SourceUrlChannel.isRoutedUrl('fushi://$host/user/x'),
          isTrue,
          reason: 'macOS does not hand fushi://$host to Dart',
        );
      }
    });

    test('main.dart routes the link from every desktop / mobile entry', () {
      final String main = File('lib/main.dart').readAsStringSync();
      // argv 冷启动 + handleIncomingUrl（Android / iOS / macOS）+ 单实例转交（Win / Linux）。
      expect(
        'LeaderboardDeepLink.tryParse('.allMatches(main).length,
        3,
        reason: 'argv, handleIncomingUrl and _handleExternalVideoChannel',
      );
      expect(main, contains('_leaderboardLinks.schedule();'));
      expect(main, contains('openLeaderboardDeepLink('));
    });
  });

  group('openLeaderboardDeepLink', () {
    late GlobalKey<NavigatorState> navigatorKey;
    late _RecordingObserver observer;

    Future<void> pumpHome(WidgetTester tester) {
      navigatorKey = GlobalKey<NavigatorState>();
      observer = _RecordingObserver();
      return tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: <NavigatorObserver>[observer],
          home: const Scaffold(body: Text('home')),
        ),
      );
    }

    /// 推上去的页面（不 build：页面依赖排行榜服务，这里只验路由落到哪个页面、带哪个 id）。
    Widget pushedPage() {
      expect(observer.pushed, hasLength(1));
      final MaterialPageRoute<void> route =
          observer.pushed.single as MaterialPageRoute<void>;
      return route.builder(navigatorKey.currentContext!);
    }

    testWidgets('active account: user link opens LeaderboardUserPage', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      observer.pushed.clear();
      await openLeaderboardDeepLink(
        const LeaderboardUserLink('u1'),
        navigator: navigatorKey.currentState,
        isLeaderboardActive: () async => true,
      );
      final Widget page = pushedPage();
      expect(page, isA<LeaderboardUserPage>());
      expect((page as LeaderboardUserPage).accountId, 'u1');
    });

    testWidgets('active account: work link opens LeaderboardWorkPage', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      observer.pushed.clear();
      await openLeaderboardDeepLink(
        const LeaderboardWorkLink('w1'),
        navigator: navigatorKey.currentState,
        isLeaderboardActive: () async => true,
      );
      final Widget page = pushedPage();
      expect(page, isA<LeaderboardWorkPage>());
      expect((page as LeaderboardWorkPage).workId, 'w1');
    });

    testWidgets('not enabled or account read failed: opens the leaderboard '
        'home (enable / retry) instead of an empty user page', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      observer.pushed.clear();
      await openLeaderboardDeepLink(
        const LeaderboardUserLink('u1'),
        navigator: navigatorKey.currentState,
        isLeaderboardActive: () async => false,
      );
      expect(pushedPage(), isA<LeaderboardPage>());

      observer.pushed.clear();
      await openLeaderboardDeepLink(
        const LeaderboardWorkLink('w1'),
        navigator: navigatorKey.currentState,
        isLeaderboardActive: () async => throw StateError('no data root'),
      );
      expect(pushedPage(), isA<LeaderboardPage>());
    });

    testWidgets('no navigator yet: nothing happens', (
      WidgetTester tester,
    ) async {
      bool asked = false;
      await openLeaderboardDeepLink(
        const LeaderboardUserLink('u1'),
        navigator: null,
        isLeaderboardActive: () async => asked = true,
      );
      expect(asked, isFalse);
    });
  });

  group('LeaderboardDeepLinkQueue (cold start)', () {
    testWidgets('holds the link until ready, then runs the last one once on '
        'the next frame', (WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      final List<LeaderboardDeepLink> ran = <LeaderboardDeepLink>[];
      final LeaderboardDeepLinkQueue queue = LeaderboardDeepLinkQueue(
        isActive: () => true,
        run: (LeaderboardDeepLink l) async => ran.add(l),
      );
      queue.enqueue(const LeaderboardUserLink('a'), ready: false);
      queue.enqueue(const LeaderboardWorkLink('b'), ready: false);
      await tester.pump();
      expect(ran, isEmpty);
      expect(queue.pending, const LeaderboardWorkLink('b'));

      queue.schedule();
      queue.schedule();
      await tester.pump();
      expect(ran, <LeaderboardDeepLink>[const LeaderboardWorkLink('b')]);
      expect(queue.pending, isNull);

      queue.enqueue(const LeaderboardUserLink('c'), ready: true);
      await tester.pump();
      expect(ran.last, const LeaderboardUserLink('c'));
      expect(ran, hasLength(2));
    });

    testWidgets('drops the link when the host is gone by the frame', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final List<LeaderboardDeepLink> ran = <LeaderboardDeepLink>[];
      final LeaderboardDeepLinkQueue queue = LeaderboardDeepLinkQueue(
        isActive: () => false,
        run: (LeaderboardDeepLink l) async => ran.add(l),
      );
      queue.enqueue(const LeaderboardUserLink('a'), ready: true);
      await tester.pump();
      expect(ran, isEmpty);
    });
  });
}

class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}
