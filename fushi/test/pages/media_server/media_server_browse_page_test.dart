import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_browse_page.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_home_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_server_list_view.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

import 'fake_media_server_browser.dart';

/// 分区页：服务器列表空态 / 单台直进首页（返回才见列表）/ 两台列出两张卡；
/// Escape 沿嵌套栈一层层退。
void main() {
  late FushiDatabase database;
  late int settingsOpened;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    settingsOpened = 0;
  });

  tearDown(() async {
    await database.close();
  });

  Widget harness(
    List<MediaServerEntry> servers, {
    bool systemBackActive = true,
    List<GamepadButton>? outerGamepad,
  }) {
    Widget page = MediaServerBrowsePage(
      navigation: const Text('nav-probe'),
      repo: VideoBookRepository(database),
      loadServers: () async => servers,
      onPlay: (BuildContext _, MediaServerPlayRequest __) {},
      onOpenSettings: () => settingsOpened++,
      systemBackActive: systemBackActive,
    );
    if (outerGamepad != null) {
      // 模拟 HomePage 那层 Actions（LT/RT 换 tab、Y 搜索都注册在那里）。
      page = Actions(
        actions: <Type, Action<Intent>>{
          GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
            onInvoke: (GamepadButtonIntent intent) {
              outerGamepad.add(intent.button);
              return true;
            },
          ),
        },
        child: page,
      );
    }
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          // 同一测试里换参数重新 pump 时强制重建 State（否则嵌套栈沿用上一次的）。
          body: KeyedSubtree(
            key: ValueKey<bool>(systemBackActive),
            child: page,
          ),
        ),
      ),
    );
  }

  FakeMediaServerBrowser fakeServer(String id, String name) {
    final FakeMediaServerBrowser b = FakeMediaServerBrowser(
      serverId: 'fake:$id',
      displayName: name,
      serverUrl: 'http://$id:8096',
    );
    b.libraries.add(
      MediaServerLibrary(
        id: '$id-lib',
        name: '$name 的库',
        kind: MediaServerLibraryKind.movies,
      ),
    );
    b.children['$id-lib'] = fakeMovies(1, prefix: '$id-movie');
    return b;
  }

  testWidgets('空态：提示 + 「去设置添加服务器」', (WidgetTester tester) async {
    await tester.pumpWidget(harness(const <MediaServerEntry>[]));
    await tester.pumpAndSettle();

    expect(find.text('nav-probe'), findsOneWidget, reason: '分区页签在页头');
    expect(find.text(t.media_server_servers_empty_hint), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-list-go-settings')),
    );
    await tester.pump();
    expect(settingsOpened, 1);
  });

  testWidgets('点服务器以二级页面打开：整页盖住分区页签，返回回到列表', (WidgetTester tester) async {
    final FakeMediaServerBrowser only = fakeServer('nas', 'NAS');
    await tester.pumpWidget(
      harness(<MediaServerEntry>[MediaServerEntry(browser: only)]),
    );
    await tester.pumpAndSettle();
    expect(find.text('nav-probe').hitTestable(), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-card-fake:nas')),
    );
    await tester.pumpAndSettle();
    // 2026-10-30 用户：「点击进去媒体服务器应该要是二级界面」——根导航器整页
    // push，分区页签不再叠在服务器页之上。
    expect(find.byType(MediaServerHomeView), findsOneWidget);
    expect(
      find.text('nav-probe').hitTestable(),
      findsNothing,
      reason: '二级页面盖住整页，包括分区页签',
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MediaServerHomeView), findsNothing);
    expect(find.text('nav-probe').hitTestable(), findsOneWidget);
  });

  testWidgets('单台：不自动进首页，列表露出那张卡；点进去才拉库', (WidgetTester tester) async {
    final FakeMediaServerBrowser only = fakeServer('nas', 'NAS');
    await tester.pumpWidget(
      harness(<MediaServerEntry>[
        MediaServerEntry(browser: only, accountName: 'alice'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MediaServerHomeView), findsNothing);
    expect(only.listLibrariesCalls, 0, reason: '没点进去一个请求都不发');
    expect(
      find.byKey(const ValueKey<String>('media-server-card-fake:nas')),
      findsOneWidget,
    );
    expect(find.text('alice'), findsOneWidget, reason: '卡片带账号');

    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-card-fake:nas')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MediaServerHomeView), findsOneWidget);
    expect(only.listLibrariesCalls, 1, reason: '首页真的开始拉库');
  });

  testWidgets('两台：列出两张卡，点一张进它的首页；返回退回列表', (WidgetTester tester) async {
    final FakeMediaServerBrowser a = fakeServer('a', 'Alpha');
    final FakeMediaServerBrowser b = fakeServer('b', 'Beta');
    await tester.pumpWidget(
      harness(<MediaServerEntry>[
        MediaServerEntry(browser: a),
        MediaServerEntry(browser: b),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MediaServerHomeView), findsNothing, reason: '多台不自动进');
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('http://b:8096'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-card-fake:b')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MediaServerHomeView), findsOneWidget);
    expect(b.listLibrariesCalls, 1);
    expect(a.listLibrariesCalls, 0, reason: '没点的那台一个请求都不发');
    expect(find.text('Beta 的库'), findsWidgets);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MediaServerHomeView), findsNothing, reason: '返回退出二级页面');
    expect(find.byType(MediaServerListView), findsOneWidget);
  });

  testWidgets('手柄：列表页上非返回键转发给祖先 Actions（不吞 LT/RT/Y）', (
    WidgetTester tester,
  ) async {
    final List<GamepadButton> outer = <GamepadButton>[];
    final FakeMediaServerBrowser only = fakeServer('nas', 'NAS');
    await tester.pumpWidget(
      harness(<MediaServerEntry>[
        MediaServerEntry(browser: only),
      ], outerGamepad: outer),
    );
    await tester.pumpAndSettle();

    final BuildContext inside = tester.element(
      find.byType(MediaServerListView),
    );
    Actions.maybeInvoke<GamepadButtonIntent>(
      inside,
      const GamepadButtonIntent(GamepadButton.y),
    );
    Actions.maybeInvoke<GamepadButtonIntent>(
      inside,
      const GamepadButtonIntent(GamepadButton.lt),
    );
    await tester.pumpAndSettle();
    expect(outer, <GamepadButton>[
      GamepadButton.y,
      GamepadButton.lt,
    ], reason: '非返回键必须到达 HomePage 那层，否则换 tab / 搜索在分区内失灵');
    expect(find.byType(MediaServerListView), findsOneWidget);
  });

  testWidgets('多线路：卡片出「切换线路」菜单，选另一条 → 回调 + 列表重取；单线路无入口', (
    WidgetTester tester,
  ) async {
    final FakeMediaServerBrowser a = fakeServer('a', 'Alpha');
    final FakeMediaServerBrowser b = fakeServer('b', 'Beta');
    final List<String> switched = <String>[];
    int loads = 0;
    // 切换后 loadServers 重取：Beta 换成按新线路建的浏览器。
    final FakeMediaServerBrowser bWan = FakeMediaServerBrowser(
      serverId: 'fake:b',
      displayName: 'Beta',
      serverUrl: 'https://b.example.com',
    );
    final Widget page = MediaServerBrowsePage(
      navigation: const Text('nav-probe'),
      repo: VideoBookRepository(database),
      loadServers: () async {
        loads++;
        return <MediaServerEntry>[
          MediaServerEntry(browser: a),
          MediaServerEntry(
            browser: switched.isEmpty ? b : bWan,
            routeUrls: const <String>['http://b:8096', 'https://b.example.com'],
            onSwitchRoute: (String url) async => switched.add(url),
          ),
        ];
      },
      onPlay: (BuildContext _, MediaServerPlayRequest __) {},
      onOpenSettings: () => settingsOpened++,
      systemBackActive: true,
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: Scaffold(body: page)),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('media-server-route-switch-fake:a')),
      findsNothing,
      reason: '单线路不出切换入口',
    );
    final Finder switcher = find.byKey(
      const ValueKey<String>('media-server-route-switch-fake:b'),
    );
    expect(switcher, findsOneWidget);

    await tester.tap(switcher);
    await tester.pumpAndSettle();
    expect(
      find.text('https://b.example.com'),
      findsOneWidget,
      reason: '菜单列出线路',
    );
    await tester.tap(find.text('https://b.example.com').last);
    await tester.pumpAndSettle();

    expect(switched, <String>['https://b.example.com']);
    expect(loads, 2, reason: '切换后列表重取');
    expect(
      find.text('https://b.example.com'),
      findsOneWidget,
      reason: '卡片显示新线路',
    );
    expect(find.text('http://b:8096'), findsNothing);
    expect(find.byType(MediaServerHomeView), findsNothing, reason: '切线路不进首页');
  });
}
