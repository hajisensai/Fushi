import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as webview;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_login_page.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare.dart';
import 'package:fushi/src/media/novel/online/lnreader_fetch_bridge.dart';
import 'package:fushi/src/media/novel/online/lnreader_installed_sources_section.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_source_browse_page.dart';
import 'package:fushi/src/media/novel/online/lnreader_web_login.dart';

import 'fake_lnreader_runtime.dart';

/// 小说源 app 内登录：登录页写的是小说源自己的 jar（出站桥唯一的 cookie 存储，
/// 写进去即生效）；入口出现在源列表菜单、加载失败与空结果的错误区。
void main() {
  late Directory root;
  late FakeLnReaderRuntime runtime;
  late LnReaderCloudflare cloudflare;
  late LnReaderManager manager;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('lnreader_login_test');
    runtime = FakeLnReaderRuntime();
    await File('${root.path}/state.json').writeAsString(
      '{"stores":[],"installed":[{"id":"syosetu","name":"Syosetu",'
      '"site":"https://syosetu.example/","lang":"日本語","version":"1.0.0",'
      '"url":"","iconUrl":"","storeUrl":"","enabled":true,'
      '"pinned":false,"sortOrder":0,"installedAt":0}]}',
    );
    cloudflare = LnReaderCloudflare(
      MangaCookieJar(File('${root.path}/cookies.json')),
    );
    manager = LnReaderManager(
      rootDirectory: root,
      runtime: runtime,
      httpClientFactory: HttpClient.new,
      cloudflare: cloudflare,
    );
    await manager.initialise();
    await manager.pluginFile('syosetu').create(recursive: true);
  });

  tearDown(() async {
    manager.dispose();
    await root.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: child,
        ),
      ),
    );
    await tester.pump();
  }

  group('登录入口的能力判据', () {
    test('有 jar 且 site 解析得出 http(s) host 才给入口', () {
      expect(
        lnReaderLoginTarget(
          cloudflare: cloudflare,
          site: ' https://syosetu.example/ ',
        ),
        Uri.parse('https://syosetu.example/'),
      );
    });

    test('没有 jar（单测 / 无 UI 构造的 manager）→ 无入口', () {
      expect(
        lnReaderLoginTarget(cloudflare: null, site: 'https://syosetu.example/'),
        isNull,
      );
    });

    test('site 解析不出 host 或不是网页地址 → 无入口', () {
      for (final String site in <String>[
        '',
        '   ',
        '/relative',
        'not a url',
        'ftp://syosetu.example/',
      ]) {
        expect(
          lnReaderLoginTarget(cloudflare: cloudflare, site: site),
          isNull,
          reason: 'site=$site 不该给出登录入口',
        );
      }
    });
  });

  /// 用 [openLnReaderWebLogin] 推**真的** [MihonWebLoginPage]（只替掉平台 WebView
  /// 与 CookieManager），返回 pop 结果的取值器。
  Future<bool? Function()> openLogin(
    WidgetTester tester, {
    required bool isDesktop,
    List<webview.Cookie> browserCookies = const <webview.Cookie>[],
  }) async {
    bool? outcome;
    await pump(
      tester,
      Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () async {
            outcome = await openLnReaderWebLogin(
              context,
              manager: manager,
              plugin: manager.installed.single,
              isDesktop: isDesktop,
              cookieReader: (webview.WebUri _) async => browserCookies,
              environmentFactory: () async => null,
              webViewBuilder: (_) =>
                  const SizedBox(key: ValueKey<String>('stub-webview')),
            );
          },
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => outcome;
  }

  MihonWebLoginPage loginPage(WidgetTester tester) =>
      tester.widget<MihonWebLoginPage>(find.byType(MihonWebLoginPage));

  // 审查（PR #2986）：原先测试用 pageBuilder 整个替掉登录页，生产里传给
  // MihonWebLoginPage 的 UA / jar / 导入开关删了测试照绿。现在断言真页的入参。
  testWidgets('登录页用桥的 UA、写小说源的 jar；移动端不给「从浏览器导入」', (WidgetTester tester) async {
    await openLogin(tester, isDesktop: false);
    final MihonWebLoginPage page = loginPage(tester);
    expect(page.userAgent, LnReaderFetchBridge.defaultUserAgent);
    expect(
      identical(page.jar, cloudflare.jar),
      isTrue,
      reason: '登录页必须写出站桥读的那份 jar，否则登了也不生效',
    );
    expect(page.baseUrl, Uri.parse('https://syosetu.example/'));
    expect(page.browserImportAvailable, isFalse);
    expect(
      find.byKey(const ValueKey<String>('mihon_login_import_browser')),
      findsNothing,
    );
  });

  testWidgets('桌面给「从浏览器导入」', (WidgetTester tester) async {
    await openLogin(tester, isDesktop: true);
    expect(loginPage(tester).browserImportAvailable, isTrue);
    expect(
      find.byKey(const ValueKey<String>('mihon_login_import_browser')),
      findsOneWidget,
    );
  });

  testWidgets('点「完成」：整站 cookie 写进小说源 jar 并返回 true', (
    WidgetTester tester,
  ) async {
    final bool? Function() outcome = await openLogin(
      tester,
      isDesktop: false,
      browserCookies: <webview.Cookie>[
        webview.Cookie(
          name: 'ses',
          value: 'signed-in',
          domain: '.syosetu.example',
        ),
      ],
    );
    await tester.tap(find.byKey(const ValueKey<String>('mihon_login_done')));
    final Stopwatch clock = Stopwatch()..start();
    while (find.byType(MihonWebLoginPage).evaluate().isNotEmpty &&
        clock.elapsed < const Duration(seconds: 10)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(outcome(), isTrue);
    expect(
      cloudflare.jar
          .cookiesFor(Uri.parse('https://syosetu.example/'))
          .map((MangaCookie c) => '${c.name}=${c.value}'),
      <String>['ses=signed-in'],
    );
  });

  testWidgets('关页取消：返回 false', (WidgetTester tester) async {
    final bool? Function() outcome = await openLogin(tester, isDesktop: false);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(MihonWebLoginPage), findsNothing);
    expect(outcome(), isFalse);
  });

  testWidgets('源列表「⋯」菜单有「登录」', (WidgetTester tester) async {
    await pump(
      tester,
      Scaffold(
        body: CustomScrollView(
          slivers: <Widget>[
            LnReaderInstalledSourcesSection(
              manager: manager,
              onOpenSource: (LnReaderInstalledPlugin _) {},
            ),
          ],
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('novel_source_menu_syosetu')),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.mihon_source_login), findsOneWidget);
  });

  /// 等浏览页把 [call] 交给假运行时、结果回来后的 setState 出帧。
  Future<void> untilCalled(WidgetTester tester, String call) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!runtime.calls.contains(call)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('runtime never received $call (got ${runtime.calls})');
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump();
    await tester.pump();
  }

  const ValueKey<String> loginKey = ValueKey<String>(
    'novel_source_login_syosetu',
  );

  /// 按钮所在 Wrap 的宽度等于按钮本身：没显示的 Cloudflare 按钮不该留下
  /// `spacing` 空隙把登录按钮挤偏。
  void expectLoginNotOffset(WidgetTester tester) {
    final Finder wrap = find
        .ancestor(of: find.byKey(loginKey), matching: find.byType(Wrap))
        .first;
    expect(
      tester.getSize(wrap).width,
      tester.getSize(find.byKey(loginKey)).width,
      reason: '零尺寸的 Cloudflare 按钮仍占 spacing 时 Wrap 会比登录按钮宽 8',
    );
  }

  testWidgets('浏览页加载失败时错误旁给「登录」，不被隐形的验证按钮挤偏', (WidgetTester tester) async {
    runtime.popularError = Exception('HTTP 401');
    await pump(
      tester,
      LnReaderSourceBrowsePage(
        manager: manager,
        plugin: manager.installed.single,
      ),
    );
    await untilCalled(tester, 'popular:1:false');
    expect(find.byKey(loginKey), findsOneWidget);
    expectLoginNotOffset(tester);
  });

  // 产品取舍（审查 #4）：插件撞上要登录的站多半只回空列表、不抛错（verifyOnEmpty
  // 同理），区分不出「真没有」还是「没登录看不到」，空结果也给登录入口。
  testWidgets('浏览页回空列表：同样给「登录」', (WidgetTester tester) async {
    await pump(
      tester,
      LnReaderSourceBrowsePage(
        manager: manager,
        plugin: manager.installed.single,
      ),
    );
    await untilCalled(tester, 'popular:1:false');
    expect(find.text(t.novel_source_no_results), findsOneWidget);
    expect(find.byKey(loginKey), findsOneWidget);
    expectLoginNotOffset(tester);
  });
}
