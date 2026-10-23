import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/fushi_web_browser_page.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/web_adblock/web_adblock_service.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';

import '../helpers/test_platform_services.dart';

/// 2026-10-19 用户截图三连：
/// ① 浏览器页点「⋯」左上角凭空出现返回键——根因是脚手架默认返回键问的是
///    `Navigator.canPop()`（整个导航栈），弹出菜单路由压栈也算数；
/// ② 浏览器嵌在模块页里，主导航底栏 + 「阅读本章」FAB 叠在网页上互相遮挡、
///    顶部还有一整行「浏览器」标题；
/// 重设计后：模块页只是入口（地址栏 + 站点），打开网址推全屏浏览页。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('脚手架默认返回键只看本页路由', () {
    testWidgets('根页在弹出路由（菜单 / 对话框）打开期间重建，不长出返回键', (WidgetTester tester) async {
      final GlobalKey<_RebuildableRootState> root =
          GlobalKey<_RebuildableRootState>();
      await tester.pumpWidget(MaterialApp(home: _RebuildableRoot(key: root)));
      expect(find.byTooltip('Back'), findsNothing);

      showDialog<void>(
        context: root.currentContext!,
        builder: (BuildContext _) => const AlertDialog(content: Text('menu')),
      );
      await tester.pumpAndSettle();
      root.currentState!.rebuild();
      await tester.pump();

      expect(
        find.byTooltip('Back'),
        findsNothing,
        reason: '弹出路由压在根页之上时 Navigator.canPop() 为 true，但根页本身没有可退的页面',
      );
    });

    testWidgets('推出来的页照常有返回键', (WidgetTester tester) async {
      final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: nav, home: const Text('origin')),
      );
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) =>
              const FushiPageScaffold(title: 'pushed', body: SizedBox()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Back'), findsOneWidget);
    });
  });

  test('浏览页返回的优先级：查词弹窗 → 网页历史 → 离开浏览页', () {
    // 弹窗栈挂在浏览页路由之内、没有自己的 PopScope：弹窗开着时返回若直接退
    // 网页历史 / 整页 pop，弹窗会留在换掉的网页上，或随浏览页一起被关掉。
    for (final bool canGoBack in <bool>[false, true]) {
      expect(
        webBrowserBackStep(lookupOpen: true, canGoBack: canGoBack),
        WebBrowserBackStep.closeLookup,
      );
    }
    expect(
      webBrowserBackStep(lookupOpen: false, canGoBack: true),
      WebBrowserBackStep.webHistoryBack,
    );
    expect(
      webBrowserBackStep(lookupOpen: false, canGoBack: false),
      WebBrowserBackStep.leavePage,
    );
  });

  group('浏览器：入口页 + 全屏浏览页', () {
    late FushiDatabase db;
    late AppModel appModel;
    late Directory tmp;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      await prefs.setWebBrowserSitesJson(
        encodeWebBrowserSites(<WebBrowserSite>[
          WebBrowserSite(
            name: 'Example',
            url: Uri.parse('https://example.com/'),
          ),
        ]),
      );
      tmp = Directory.systemTemp.createTempSync('fushi_web_browser_');
      appModel = AppModel(testPlatformServices())
        ..wireDatabaseForTesting(db)
        ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp);
      MangaWebViewEnvironment.override = () async => null;
      FushiWebBrowserPage.debugWebViewBuilder = (BuildContext _) =>
          const ColoredBox(
            key: ValueKey<String>('stub-webview'),
            color: Colors.white,
          );
    });

    tearDown(() async {
      MangaWebViewEnvironment.override = null;
      FushiWebBrowserPage.debugWebViewBuilder = null;
      await db.close();
      try {
        tmp.deleteSync(recursive: true);
      } on Object {
        // Windows 偶发占用：临时目录留给系统清理。
      }
    });

    Future<void> pumpHome(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith((Ref ref) => appModel),
            // 没有数据目录：广告拦截核心不打开，也不联网。
            webAdblockServiceProvider.overrideWith(
              (Ref ref) => WebAdblockService(
                dataDir: () => null,
                fetcher:
                    (Uri url, {String? etag, String? lastModified}) async =>
                        const AdblockFetchResponse(statusCode: 503),
              ),
            ),
          ],
          child: TranslationProvider(
            child: const MaterialApp(home: FushiWebBrowserHomePage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('入口页（手机、单子页）不画「浏览器」标题，地址栏在顶、站点成网格', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      expect(find.text(t.web_browser_title), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('web-browser-address')),
        findsOneWidget,
      );
      expect(find.text('Example'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('stub-webview')), findsNothing);
      // 地址栏是网址键盘、不自动更正（搜索框默认的文本键盘会把网址改坏）。
      final EditableText entry = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('web-browser-address')),
          matching: find.byType(EditableText),
        ),
      );
      expect(entry.keyboardType, TextInputType.url);
      expect(entry.autocorrect, isFalse);
    });

    testWidgets('点站点推全屏浏览页：地址栏 + 底部工具栏放得下、✕ 回入口页', (WidgetTester tester) async {
      await pumpHome(tester);
      await tester.tap(find.text('Example'));
      await tester.pumpAndSettle();

      expect(find.byType(FushiWebBrowserPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('stub-webview')),
        findsOneWidget,
      );
      final EditableText address = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('web-browser-address')),
          matching: find.byType(EditableText),
        ),
      );
      expect(address.controller.text, 'https://example.com/');
      expect(address.keyboardType, TextInputType.url);
      expect(address.autocorrect, isFalse);

      final Finder toolbar = find.byKey(
        const ValueKey<String>('web-browser-toolbar'),
      );
      expect(toolbar, findsOneWidget);
      final Rect bar = tester.getRect(toolbar);
      expect(bar.left, greaterThanOrEqualTo(0));
      expect(bar.right, lessThanOrEqualTo(360));
      expect(
        bar.bottom,
        lessThanOrEqualTo(780),
        reason: '工具栏在网页下方、窗口之内（不再被主导航底栏盖住）',
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey<String>('stub-webview')))
            .bottom,
        lessThanOrEqualTo(bar.top),
        reason: '工具栏不叠在网页上：WebView 内容拿不到底部让位',
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey<String>('web-browser-address')))
            .top,
        greaterThanOrEqualTo(
          tester
              .getRect(find.byKey(const ValueKey<String>('stub-webview')))
              .bottom,
        ),
        reason: '手机竖屏：地址栏也在底部（网页下方）',
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey<String>('web-browser-close')));
      await tester.pumpAndSettle();
      expect(find.byType(FushiWebBrowserPage), findsNothing);
      expect(find.text('Example'), findsOneWidget);
    });

    // 5wWlKU_Rir：站点可手动添加 / 编辑（本机服务地址没有点号也能存）。
    testWidgets('手动添加本机地址站点，再长按编辑名称，写穿偏好', (WidgetTester tester) async {
      await pumpHome(tester);
      Future<void> submitDialogText(String text) async {
        final Finder field = find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(EditableText),
        );
        await tester.enterText(field, text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
      }

      await tester.tap(
        find.byKey(const ValueKey<String>('web-browser-site-new')),
      );
      await tester.pumpAndSettle();
      await submitDialogText('localhost:55000/texthooker');
      await submitDialogText('Texthooker');
      expect(find.text('Texthooker'), findsOneWidget);
      expect(
        parseWebBrowserSites(
          appModel.prefsRepo.webBrowserSitesJson,
          presets: const <WebBrowserSite>[],
        ).map((WebBrowserSite s) => '${s.name}|${s.url}'),
        <String>[
          'Example|https://example.com/',
          'Texthooker|http://localhost:55000/texthooker',
        ],
      );

      await tester.longPress(find.text('Texthooker'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.web_browser_site_edit));
      await tester.pumpAndSettle();
      await submitDialogText('http://127.0.0.1:55000/texthooker');
      await submitDialogText('TH');
      expect(find.text('TH'), findsOneWidget);
      expect(
        parseWebBrowserSites(
          appModel.prefsRepo.webBrowserSitesJson,
          presets: const <WebBrowserSite>[],
        ).map((WebBrowserSite s) => '${s.name}|${s.url}'),
        <String>[
          'Example|https://example.com/',
          'TH|http://127.0.0.1:55000/texthooker',
        ],
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('手机横屏：地址栏与工具栏并成顶部一行、都在网页上方', (WidgetTester tester) async {
      await pumpHome(tester);
      await tester.tap(find.text('Example'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(780, 360);
      await tester.pumpAndSettle();

      final Rect web = tester.getRect(
        find.byKey(const ValueKey<String>('stub-webview')),
      );
      final Rect address = tester.getRect(
        find.byKey(const ValueKey<String>('web-browser-address')),
      );
      final Rect bar = tester.getRect(
        find.byKey(const ValueKey<String>('web-browser-toolbar')),
      );
      expect(address.bottom, lessThanOrEqualTo(web.top));
      expect(bar.bottom, lessThanOrEqualTo(web.top));
      expect(address.right, lessThanOrEqualTo(bar.left), reason: '同一行，地址栏在左');
      expect(bar.right, lessThanOrEqualTo(780));
      expect(web.bottom, 360, reason: '底部不再留工具栏');
      expect(tester.takeException(), isNull);
    });
  });

  test('chrome 摆放只看窗口宽度：窄窗口底部、宽窗口顶部', () {
    expect(
      webBrowserChromeLayout(size: const Size(390, 844)),
      WebBrowserChromeLayout.bottom,
    );
    expect(
      webBrowserChromeLayout(size: const Size(599, 900)),
      WebBrowserChromeLayout.bottom,
    );
    expect(
      webBrowserChromeLayout(size: const Size(600, 900)),
      WebBrowserChromeLayout.top,
    );
    expect(
      webBrowserChromeLayout(size: const Size(844, 390)),
      WebBrowserChromeLayout.top,
    );
    expect(
      webBrowserChromeLayout(size: const Size(1600, 1000)),
      WebBrowserChromeLayout.top,
    );
  });
}

class _RebuildableRoot extends StatefulWidget {
  const _RebuildableRoot({super.key});

  @override
  State<_RebuildableRoot> createState() => _RebuildableRootState();
}

class _RebuildableRootState extends State<_RebuildableRoot> {
  int _generation = 0;

  void rebuild() => setState(() => _generation++);

  @override
  Widget build(BuildContext context) =>
      FushiPageScaffold(title: 'root $_generation', body: const SizedBox());
}
