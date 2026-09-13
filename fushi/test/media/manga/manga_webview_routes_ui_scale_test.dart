import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_cloudflare_challenge_page.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_challenge.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_gate.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_login_page.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';

/// BUG-2522：漫画源登录页 / Cloudflare 挑战页在「界面整体缩放」≠ 1 时整页发糊。
///
/// 根因不在 WebView 本身：`FushiAppUiScale` 用 FittedBox 把整棵子树按 s 缩放，
/// 子树里的 WebView 纹理按 view/s 的画布栅格化、再被拉伸 s 倍。阅读器 / 漫画 /
/// 视频页都在**路由层**包了 `FushiAppUiScaleNeutralizer`，这三条推 WebView 的路由
/// 漏了。守法：把探针当页面推进去，断言探针拿到的布局尺寸等于**真实视口**
/// （800×600），而不是被缩放过的画布（800/1.5 × 600/1.5）。
void main() {
  const double scale = 1.5;
  const Size viewport = Size(800, 600);

  final GlobalKey probeKey = GlobalKey();
  Widget probe() => SizedBox.expand(key: probeKey);

  Size probeSize() {
    final RenderBox box =
        probeKey.currentContext!.findRenderObject()! as RenderBox;
    return box.size;
  }

  /// 与 `main.dart` 同一形状：`FushiAppUiScale` 在 `MaterialApp.builder` 里包住
  /// 整个 navigator，被推的路由必然落在缩放之下。
  Widget scaledApp({
    required GlobalKey<NavigatorState> navigatorKey,
    required Widget home,
  }) => MaterialApp(
    navigatorKey: navigatorKey,
    builder: (BuildContext context, Widget? child) =>
        FushiAppUiScale(scale: scale, child: child!),
    home: home,
  );

  setUp(() {
    AidokuCloudflareGate.resolver = null;
    MihonCloudflareGate.resolver = null;
  });
  tearDown(() {
    AidokuCloudflareGate.resolver = null;
    MihonCloudflareGate.resolver = null;
  });

  testWidgets('对照：不中和的路由在缩放下只拿到 view/s 的画布（确认探针本身有效）', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      scaledApp(navigatorKey: navigatorKey, home: const SizedBox.shrink()),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (BuildContext _) => probe()),
    );
    await tester.pumpAndSettle();
    expect(probeSize(), viewport / scale);
  });

  testWidgets('openMihonWebLogin 推的登录页按真实视口布局', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    late BuildContext homeContext;
    await tester.pumpWidget(
      scaledApp(
        navigatorKey: navigatorKey,
        home: Builder(
          builder: (BuildContext context) {
            homeContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final Future<bool> opened = openMihonWebLogin(
      homeContext,
      runtime: _BrowserRuntime(),
      sourceName: 'BookWalker',
      baseUrl: 'https://bookwalker.jp',
      pageBuilder: (Uri target, MihonCookieJar? jar) => probe(),
    );
    await tester.pumpAndSettle();
    expect(probeSize(), viewport);
    navigatorKey.currentState!.pop(true);
    await tester.pumpAndSettle();
    expect(await opened, isTrue);
  });

  testWidgets('Aidoku Cloudflare 挑战页按真实视口布局', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      scaledApp(navigatorKey: navigatorKey, home: const SizedBox.shrink()),
    );
    installAidokuCloudflareResolver(
      navigatorKey,
      pageBuilder: (Uri url, String ua) => probe(),
    );
    final Future<bool> solving = AidokuCloudflareGate.resolver!(
      Uri.parse('https://cf.invalid/'),
      'ua',
    );
    await tester.pumpAndSettle();
    expect(probeSize(), viewport);
    navigatorKey.currentState!.pop(true);
    await tester.pumpAndSettle();
    expect(await solving, isTrue);
  });

  testWidgets('Mihon Cloudflare 挑战页按真实视口布局', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      scaledApp(navigatorKey: navigatorKey, home: const SizedBox.shrink()),
    );
    installMihonCloudflareResolver(
      navigatorKey,
      pageBuilder: (Uri url, String ua, MangaCookieJar target) => probe(),
    );
    final MihonCookieJar jar = MihonCookieJar(
      File('${Directory.systemTemp.path}/bug-2522-unused-cookies.json'),
    );
    final Future<bool> solving = MihonCloudflareGate.resolver!(
      Uri.parse('https://cf.invalid/'),
      'ua',
      jar,
    );
    await tester.pumpAndSettle();
    expect(probeSize(), viewport);
    navigatorKey.currentState!.pop(true);
    await tester.pumpAndSettle();
    expect(await solving, isTrue);
  });
}

/// 「浏览器持有 cookie」的运行时：登录页什么都不导出，最短路径通过入口判据。
class _BrowserRuntime implements BrowserCookieMihonRuntime {}
