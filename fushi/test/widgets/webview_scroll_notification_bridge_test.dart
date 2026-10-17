// BUG-3064：移动端查词页往下滑底部栏不收起。
//
// 查词结果正文在 WebView 里滚，Flutter 收不到 ScrollNotification，外壳那台
// 「底栏随下滑收起」状态机（FushiAppleScrollChrome，库页 ListView 也走它）从未
// 被喂到。修法：WebView 把文档滚动报上来，WebViewScrollNotificationBridge 按
// Flutter Scrollable 的形状派发通知。这里用真实的外壳状态机验证行为，再钉住
// 首页查词结果卡确实打开了转发。
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart';
import 'package:fushi/src/utils/misc/webview_scroll_notification_bridge.dart';

void main() {
  group('WebViewScrollNotificationBridge drives the shell bottom bar', () {
    late FushiAppleScrollChrome chrome;
    late List<Notification> seen;
    late BuildContext leaf;

    Future<void> pumpShell(WidgetTester tester) async {
      chrome = FushiAppleScrollChrome();
      addTearDown(chrome.dispose);
      seen = <Notification>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          // 与 home_page.dart `_withAppleScrollChrome` 同一接法。
          child: NotificationListener<Notification>(
            onNotification: (Notification n) {
              seen.add(n);
              if (!fushiNotificationFromVisibleSubtree(n)) return false;
              chrome.handleNotification(n);
              return false;
            },
            child: Builder(
              builder: (BuildContext context) {
                leaf = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
    }

    WebViewScrollSample sample(double px, {bool user = true}) =>
        WebViewScrollSample(
          pixels: px,
          maxScrollExtent: 3000,
          viewportDimension: 700,
          userDriven: user,
        );

    testWidgets('user scroll down minimizes, scroll up expands', (
      WidgetTester tester,
    ) async {
      await pumpShell(tester);
      final WebViewScrollNotificationBridge bridge =
          WebViewScrollNotificationBridge();
      for (double px = 0; px <= 200; px += 16) {
        bridge.dispatch(leaf, sample(px));
      }
      expect(chrome.minimized, isTrue);
      expect(bridge.direction, ScrollDirection.reverse);

      for (double px = 200; px >= 150; px -= 8) {
        bridge.dispatch(leaf, sample(px));
      }
      expect(chrome.minimized, isFalse);
      expect(bridge.direction, ScrollDirection.forward);
    });

    testWidgets('programmatic scroll (not user-driven) never minimizes', (
      WidgetTester tester,
    ) async {
      await pumpShell(tester);
      final WebViewScrollNotificationBridge bridge =
          WebViewScrollNotificationBridge();
      // 恢复滚动位 / 换词归零：JS 端未置用户标记。
      bridge.dispatch(leaf, sample(0, user: false));
      for (double px = 40; px <= 400; px += 40) {
        bridge.dispatch(leaf, sample(px, user: false));
      }
      expect(chrome.minimized, isFalse);
      expect(bridge.direction, ScrollDirection.idle);
    });

    testWidgets('returning to the top always expands', (
      WidgetTester tester,
    ) async {
      await pumpShell(tester);
      final WebViewScrollNotificationBridge bridge =
          WebViewScrollNotificationBridge();
      for (double px = 0; px <= 200; px += 16) {
        bridge.dispatch(leaf, sample(px));
      }
      expect(chrome.minimized, isTrue);
      // 新一次查词渲染把文档归零（程序滚动）。
      bridge.dispatch(leaf, sample(0, user: false));
      expect(chrome.minimized, isFalse);
    });

    testWidgets(
      'notifications have Scrollable shape (vertical, user dir once)',
      (WidgetTester tester) async {
        await pumpShell(tester);
        final WebViewScrollNotificationBridge bridge =
            WebViewScrollNotificationBridge();
        bridge.dispatch(leaf, sample(0));
        bridge.dispatch(leaf, sample(10));
        bridge.dispatch(leaf, sample(20));
        final List<UserScrollNotification> user = seen
            .whereType<UserScrollNotification>()
            .toList();
        final List<ScrollUpdateNotification> updates = seen
            .whereType<ScrollUpdateNotification>()
            .toList();
        expect(user, hasLength(1));
        expect(user.single.direction, ScrollDirection.reverse);
        expect(updates, hasLength(3));
        expect(updates.last.metrics.axis, Axis.vertical);
        expect(updates.last.metrics.pixels, 20);
        expect(updates.last.scrollDelta, 10);
        expect(updates.last.metrics.viewportDimension, 700);
      },
    );
  });

  group('WebViewScrollSample.fromJs', () {
    test('parses the JS payload', () {
      final WebViewScrollSample? s = WebViewScrollSample.fromJs(
        <String, Object?>{
          'pixels': 12,
          'max': 900.5,
          'viewport': 640,
          'user': true,
        },
      );
      expect(s, isNotNull);
      expect(s!.pixels, 12);
      expect(s.maxScrollExtent, 900.5);
      expect(s.viewportDimension, 640);
      expect(s.userDriven, isTrue);
    });

    test('rejects malformed payloads', () {
      expect(WebViewScrollSample.fromJs(null), isNull);
      expect(
        WebViewScrollSample.fromJs(<String, Object?>{'pixels': 1}),
        isNull,
      );
      expect(
        WebViewScrollSample.fromJs(<String, Object?>{
          'pixels': 1,
          'max': 1,
          'viewport': 0,
        }),
        isNull,
      );
      expect(
        WebViewScrollSample.fromJs(<String, Object?>{
          'pixels': double.nan,
          'max': 1,
          'viewport': 10,
        }),
        isNull,
      );
    });
  });

  group('wiring guard', () {
    final String webview = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();
    final String page = File(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ).readAsStringSync();

    test('home lookup result WebView forwards its scroll to the shell', () {
      final int webviewAt = page.indexOf('key: _resultWebViewKey,');
      expect(webviewAt, greaterThan(0));
      final int end = page.indexOf('nudgeSurfaceOnRender', webviewAt);
      expect(
        page.substring(webviewAt, end),
        contains('forwardScrollToHost: true'),
      );
    });

    test(
      'popup WebView registers the bridge handler and injects the script',
      () {
        expect(kWebViewHostScrollReportJs, contains("'popupHostScroll'"));
        expect(webview, contains("handlerName: 'popupHostScroll'"));
        expect(webview, contains('kWebViewHostScrollReportJs'));
        // 整页重渲染前清用户标记，程序滚动不算用户滚动。
        expect(webview, contains('kWebViewHostScrollDisarmJs'));
      },
    );
  });
}
