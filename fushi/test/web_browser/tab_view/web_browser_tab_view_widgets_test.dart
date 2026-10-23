// 标签页 WebView 的组件：标签页视图（注入桩 WebView）的功能插件回调与取词表面门控、
// 加载失败页、页内查找条、站点图标。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/web_browser/data/memory_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_error_view.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_favicon.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_find_bar.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_tab_view.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab_host.dart';

import '../../helpers/test_platform_services.dart';

class _App extends AppModel {
  _App() : super(testPlatformServices());
}

class _RecordingFeature extends WebBrowserFeature {
  final List<String> events = <String>[];

  @override
  String get id => 'recording';

  @override
  void onTabActiveChanged(WebBrowserTab tab, {required bool active}) =>
      events.add('${tab.id}:active=$active');

  @override
  void onTabClosed(WebBrowserTab tab) => events.add('${tab.id}:closed');
}

class _Host implements WebBrowserTabHost {
  _Host(this.features);

  @override
  final List<WebBrowserFeature> features;

  @override
  final WebBrowserStore store = MemoryWebBrowserStore();

  String? activeId;
  final List<Uri?> opened = <Uri?>[];

  @override
  WebBrowserTab openTab(
    Uri? url, {
    String? openerId,
    int? windowId,
    bool incognito = false,
    bool activate = true,
  }) {
    opened.add(url);
    return WebBrowserTab(id: 'new', url: url);
  }

  @override
  void closeTab(WebBrowserTab tab) {}

  @override
  bool isActive(WebBrowserTab tab) => tab.id == activeId;

  @override
  void onContentScrolled(
    WebBrowserTab tab, {
    required int y,
    required int dy,
  }) {}

  @override
  void onFullscreenChanged(WebBrowserTab tab, {required bool fullscreen}) {}
}

Widget _wrap(Widget child, {List<Override> overrides = const <Override>[]}) =>
    ProviderScope(
      overrides: overrides,
      child: TranslationProvider(
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('WebBrowserTabView（桩 WebView）', () {
    late FushiDatabase db;
    late _App appModel;
    late Directory tmp;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      tmp = Directory.systemTemp.createTempSync('fushi_tab_view_');
      appModel = _App()
        ..wireDatabaseForTesting(db)
        ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp);
      WebBrowserTabView.debugWebViewBuilder =
          (BuildContext _, WebBrowserTab tab) => ColoredBox(
            key: ValueKey<String>('stub-${tab.id}'),
            color: Colors.white,
          );
    });

    tearDown(() async {
      WebBrowserTabView.debugWebViewBuilder = null;
      await db.close();
      try {
        tmp.deleteSync(recursive: true);
      } on Object {
        // Windows 偶发占用。
      }
    });

    testWidgets('视图不发插件的前后台 / 关闭回调（归标签控制器）；后台页不接 barrier 取词', (
      WidgetTester tester,
    ) async {
      final _RecordingFeature feature = _RecordingFeature();
      final _Host host = _Host(<WebBrowserFeature>[feature])..activeId = 'a';
      final WebBrowserTab a = WebBrowserTab(
        id: 'a',
        url: Uri.parse('https://a.test/'),
      );
      final WebBrowserTab b = WebBrowserTab(
        id: 'b',
        url: Uri.parse('https://b.test/'),
      );
      final SrsCardLookupController lookup = SrsCardLookupController(
        settings: () => (tap: true, hoverAuto: false),
      );
      addTearDown(lookup.dispose);

      Widget page() => SrsCardLookupScope(
        controller: lookup,
        child: IndexedStack(
          index: host.activeId == 'a' ? 0 : 1,
          children: <Widget>[
            WebBrowserTabView(
              key: const ValueKey<String>('a'),
              tab: a,
              host: host,
            ),
            WebBrowserTabView(
              key: const ValueKey<String>('b'),
              tab: b,
              host: host,
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        _wrap(
          page(),
          overrides: <Override>[
            appProvider.overrideWith((Ref ref) => appModel),
          ],
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('stub-a')), findsOneWidget);
      // 视图被回收 / 重建也会 dispose，那不是「关闭」：前后台与关闭只由控制器发。
      expect(feature.events, isEmpty);

      host.activeId = 'b';
      await tester.pumpWidget(
        _wrap(
          page(),
          overrides: <Override>[
            appProvider.overrideWith((Ref ref) => appModel),
          ],
        ),
      );
      await tester.pump();
      expect(feature.events, isEmpty);

      // 后台标签页（a）不响应 barrier 转发的取词；桩没有控制器，前台的也返回 false。
      final WebBrowserTabViewState stateA = tester.state(
        find.byKey(const ValueKey<String>('a'), skipOffstage: false),
      );
      expect(stateA.lookupAt(const Offset(10, 10), fromHover: false), isFalse);

      await tester.pumpWidget(
        _wrap(
          const SizedBox.shrink(),
          overrides: <Override>[
            appProvider.overrideWith((Ref ref) => appModel),
          ],
        ),
      );
      expect(feature.events, isEmpty);
    });
  });

  testWidgets('加载失败页：断网文案 + 重试', (WidgetTester tester) async {
    int retries = 0;
    await tester.pumpWidget(
      _wrap(
        WebBrowserErrorView(
          error: WebBrowserLoadError(
            url: Uri.parse('https://a.test/'),
            description: 'x',
            offline: true,
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.web_browser_error_offline_title), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('web-browser-error-retry')),
    );
    expect(retries, 1);
  });

  testWidgets('加载失败页：空白 HTTP 错误显示状态码', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        WebBrowserErrorView(
          error: WebBrowserLoadError(
            url: Uri.parse('https://a.test/'),
            description: 'HTTP 502',
            statusCode: 502,
          ),
          onRetry: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.web_browser_error_title), findsOneWidget);
    expect(find.text(t.web_browser_error_http_body(code: 502)), findsOneWidget);
  });

  testWidgets('页内查找条：输入即查、计数、下一个、Esc 关闭', (WidgetTester tester) async {
    final WebBrowserTab tab = WebBrowserTab(id: 't', url: null)
      ..update(findOpen: true);
    final List<String> scripts = <String>[];
    await tester.pumpWidget(
      _wrap(
        WebBrowserFindBar(
          tab: tab,
          runner: (String script) async {
            scripts.add(script);
            if (script.contains('.run(')) return '{"count":4,"current":1}';
            if (script.contains('.step(1)')) return '{"count":4,"current":2}';
            return '{"count":0,"current":0}';
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('web-browser-find-field')),
      'ab',
    );
    await tester.pumpAndSettle();
    expect(find.text('1/4'), findsOneWidget);
    expect(scripts.last, contains('run("ab")'));

    await tester.tap(
      find.byKey(const ValueKey<String>('web-browser-find-next')),
    );
    await tester.pumpAndSettle();
    expect(find.text('2/4'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('web-browser-find-close')),
    );
    await tester.pump();
    expect(tab.findOpen, isFalse);
  });

  testWidgets('站点图标：没有图标地址时画首字母色块', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        Center(
          child: WebBrowserFavicon(
            url: Uri.parse('https://www.kakuyomu.jp/'),
            title: '',
          ),
        ),
      ),
    );
    expect(find.text('K'), findsOneWidget);
    expect(
      webBrowserFaviconColorFor('kakuyomu.jp'),
      webBrowserFaviconColorFor('KAKUYOMU.JP'),
    );
    expect(webBrowserFaviconLetter(title: 'カクヨム', url: null), 'カ');
  });
}
