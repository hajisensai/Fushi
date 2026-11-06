import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/play_in_fushi_feature.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/youtube_watch_page.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:material_ui/material_ui.dart';

String? _id(String url) => youtubeWatchVideoIdOf(Uri.parse(url));

void main() {
  group('youtubeWatchVideoIdOf', () {
    const String id = 'dQw4w9WgXcQ';

    test('认各种观看页写法', () {
      for (final String url in <String>[
        'https://www.youtube.com/watch?v=$id',
        'https://youtube.com/watch?v=$id&t=42s&list=PL123',
        'https://m.youtube.com/watch?v=$id&feature=share',
        'https://music.youtube.com/watch?v=$id&si=abc',
        'https://www.youtube.com/shorts/$id',
        'https://m.youtube.com/shorts/$id?feature=share',
        'https://www.youtube.com/live/$id',
        'https://www.youtube.com/embed/$id',
        'https://youtu.be/$id?t=10',
        'https://www.youtube-nocookie.com/embed/$id',
        'HTTPS://WWW.YOUTUBE.COM./watch?v=$id',
        'http://www.youtube.com/watch?v=$id',
      ]) {
        expect(_id(url), id, reason: url);
      }
    });

    test('非观看页 / 非 YouTube / 形状不对都返回 null', () {
      for (final String url in <String>[
        'https://www.youtube.com/',
        'https://www.youtube.com/results?search_query=cat',
        'https://www.youtube.com/@channel',
        'https://www.youtube.com/playlist?list=PL123',
        'https://www.youtube.com/feed/subscriptions',
        'https://www.youtube.com/watch',
        'https://www.youtube.com/watch?v=short',
        'https://www.youtube.com/watch?v=$id/extra',
        'https://notyoutube.com/watch?v=$id',
        'https://youtube.com.evil.example/watch?v=$id',
        'https://youtu.be/',
        'ftp://www.youtube.com/watch?v=$id',
        'about:blank',
      ]) {
        expect(_id(url), isNull, reason: url);
      }
      expect(youtubeWatchVideoIdOf(null), isNull);
    });

    test('规范化地址收敛同一视频', () {
      expect(
        youtubeCanonicalWatchUrl(_id('https://youtu.be/$id?t=3')!),
        'https://www.youtube.com/watch?v=$id',
      );
    });
  });

  group('PlayInFushiFeature.actions', () {
    PlayInFushiFeature feature() => PlayInFushiFeature(
      repository: () => throw StateError('not used'),
      youtubeTargetHeight: () => null,
      // 这组只测 YouTube 观看页；有播放页时其它网页的动作见
      // web_browser_site_player_test.dart。
      playerAvailable: () => false,
    );

    Future<List<WebBrowserAction>> actionsFor(
      WidgetTester tester,
      String url,
    ) async {
      late List<WebBrowserAction> out;
      await tester.pumpWidget(
        Builder(
          builder: (BuildContext context) {
            out = feature().actions(
              context,
              WebBrowserTab(id: 't', url: Uri.parse(url)),
            );
            return const SizedBox.shrink();
          },
        ),
      );
      return out;
    }

    testWidgets('观看页给一个工具栏动作，其它页不给', (WidgetTester tester) async {
      final List<WebBrowserAction> watch = await actionsFor(
        tester,
        'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
      );
      expect(watch, hasLength(1));
      expect(watch.single.placement, WebBrowserActionPlacement.toolbar);
      expect(watch.single.onPressed, isNotNull);

      expect(await actionsFor(tester, 'https://www.youtube.com/'), isEmpty);
      expect(await actionsFor(tester, 'https://example.com/'), isEmpty);
    });

    test('五端都装配（YouTube 流播放不属于商店受限能力）', () {
      expect(feature().available, isTrue);
    });
  });

  test('按住脚本：暂停在播的媒体并拦之后的 play；解除脚本摘掉同一个监听', () {
    expect(
      kWebBrowserHoldMediaScript,
      contains('querySelectorAll("video,audio")'),
    );
    expect(kWebBrowserHoldMediaScript, contains('.pause()'));
    // 捕获阶段拦 play：交接时 <video> 还没建 / 退回选集页后预告片自动播（BUG-3801）。
    expect(
      kWebBrowserHoldMediaScript,
      contains('addEventListener("play",window.__fushiMediaHold,true)'),
    );
    expect(
      kWebBrowserReleaseMediaScript,
      contains('removeEventListener("play",h,true)'),
    );
  });

  testWidgets('播放页（含 pushReplacement 换上来的制卡页）都关掉才算回到浏览器', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
    late BuildContext browserContext;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: Builder(
          builder: (BuildContext context) {
            browserContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    bool back = false;
    unawaited(
      nav.currentState!
          .push<void>(
            MaterialPageRoute<void>(builder: (_) => const Text('player')),
          )
          .then((_) {}),
    );
    await tester.pumpAndSettle();
    unawaited(untilRouteIsCurrent(browserContext).then((_) => back = true));
    // 播放页换成制卡页：浏览器仍被盖着。
    unawaited(
      nav.currentState!.pushReplacement<void, void>(
        MaterialPageRoute<void>(builder: (_) => const Text('mining')),
      ),
    );
    await tester.pumpAndSettle();
    expect(back, isFalse);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(back, isTrue);
  });
}
