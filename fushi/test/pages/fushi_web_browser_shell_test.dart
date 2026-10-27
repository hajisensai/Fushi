// 多标签页浏览器壳（设计图 v4）：入口页 + 全屏浏览页的 widget 测试。
//
// 标签页 WebView 用 `FushiWebBrowserPage.debugTabViewBuilder` 换成色块（widget 测试
// 没有平台视图），浏览器数据用内存版 store。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/fushi_web_browser_page.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:fushi/src/web_adblock/web_adblock_service.dart';
import 'package:fushi/src/web_browser/data/memory_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store_provider.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/web_browser/web_browser_prefs.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';

import '../helpers/test_platform_services.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  late FushiDatabase db;
  late AppModel appModel;
  late MemoryWebBrowserStore store;
  late Directory tmp;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    await prefs.setWebBrowserSitesJson(
      encodeWebBrowserSites(<WebBrowserSite>[
        WebBrowserSite(name: 'Example', url: Uri.parse('https://example.com/')),
      ]),
    );
    tmp = Directory.systemTemp.createTempSync('fushi_web_browser_');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp);
    store = MemoryWebBrowserStore();
    MangaWebViewEnvironment.override = () async => null;
    FushiWebBrowserPage.debugTabViewBuilder =
        (BuildContext _, WebBrowserTab tab) => ColoredBox(
          key: const ValueKey<String>('stub-webview'),
          color: Colors.white,
          child: Text('page ${tab.url}'),
        );
  });

  tearDown(() async {
    MangaWebViewEnvironment.override = null;
    FushiWebBrowserPage.debugTabViewBuilder = null;
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } on Object {
      // Windows 偶发占用：临时目录留给系统清理。
    }
  });

  List<Override> overrides() => <Override>[
    appProvider.overrideWith((Ref ref) => appModel),
    webBrowserStoreProvider.overrideWithValue(store),
    // 没有数据目录：广告拦截核心不打开，也不联网。
    webAdblockServiceProvider.overrideWith(
      (Ref ref) => WebAdblockService(
        dataDir: () => null,
        fetcher: (Uri url, {String? etag, String? lastModified}) async =>
            const AdblockFetchResponse(statusCode: 503),
      ),
    ),
  ];

  Future<void> pumpApp(WidgetTester tester, Size size, Widget home) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: TranslationProvider(child: MaterialApp(home: home)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpBrowser(WidgetTester tester, Size size) => pumpApp(
    tester,
    size,
    const FushiWebBrowserPage(initialUrl: 'https://example.com/'),
  );

  FushiWebBrowserPageState page(WidgetTester tester) =>
      tester.state<FushiWebBrowserPageState>(find.byType(FushiWebBrowserPage));

  Finder byKey(String key) => find.byKey(ValueKey<String>(key));

  testWidgets('入口页（手机、单子页）不画「浏览器」标题，地址栏在顶、站点成网格', (WidgetTester tester) async {
    await pumpApp(
      tester,
      const Size(360, 780),
      const FushiWebBrowserHomePage(),
    );
    expect(find.text(t.web_browser_title), findsNothing);
    expect(byKey('web-browser-address'), findsOneWidget);
    expect(find.text('Example'), findsOneWidget);
    expect(byKey('stub-webview'), findsNothing);
    // 地址栏是网址键盘、不自动更正（搜索框默认的文本键盘会把网址改坏）。
    final EditableText entry = tester.widget<EditableText>(
      find.descendant(
        of: byKey('web-browser-address'),
        matching: find.byType(EditableText),
      ),
    );
    expect(entry.keyboardType, TextInputType.url);
    expect(entry.autocorrect, isFalse);
  });

  testWidgets('竖屏：点站点推全屏浏览页，底栏在网页下方，地址栏点开才可编辑，后退回入口页', (
    WidgetTester tester,
  ) async {
    await pumpApp(
      tester,
      const Size(360, 780),
      const FushiWebBrowserHomePage(),
    );
    await tester.tap(find.text('Example'));
    await tester.pumpAndSettle();

    expect(find.byType(FushiWebBrowserPage), findsOneWidget);
    expect(byKey('stub-webview'), findsOneWidget);
    final Rect bar = tester.getRect(byKey('web-browser-toolbar'));
    expect(bar.left, greaterThanOrEqualTo(0));
    expect(bar.right, lessThanOrEqualTo(360));
    expect(bar.bottom, lessThanOrEqualTo(780));
    expect(
      tester.getRect(byKey('stub-webview')).bottom,
      lessThanOrEqualTo(bar.top),
      reason: '底栏不叠在网页上：WebView 内容拿不到底部让位',
    );
    expect(byKey('web-browser-tab-count'), findsOneWidget);
    expect(byKey('web-browser-sidebar'), findsNothing);

    // 平时显示「域名加粗」的地址；点一下才是网址键盘的输入框。
    expect(byKey('web-browser-address-display'), findsOneWidget);
    await tester.tap(byKey('web-browser-address'));
    await tester.pumpAndSettle();
    final EditableText address = tester.widget<EditableText>(
      find.descendant(
        of: byKey('web-browser-address'),
        matching: find.byType(EditableText),
      ),
    );
    expect(address.controller.text, 'https://example.com/');
    expect(address.keyboardType, TextInputType.url);
    expect(address.autocorrect, isFalse);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 没有网页历史：工具栏后退直接离开浏览页（桌面没有系统返回键）。
    await tester.tap(byKey('web-browser-back'));
    await tester.pumpAndSettle();
    expect(find.byType(FushiWebBrowserPage), findsNothing);
    expect(find.text('Example'), findsOneWidget);
  });

  testWidgets('手机横屏：顶栏在网页上方，默认侧边栏样式是盖在网页上的抽屉', (WidgetTester tester) async {
    await pumpBrowser(tester, const Size(844, 390));
    final Rect web = tester.getRect(byKey('stub-webview'));
    final Rect bar = tester.getRect(byKey('web-browser-toolbar'));
    expect(bar.bottom, lessThanOrEqualTo(web.top));
    expect(web.bottom, 390, reason: '底部不留工具栏');
    expect(byKey('web-browser-sidebar-toggle'), findsOneWidget);
    expect(byKey('web-browser-tab-count'), findsNothing, reason: '宽窗口没有标签数按钮');

    await tester.tap(byKey('web-browser-sidebar-toggle'));
    await tester.pumpAndSettle();
    expect(tester.getRect(byKey('web-browser-sidebar').last).left, 0);
    expect(
      tester.getRect(byKey('stub-webview')).left,
      0,
      reason: '抽屉盖在网页上，不挤压网页',
    );
    await tester.tapAt(const Offset(700, 300));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(byKey('web-browser-sidebar').last).right,
      lessThanOrEqualTo(0),
      reason: '点 scrim 关抽屉',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面：默认侧边栏挤开网页；⋯ 菜单项齐全；切到顶部标签栏立即生效并记住', (
    WidgetTester tester,
  ) async {
    await pumpBrowser(tester, const Size(1280, 720));
    expect(byKey('web-browser-sidebar'), findsOneWidget);
    expect(
      tester.getRect(byKey('stub-webview')).left,
      greaterThanOrEqualTo(260),
      reason: '桌面侧边栏挤开网页',
    );
    final WebBrowserTab tab = page(tester).tabsController.activeTab!;
    expect(byKey('web-browser-sidebar-tab-${tab.id}'), findsOneWidget);

    await tester.tap(byKey('web-browser-more'));
    await tester.pumpAndSettle();
    for (final String label in <String>[
      t.web_browser_tab_new,
      t.web_browser_menu_history,
      t.web_browser_menu_bookmarks,
      t.web_browser_menu_downloads,
      t.web_browser_find_hint,
      t.share,
      t.web_browser_link_copy,
      t.web_browser_menu_open_external,
      t.web_browser_menu_desktop_site,
      t.web_browser_menu_text_size,
      t.web_browser_tab_style,
      t.web_browser_menu_settings,
    ]) {
      expect(find.text(label), findsWidgets, reason: '菜单里应有「$label」');
    }
    // 菜单比 720 高的窗口长，「标签页样式」在下半截：先滚进视野。
    await tester.ensureVisible(find.text(t.web_browser_tab_style_top).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.web_browser_tab_style_top).last);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(webBrowserTabStyle(appModel.prefsRepo), WebBrowserTabStyle.topStrip);
    expect(
      byKey('web-browser-sidebar-toggle'),
      findsNothing,
      reason: '顶部标签栏模式下侧边栏开关隐藏',
    );
    expect(byKey('web-browser-strip-tab-${tab.id}'), findsOneWidget);
    expect(byKey('web-browser-bookmarks'), findsOneWidget, reason: '书签移到顶栏按钮');
    expect(tester.getRect(byKey('stub-webview')).left, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面自绘标题栏：顶部标签栏并进标题行、与窗口按钮同一行；退出按钮一键回到入口', (
    WidgetTester tester,
  ) async {
    final List<String> windowCalls = <String>[];
    const MethodChannel windowManager = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowManager,
      (MethodCall call) async {
        windowCalls.add(call.method);
        return call.method.startsWith('is') ? false : null;
      },
    );
    final TargetPlatform Function() savedHost =
        FushiDesktopTitleBar.debugHostPlatform;
    FushiDesktopTitleBar.debugIsEnabled = true;
    FushiDesktopTitleBar.debugHostPlatform = () => TargetPlatform.windows;
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowManager,
        null,
      );
      FushiDesktopTitleBar.debugIsEnabled = false;
      FushiDesktopTitleBar.debugHostPlatform = savedHost;
    });
    await setWebBrowserTabStyle(
      appModel.prefsRepo,
      WebBrowserTabStyle.topStrip,
    );

    const Size size = Size(1280, 720);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: TranslationProvider(
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) =>
                FushiDesktopTitleBar(
                  title: const SizedBox.shrink(),
                  child: child!,
                ),
            home: const FushiWebBrowserHomePage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Example'));
    await tester.pumpAndSettle();
    expect(find.byType(FushiWebBrowserPage), findsOneWidget);

    // 标签栏占标题栏那一行：标签与窗口按钮竖向重叠，地址栏紧贴其下，中间不再
    // 空着一整条标题行。
    final WebBrowserTab tab = page(tester).tabsController.activeTab!;
    final Rect stripTab = tester.getRect(
      byKey('web-browser-strip-tab-${tab.id}'),
    );
    final Rect close = tester.getRect(
      find.byKey(FushiDesktopTitleBar.closeButtonKey),
    );
    expect(stripTab.top, lessThan(FushiDesktopTitleBar.height));
    expect(stripTab.bottom, greaterThan(close.top));
    expect(
      tester.getRect(byKey('web-browser-toolbar')).top,
      lessThanOrEqualTo(kWebBrowserTabStripHeight),
      reason: '地址栏直接接在标题行（标签栏）下面',
    );
    // 标签栏让开右侧窗口按钮组。
    final Rect add = tester.getRect(byKey('web-browser-strip-new-tab'));
    expect(add.right, lessThan(close.left - 100));
    expect(FushiDesktopTitleBar.captionPassthrough.value, isTrue);

    // 标题行里的标签栏真能点（标题栏不再把这段整条吞成拖动区）……
    await tester.tap(byKey('web-browser-strip-new-tab'));
    await tester.pumpAndSettle();
    expect(page(tester).tabsController.length, 2);
    // ……空白处仍能拖窗，窗口按钮照常可用。
    await tester.drag(byKey('web-browser-strip-drag'), const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(windowCalls, contains('startDragging'));
    await tester.tap(find.byKey(FushiDesktopTitleBar.closeButtonKey));
    await tester.pumpAndSettle();
    expect(windowCalls, contains('close'));

    // 退出按钮不走网页后退阶梯，一键离开浏览页；标题行交还给整条拖动区。
    await tester.tap(byKey('web-browser-exit'));
    await tester.pumpAndSettle();
    expect(find.byType(FushiWebBrowserPage), findsNothing);
    expect(find.text('Example'), findsOneWidget);
    expect(FushiDesktopTitleBar.captionPassthrough.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('⋯ 菜单里有「退出浏览器」，点了直接回到入口页', (WidgetTester tester) async {
    await pumpApp(
      tester,
      const Size(360, 780),
      const FushiWebBrowserHomePage(),
    );
    await tester.tap(find.text('Example'));
    await tester.pumpAndSettle();
    await tester.tap(byKey('web-browser-more'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(t.web_browser_exit).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.web_browser_exit).last);
    await tester.pumpAndSettle();
    expect(find.byType(FushiWebBrowserPage), findsNothing);
    expect(find.text('Example'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('标签区域右键菜单：改样式 / 关闭其他 / 重开', (WidgetTester tester) async {
    await pumpBrowser(tester, const Size(1280, 720));
    final FushiWebBrowserPageState state = page(tester);
    state.runShortcut(ShortcutAction.webBrowserNewTab);
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(state.tabsController.length, 2);
    final WebBrowserTab first = state.tabsController.tabs.first;
    await tester.tapAt(
      tester.getCenter(byKey('web-browser-sidebar-tab-${first.id}')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text(t.web_browser_tab_style_use_top), findsOneWidget);
    expect(find.text(t.web_browser_tab_reopen_closed), findsOneWidget);
    await tester.tap(find.text(t.web_browser_tab_close_others));
    await tester.pumpAndSettle();
    expect(state.tabsController.tabs, <WebBrowserTab>[first]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('竖屏标签数按钮：新建后变 2，打开网格、选卡片回到网页', (WidgetTester tester) async {
    await pumpBrowser(tester, const Size(390, 844));
    Finder count(String n) => find.descendant(
      of: byKey('web-browser-tab-count'),
      matching: find.text(n),
    );
    expect(count('1'), findsOneWidget);
    final FushiWebBrowserPageState state = page(tester);
    state.runShortcut(ShortcutAction.webBrowserNewTab);
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(count('2'), findsOneWidget);

    await tester.tap(byKey('web-browser-tab-count'));
    await tester.pumpAndSettle();
    expect(byKey('web-browser-tab-grid'), findsOneWidget);
    final WebBrowserTab first = state.tabsController.tabs.first;
    await tester.tap(byKey('web-browser-grid-tab-${first.id}'));
    await tester.pumpAndSettle();
    expect(byKey('web-browser-tab-grid'), findsNothing);
    expect(state.tabsController.activeTab, first);
    expect(byKey('stub-webview'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('快捷键动作：切换 / 文字大小 / 关闭 / 重开', (WidgetTester tester) async {
    await pumpBrowser(tester, const Size(1280, 720));
    final FushiWebBrowserPageState state = page(tester);
    state.runShortcut(ShortcutAction.webBrowserNewTab);
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    final WebBrowserTab second = state.tabsController.activeTab!;
    state.runShortcut(ShortcutAction.webBrowserPreviousTab);
    expect(state.tabsController.activeIndex, 0);
    state.runShortcut(ShortcutAction.webBrowserNextTab);
    expect(state.tabsController.activeTab, second);
    state.runShortcut(ShortcutAction.webBrowserPreviousTab);
    state.runShortcut(ShortcutAction.webBrowserZoomIn);
    expect(state.tabsController.activeTab!.textZoom, 110);
    state.runShortcut(ShortcutAction.webBrowserZoomReset);
    expect(state.tabsController.activeTab!.textZoom, 100);
    state.runShortcut(ShortcutAction.webBrowserCloseTab);
    await tester.pumpAndSettle();
    expect(state.tabsController.length, 1);
    state.runShortcut(ShortcutAction.webBrowserReopenClosedTab);
    await tester.pumpAndSettle();
    expect(state.tabsController.length, 2);
    expect(
      state.tabsController.activeTab!.url,
      Uri.parse('https://example.com/'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('恢复上次的标签页：会话里的页排在前面，只有前台页建 WebView', (WidgetTester tester) async {
    await store.saveSession(
      WebBrowserSession(
        tabs: <WebBrowserSessionTab>[
          WebBrowserSessionTab(
            id: 'old',
            url: Uri.parse('https://old.example/'),
            title: 'Old',
          ),
        ],
        activeTabId: 'old',
      ),
    );
    await pumpBrowser(tester, const Size(1280, 720));
    final FushiWebBrowserPageState state = page(tester);
    expect(state.tabsController.tabs.map((WebBrowserTab t) => t.url), <Uri>[
      Uri.parse('https://old.example/'),
      Uri.parse('https://example.com/'),
    ]);
    expect(
      state.tabsController.activeTab!.url,
      Uri.parse('https://example.com/'),
    );
    expect(
      state.tabsController.isLive(state.tabsController.tabs.first),
      isFalse,
    );
    expect(
      byKey('web-browser-sidebar-tab-old'),
      findsOneWidget,
      reason: '侧边栏列出恢复的标签页',
    );
  });

  testWidgets('设置联动：默认桌面版作用于新标签页；往下滚收成小地址条、点一下展开', (WidgetTester tester) async {
    await setWebBrowserDesktopModeDefault(appModel.prefsRepo, true);
    await pumpBrowser(tester, const Size(390, 844));
    final FushiWebBrowserPageState state = page(tester);
    final WebBrowserTab tab = state.tabsController.activeTab!;
    expect(tab.desktopMode, isTrue);

    state.onContentScrolled(tab, y: 200, dy: 120);
    await tester.pumpAndSettle();
    expect(byKey('web-browser-mini-bar'), findsOneWidget);
    expect(byKey('web-browser-toolbar'), findsNothing);
    await tester.tap(byKey('web-browser-mini-bar'));
    await tester.pumpAndSettle();
    expect(byKey('web-browser-toolbar'), findsOneWidget);

    await setWebBrowserCollapseOnScroll(appModel.prefsRepo, false);
    state.onContentScrolled(tab, y: 400, dy: 120);
    await tester.pumpAndSettle();
    expect(
      byKey('web-browser-mini-bar'),
      findsNothing,
      reason: '关掉「滚动时收起工具栏」后不收',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('window.open 新窗口：Android 发起时没有地址也照常建 WebView 接走 windowId，不弹地址栏', (
    WidgetTester tester,
  ) async {
    await pumpBrowser(tester, const Size(390, 844));
    final FushiWebBrowserPageState state = page(tester);
    final WebBrowserTab opener = state.tabsController.activeTab!;
    final WebBrowserTab popup = state.openTab(
      null,
      openerId: opener.id,
      windowId: 7,
    );
    await tester.pumpAndSettle();
    expect(state.tabsController.activeTab, popup);
    expect(popup.url, isNull);
    expect(
      byKey('web-browser-start-${popup.id}'),
      findsNothing,
      reason: '带 windowId 的页不能画起始页（平台侧挂着的新窗口没人认领）',
    );
    expect(find.text('page null'), findsOneWidget, reason: '新窗口的 WebView 已建');
    Finder addressEditor() => find.descendant(
      of: byKey('web-browser-address'),
      matching: find.byType(EditableText),
    );
    expect(addressEditor(), findsNothing, reason: '网页自己开的窗口不进地址栏编辑、不弹键盘');

    // 页面加载后 WebView 回填地址，照常显示网页。
    popup.update(url: Uri.parse('https://popup.example/'));
    await tester.pumpAndSettle();
    expect(find.text('page https://popup.example/'), findsOneWidget);

    // 用户自己新建的空白页仍是起始页 + 地址栏编辑。
    final WebBrowserTab blank = state.openTab(null);
    await tester.pumpAndSettle();
    expect(byKey('web-browser-start-${blank.id}'), findsOneWidget);
    expect(addressEditor(), findsOneWidget, reason: '用户新建的空白页进地址栏编辑');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('竖屏弹软键盘：底栏（地址栏）让到键盘上方，网页区域变矮而不被盖住', (WidgetTester tester) async {
    await pumpBrowser(tester, const Size(390, 844));
    await tester.tap(byKey('web-browser-address'));
    await tester.pumpAndSettle();
    // 键盘开合不得重挂标签页（真机上重挂 = InAppWebView 重建、网页重载、表单输入丢失）。
    final Element webBefore = tester.element(byKey('stub-webview'));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    final Rect bar = tester.getRect(byKey('web-browser-toolbar'));
    expect(bar.bottom, lessThanOrEqualTo(844 - 300), reason: '底栏在键盘上方');
    expect(bar.top, greaterThan(0));
    final Rect web = tester.getRect(byKey('stub-webview'));
    expect(web.bottom, lessThanOrEqualTo(bar.top), reason: '网页不叠在底栏下');
    expect(web.height, greaterThan(0));
    expect(
      find.descendant(
        of: byKey('web-browser-address'),
        matching: find.byType(EditableText),
      ),
      findsOneWidget,
      reason: '弹键盘不收起地址栏编辑',
    );

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(
      tester.getRect(byKey('web-browser-toolbar')).bottom,
      844,
      reason: '收起键盘底栏回到底部',
    );
    expect(
      identical(tester.element(byKey('stub-webview')), webBefore),
      isTrue,
      reason: '键盘开合前后网页是同一个元素，没有被卸载重挂',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final Size size in <Size>[const Size(390, 844), const Size(1280, 800)]) {
    testWidgets('网页全屏进出不重挂标签页（${size.width.toInt()} 宽）', (
      WidgetTester tester,
    ) async {
      // 回归：手机竖屏全屏时网页区所在的列首尾同时增删子节点，不带 key 的网页区
      // 被卸载重挂——真机上 InAppWebView 销毁重建（页面重载），原生全屏视图冻结 /
      // 白屏盖在 app 上退不出来。
      await pumpBrowser(tester, size);
      final FushiWebBrowserPageState state = page(tester);
      final WebBrowserTab tab = state.tabsController.activeTab!;
      final Element webBefore = tester.element(byKey('stub-webview'));
      expect(byKey('web-browser-toolbar'), findsOneWidget);

      state.onFullscreenChanged(tab, fullscreen: true);
      await tester.pumpAndSettle();
      expect(byKey('web-browser-toolbar'), findsNothing, reason: '全屏收起 chrome');
      expect(
        tester.getRect(byKey('stub-webview')),
        Offset.zero & size,
        reason: '网页占满整屏',
      );
      expect(
        identical(tester.element(byKey('stub-webview')), webBefore),
        isTrue,
      );

      state.onFullscreenChanged(tab, fullscreen: false);
      await tester.pumpAndSettle();
      expect(
        byKey('web-browser-toolbar'),
        findsOneWidget,
        reason: '退出恢复 chrome',
      );
      expect(
        identical(tester.element(byKey('stub-webview')), webBefore),
        isTrue,
        reason: '全屏进出前后网页是同一个元素，没有被卸载重挂',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('标签页网格有普通「新标签页」按钮（Android 不支持无痕时也能新建）', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpBrowser(tester, const Size(390, 844));
      final FushiWebBrowserPageState state = page(tester);
      await tester.tap(byKey('web-browser-tab-count'));
      await tester.pumpAndSettle();
      expect(byKey('web-browser-tab-grid'), findsOneWidget);
      expect(
        byKey('web-browser-grid-new-incognito'),
        findsNothing,
        reason: 'Android 不支持无痕',
      );
      await tester.tap(byKey('web-browser-grid-new-tab'));
      await tester.pumpAndSettle();
      expect(state.tabsController.length, 2);
      expect(byKey('web-browser-tab-grid'), findsNothing, reason: '新建后回到新页');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('浏览页抵消全局界面缩放：路由整页包在中和层里，网页按真实视口排版', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(411, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // 与 app 根一致：缩放层包在 Navigator 外，推出来的路由同样处在缩放画布里。
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: TranslationProvider(
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) =>
                FushiAppUiScale(scale: 1.12, child: child!),
            home: const FushiWebBrowserHomePage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      MediaQuery.sizeOf(
        tester.element(find.byType(FushiWebBrowserHomePage)),
      ).width,
      lessThan(400),
      reason: '前提：入口页在缩小后的画布里',
    );
    await tester.tap(find.text('Example'));
    await tester.pumpAndSettle();
    expect(
      find.ancestor(
        of: find.byType(FushiWebBrowserPage),
        matching: find.byType(FushiAppUiScaleNeutralizer),
      ),
      findsOneWidget,
    );
    final BuildContext pageContext = tester.element(
      find.byType(FushiWebBrowserPage),
    );
    expect(FushiAppUiScale.of(pageContext), FushiAppUiScale.defaultScale);
    expect(MediaQuery.sizeOf(pageContext).width, closeTo(411, 0.01));
    expect(tester.takeException(), isNull);
  });
}
