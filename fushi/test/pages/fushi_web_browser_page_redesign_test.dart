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
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey<String>('web-browser-close')));
      await tester.pumpAndSettle();
      expect(find.byType(FushiWebBrowserPage), findsNothing);
      expect(find.text('Example'), findsOneWidget);
    });
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
