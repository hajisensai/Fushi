import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/cookie/browser_cookie_import.dart';
import 'package:fushi/src/media/manga/cookie/browser_login_import.dart';
import 'package:fushi/src/media/video/web_video_login_import.dart';

/// 视频站点网页档的「从浏览器导入登录」接入点（[WebVideoLoginImport] + 工具条按钮 +
/// 工具条下方状态条，`video_fushi/web_source.part.dart` 只做接线）。只用假的扩展回传
/// （直接调 [BrowserCookieImportGate.deliver]），不起真浏览器、不碰 WebView2。
void main() {
  const BrowserSiteCookie session = BrowserSiteCookie(
    name: 'sid',
    value: 'v1',
    domain: '.example.com',
    path: '/',
    secure: true,
    hostOnly: false,
  );
  const BrowserSiteCookie otherSite = BrowserSiteCookie(
    name: 'sid',
    value: 'x',
    domain: '.other.org',
    path: '/',
    secure: true,
    hostOnly: false,
  );

  late List<Uri> opened;
  late List<List<BrowserSiteCookie>> written;
  late List<int> imported;
  late WebVideoLoginImport controller;

  setUp(() {
    BrowserCookieImportGate.resetForTesting();
    opened = <Uri>[];
    written = <List<BrowserSiteCookie>>[];
    imported = <int>[];
    controller = WebVideoLoginImport(
      // 站内已经跳到了别的页面：按当前页面地址导，不按会话起始地址。
      urls: () => (
        currentUrl: 'https://www.example.com/login?next=/watch',
        pageUrl: 'https://start.example.net/',
      ),
      write: (List<BrowserSiteCookie> cookies) async {
        written.add(cookies);
        return cookies.length;
      },
      onImported: imported.add,
      onFailed: () {},
      openExternal: (Uri url) async => opened.add(url),
    );
  });

  tearDown(() {
    controller.dispose();
    BrowserCookieImportGate.resetForTesting();
  });

  Future<void> pumpBar(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            WebVideoLoginImportButton(controller: controller),
            WebVideoLoginImportStatusBar(controller: controller),
          ],
        ),
      ),
    ),
  );

  final Finder waitingBar = find.byKey(
    const ValueKey<String>('browser-login-import-waiting'),
  );
  final Finder cancelButton = find.byKey(
    const ValueKey<String>('browser-login-import-cancel'),
  );

  testWidgets('开始导入 → 等待条（含站点名）→ 取消 → 条收起、登记作废', (WidgetTester tester) async {
    await pumpBar(tester);
    expect(waitingBar, findsNothing);
    expect(BrowserCookieImportGate.pending, isNull);

    await tester.tap(
      find.byKey(const ValueKey<String>('video-web-login-import')),
    );
    await tester.pumpAndSettle();

    expect(BrowserCookieImportGate.pending?.host, 'example.com');
    expect(opened, <Uri>[Uri.parse('https://www.example.com/')]);
    expect(waitingBar, findsOneWidget);
    expect(
      find.text(t.login_import_pending(host: 'example.com')),
      findsOneWidget,
    );
    final String nonce = BrowserCookieImportGate.pending!.nonce;

    await tester.tap(cancelButton);
    await tester.pumpAndSettle();

    expect(waitingBar, findsNothing);
    expect(BrowserCookieImportGate.pending, isNull);
    expect(controller.import?.phase, BrowserLoginImportPhase.idle);
    // 作废的登记：扩展晚到的回传被拒（端点回 409），不写任何东西。
    expect(
      BrowserCookieImportGate.deliver(
        nonce: nonce,
        host: 'example.com',
        cookies: const <BrowserSiteCookie>[session],
      ),
      isFalse,
    );
    await tester.pumpAndSettle();
    expect(written, isEmpty);
    expect(imported, isEmpty);
  });

  testWidgets('同站点首批 cookie 到达即结束登记：条收起、只写一次', (WidgetTester tester) async {
    await pumpBar(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('video-web-login-import')),
    );
    await tester.pumpAndSettle();
    final String nonce = BrowserCookieImportGate.pending!.nonce;

    // 别站心跳不算导入：接着等。
    expect(
      BrowserCookieImportGate.deliver(
        nonce: nonce,
        host: 'other.org',
        cookies: const <BrowserSiteCookie>[otherSite],
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(waitingBar, findsOneWidget);
    expect(BrowserCookieImportGate.pending, isNotNull);
    expect(written, isEmpty);

    expect(
      BrowserCookieImportGate.deliver(
        nonce: nonce,
        host: 'example.com',
        cookies: const <BrowserSiteCookie>[session, otherSite],
      ),
      isTrue,
    );
    // deliver 返回时登记已同步撤销。
    expect(BrowserCookieImportGate.pending, isNull);
    await tester.pumpAndSettle();

    expect(waitingBar, findsNothing);
    expect(written, <List<BrowserSiteCookie>>[
      <BrowserSiteCookie>[session],
    ]);
    expect(imported, <int>[1]);
    expect(controller.import?.phase, BrowserLoginImportPhase.imported);
    // 之后该站每次加载 / 心跳的重送一律被拒，不会再灌一批、再刷一次页。
    expect(
      BrowserCookieImportGate.deliver(
        nonce: nonce,
        host: 'example.com',
        cookies: const <BrowserSiteCookie>[session],
      ),
      isFalse,
    );
    await tester.pumpAndSettle();
    expect(written, hasLength(1));
  });

  testWidgets('会话未就绪（无地址）时按钮什么都不登记', (WidgetTester tester) async {
    final WebVideoLoginImport noSession = WebVideoLoginImport(
      urls: () => null,
      write: (List<BrowserSiteCookie> _) async => 0,
      onImported: (int _) {},
      onFailed: () {},
      openExternal: (Uri url) async => opened.add(url),
    );
    addTearDown(noSession.dispose);
    await noSession.begin();
    expect(BrowserCookieImportGate.pending, isNull);
    expect(noSession.import, isNull);
    expect(opened, isEmpty);
  });

  test('站点选择：当前页面优先，空时退回起始地址，无 host 为 null', () {
    expect(
      webVideoLoginImportSite(
        currentUrl: '',
        pageUrl: 'https://www.netflix.com/browse',
      )?.host,
      'www.netflix.com',
    );
    expect(
      webVideoLoginImportSite(currentUrl: 'about:blank', pageUrl: ''),
      isNull,
    );
  });

  test('接线：视频网页档经 WebVideoLoginImport 接入，不再自己建 BrowserLoginImport', () {
    final String part = _read(
      'lib/src/pages/implementations/video_fushi/web_source.part.dart',
    );
    expect(part, contains('WebVideoLoginImportButton(controller: import)'));
    expect(part, contains('WebVideoLoginImportStatusBar(controller: import)'));
    expect(part, isNot(contains('BrowserLoginImport(')));
  });
}

String _read(String path) => File(path).readAsStringSync();
