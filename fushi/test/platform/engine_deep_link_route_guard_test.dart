import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/engine_deep_link_route_guard.dart';

/// BUG-2459：引擎默认 deep linking 把 `fushi://ankiFetch` 推成
/// `pushRouteInformation`，`WidgetsApp` 对无 Router 的 `MaterialApp(home:)`
/// 直接 `pushNamed('/')`——在当前页面上面又压一份 home。这里走**真实的**
/// `flutter/navigation` 平台消息，让框架自己演一遍这条链：不挂守卫时多出一个
/// home（复现），挂上守卫后栈不动（修复）。
void main() {
  const JSONMethodCodec codec = JSONMethodCodec();

  Future<void> pushRouteInformation(WidgetTester tester, String location) {
    return tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      codec.encodeMethodCall(
        MethodCall('pushRouteInformation', <String, Object?>{
          'location': location,
          'state': null,
        }),
      ),
      (ByteData? _) {},
    );
  }

  Widget buildApp(GlobalKey<NavigatorState> navigatorKey) {
    return MaterialApp(navigatorKey: navigatorKey, home: const _Home());
  }

  testWidgets('复现：不挂守卫时引擎深链把 home 又压了一份在设置页上面', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(buildApp(navigatorKey));
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const _Settings()),
    );
    await tester.pumpAndSettle();
    expect(find.byType(_Settings), findsOneWidget);

    await pushRouteInformation(tester, 'fushi://ankiFetch');
    await tester.pumpAndSettle();

    // 第二份 _Home 出现在栈顶，设置页被埋在下面——这就是用户看到的「跳回主页」。
    expect(find.byType(_Home), findsOneWidget);
    expect(find.byType(_Settings, skipOffstage: false), findsOneWidget);
    expect(find.byType(_Home, skipOffstage: false), findsNWidgets(2));
  });

  testWidgets('修复：守卫先于 WidgetsApp 注册时，引擎深链不再动导航栈', (WidgetTester tester) async {
    final EngineDeepLinkRouteGuard guard = EngineDeepLinkRouteGuard();
    // 与 main.dart 的根 widget 同序：observer 在子树（WidgetsApp）build 之前注册。
    tester.binding.addObserver(guard);
    addTearDown(() => tester.binding.removeObserver(guard));

    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(buildApp(navigatorKey));
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const _Settings()),
    );
    await tester.pumpAndSettle();

    await pushRouteInformation(tester, 'fushi://ankiFetch');
    await tester.pumpAndSettle();

    expect(find.byType(_Settings), findsOneWidget);
    expect(find.byType(_Home, skipOffstage: false), findsOneWidget);
  });

  test('swallowEngineDeepLinkRoute 对本 app 会收到的每种回跳 URL 都答 true', () {
    for (final String url in <String>[
      'fushi://ankiFetch',
      'fushi://ankiSuccess?expression=%E8%A8%80%E8%91%89',
      'fushi://auth/onedrive?code=abc',
      'fushi://lookup?word=%E8%A8%80%E8%91%89',
    ]) {
      expect(
        swallowEngineDeepLinkRoute(RouteInformation(uri: Uri.parse(url))),
        isTrue,
        reason: url,
      );
    }
  });

  // 源码守卫：Swift / plist 进不了 flutter test，这层是 iOS 侧唯一可落地的自动化。
  group('iOS 侧', () {
    test('Info.plist 显式关掉引擎 deep linking', () {
      final String plist = File('ios/Runner/Info.plist').readAsStringSync();
      final RegExp key = RegExp(
        r'<key>FlutterDeepLinkingEnabled</key>\s*<false\s*/>',
      );
      expect(
        plist,
        matches(key),
        reason:
            'Flutter ≥ 3.27 缺省开启引擎 deep linking；不显式写 false，'
            'fushi:// 回跳就会被推成 pushRouteInformation → pushNamed("/")',
      );
    });

    test('根 widget 的 observer 先于 WidgetsApp 截断 pushRouteInformation', () {
      final String src = File('lib/main.dart').readAsStringSync();
      const String anchor = 'class _FushiReaderAppState';
      final int start = src.indexOf(anchor);
      expect(start, greaterThan(-1), reason: '锚点漂移，守卫失效');
      final String body = src.substring(start);
      expect(body, contains('with WidgetsBindingObserver'));
      expect(body, contains('Future<bool> didPushRouteInformation('));
      expect(body, contains('swallowEngineDeepLinkRoute(routeInformation)'));
      // 注册顺序是这层不变式的前提：observer 必须在 initState 里、build 之前挂上。
      final int initState = body.indexOf('void initState()');
      final int addObserver = body.indexOf(
        'WidgetsBinding.instance.addObserver(this)',
      );
      final int build = body.indexOf('Widget build(BuildContext context)');
      expect(initState, greaterThan(-1));
      expect(addObserver, greaterThan(initState));
      expect(build, greaterThan(addObserver));
    });
  });
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('home'));
}

class _Settings extends StatelessWidget {
  const _Settings();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('settings'));
}
