import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';
import 'package:fushi/src/pages/implementations/home_game_page.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

import '../../integration_test/helpers/focus_driver.dart';

Widget _testLibrary(
  BuildContext _,
  GalHookSessionController __,
  VoidCallback ___,
) => const Center(child: Icon(Icons.sports_esports_outlined));

/// 新增游戏首页（dashboard）后，游戏模块默认停在首页；这些针对库/工作台/诊断的
/// 断言仍要在「库」子区上验证。用桩 dashboard 绕开首页对 appProvider 的依赖，并在
/// setUp 里把 IndexedStack 起始子区切到库（与旧默认行为等价）。
Widget _stubDashboard(BuildContext _, VoidCallback __) => const SizedBox();

Widget _stubDiscover(BuildContext _, Widget navigation) =>
    Column(children: <Widget>[navigation, const Text('game-discover')]);

int _streamBuilds = 0;

Widget _stubStream(BuildContext _, Widget navigation) {
  _streamBuilds++;
  return Column(children: <Widget>[navigation, const Text('game-stream')]);
}

Widget _testMonitorWithSections(BuildContext _, VoidCallback onShowLibrary) {
  return FushiPageHeader.customTitle(
    title: GameSectionTabs(
      selected: GameSection.monitor,
      focusIdPrefix: 'game-capture-tab',
      onSelectDashboard: () =>
          gameSectionNotifier.value = GameSection.dashboard,
      onSelectLibrary: onShowLibrary,
      onSelectMonitor: () {},
    ),
  );
}

Future<void> _settleOnLibrary(WidgetTester tester) async {
  // Flutter 测试在下一例首帧才销毁上一例的 HomeGamePage；它的 dispose 会把全局
  // section 回落到 dashboard。首帧后再选库，避免测试顺序影响初始子页。
  gameSectionNotifier.value = GameSection.library;
  await tester.pump();
}

void main() {
  setUp(() {
    TexthookerService.instance.clear();
    gameSectionNotifier.value = GameSection.library;
  });
  tearDown(() {
    TexthookerService.instance.clear();
    gameSectionNotifier.value = GameSection.dashboard;
  });

  testWidgets('library shows real capture count and true empty state', (
    WidgetTester tester,
  ) async {
    TexthookerService.instance.appendLine('テスト台詞');
    await tester.pumpWidget(
      MaterialApp(
        home: HomeGamePage(
          monitorBuilder: (_, __) => const SizedBox(),
          libraryBuilder: _testLibrary,
          dashboardBuilder: _stubDashboard,
          discoverBuilder: _stubDiscover,
          streamBuilder: _stubStream,
        ),
      ),
    );
    await _settleOnLibrary(tester);

    expect(find.textContaining('1'), findsWidgets);
    expect(find.text('テスト台詞'), findsOneWidget);
    expect(find.byIcon(Icons.sports_esports_outlined), findsWidgets);
  });

  testWidgets('BUG-3928: game exit returns the workbench to the dashboard', (
    WidgetTester tester,
  ) async {
    final ChangeNotifier endpoints = ChangeNotifier();
    final GalHookSessionController controller = GalHookSessionController(
      textService: TexthookerService.test(),
      isWindows: false,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );
    // 不走 close()：它的异步收尾在 widget 测试的假时钟里不会推进。会话从没启动，
    // 这里只需释放监听。
    addTearDown(() {
      controller.dispose();
      endpoints.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: HomeGamePage(
          controller: controller,
          monitorBuilder: (_, __) => const Text('monitor-session'),
          libraryBuilder: _testLibrary,
          dashboardBuilder: _stubDashboard,
          discoverBuilder: _stubDiscover,
          streamBuilder: _stubStream,
        ),
      ),
    );
    gameSectionNotifier.value = GameSection.monitor;
    await tester.pump();
    expect(find.text('monitor-session'), findsOneWidget);

    controller.debugNotifyGameExited();
    await tester.pumpAndSettle();
    expect(gameSectionNotifier.value, GameSection.dashboard);

    // 用户在别的子区时不被拉走。
    gameSectionNotifier.value = GameSection.library;
    await tester.pumpAndSettle();
    controller.debugNotifyGameExited();
    await tester.pumpAndSettle();
    expect(gameSectionNotifier.value, GameSection.library);
  });

  testWidgets('monitor state survives library/workbench switches', (
    WidgetTester tester,
  ) async {
    int initCount = 0;
    int disposeCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: HomeGamePage(
          libraryBuilder: _testLibrary,
          dashboardBuilder: _stubDashboard,
          discoverBuilder: _stubDiscover,
          streamBuilder: _stubStream,
          monitorBuilder: (_, VoidCallback onShowLibrary) => _TestMonitor(
            onShowLibrary: onShowLibrary,
            onInit: () => initCount++,
            onDispose: () => disposeCount++,
          ),
        ),
      ),
    );
    await _settleOnLibrary(tester);

    expect(initCount, 1, reason: 'IndexedStack 在模块存活期只挂载一个工作台 State');
    await tester.ensureVisible(find.byKey(HomeGamePage.captureStatusKey));
    await tester.tap(find.byKey(HomeGamePage.captureStatusKey));
    await tester.pump();
    expect(find.text('monitor-session'), findsOneWidget);

    await tester.tap(find.byKey(_TestMonitor.backKey));
    await tester.pump();
    expect(disposeCount, 0, reason: '返回游戏库只能 Offstage，不能停止 Hook 会话');

    await tester.ensureVisible(find.byKey(HomeGamePage.captureStatusKey));
    await tester.tap(find.byKey(HomeGamePage.captureStatusKey));
    await tester.pump();
    expect(initCount, 1);
    expect(disposeCount, 0);
  });

  testWidgets('800x600 top tabs carry neither diagnostics nor settings', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: FushiFocusRoot(
          child: HomeGamePage(
            monitorBuilder: _testMonitorWithSections,
            libraryBuilder: _testLibrary,
            dashboardBuilder: _stubDashboard,
            discoverBuilder: _stubDiscover,
            streamBuilder: _stubStream,
          ),
        ),
      ),
    );
    await _settleOnLibrary(tester);

    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.byType(HomeGamePage)),
    );
    // 2026-10-30 起两级页签：一级「游戏库 / 发现」，「游戏库」组内的首页 /
    // 全部游戏 / 工作台 / 串流在顶栏下方的二级胶囊里；导入是工具栏右端的圆钮。
    final Finder gameSections = find.byType(
      FushiAdjustableSegmented<GameSection>,
    );
    expect(gameSections, findsNWidgets(2), reason: '一级 + 二级各一份');
    expect(find.text(t.game_library), findsOneWidget, reason: '一级「游戏库」组');
    expect(find.text(t.library_view_discover), findsOneWidget);
    expect(find.text(t.game_dashboard), findsOneWidget);
    expect(find.text(t.game_library_all), findsOneWidget);
    expect(find.text(t.game_capture_workbench_tab), findsOneWidget);
    expect(
      find.text(t.library_view_import),
      findsNothing,
      reason: '导入不再是页签（只在圆钮 tooltip 里）',
    );
    expect(
      controller.requestById(
        const FushiFocusId('game-subsection-tab-sections'),
      ),
      isTrue,
    );
    await _settleOnLibrary(tester);
    expect(
      controller.primaryFocusIsManagedTarget,
      isTrue,
      reason: '不能仅改 activeId；真实 Flutter 焦点必须落在分段目标',
    );

    final FocusDriver driver = FocusDriver(tester);
    // 二级胶囊里库后一位是「捕获」。
    await driver.adjust(steps: 1);
    expect(find.byKey(HomeGamePage.monitorKey), findsOneWidget);

    expect(
      controller.requestById(
        const FushiFocusId('game-subsection-tab-sections'),
      ),
      isTrue,
      reason: '切到捕获页后，二级胶囊的稳定分段 ID 仍可聚焦',
    );
    await tester.pump();
    expect(controller.primaryFocusIsManagedTarget, isTrue);
    await driver.adjust(steps: 1);

    // 捕获之后是「串流」（把别的主机上的游戏串流到本机）。
    expect(find.text('game-stream'), findsOneWidget);
    // 一级页签的稳定 ID 沿用各子区原来那份（串流 = game-stream-tab）。
    expect(
      controller.requestById(const FushiFocusId('game-stream-tab-sections')),
      isTrue,
      reason: '切到串流页后，一级分段的稳定 ID 必须可聚焦',
    );
    await tester.pump();
    await driver.adjust(steps: 1);

    // 一级「游戏库」之后是「发现」。
    expect(find.text('game-discover'), findsOneWidget);
    expect(
      controller.requestById(const FushiFocusId('game-discover-tab-sections')),
      isTrue,
      reason: '切到发现页后，新的稳定分段 ID 必须可聚焦',
    );
    await tester.pump();
    expect(
      find.byType(FushiAdjustableSegmented<GameSection>),
      findsOneWidget,
      reason: '发现组只有一段，不画二级胶囊',
    );

    // 2026-08-13 入库入口统一：「导入」视图；2026-10-30 起它不再是页签，而是
    // 工具栏右端的切换型圆钮（与书 / 漫画 / 视频库页同构）。
    final Finder importButton = find.byKey(
      const ValueKey<String>('game-library-view-import'),
    );
    expect(tester.widget<FushiIconButton>(importButton).selected, isFalse);
    tester.widget<FushiIconButton>(importButton).onTap!();
    await tester.pump();
    expect(find.byKey(HomeGamePage.importKey), findsOneWidget);
    expect(tester.widget<FushiIconButton>(importButton).selected, isTrue);
    expect(
      controller.requestById(const FushiFocusId('game-import-tab-sections')),
      isTrue,
      reason: '停在导入页时一级分段仍在、稳定 ID 必须可聚焦',
    );
    // 再点一次回到进导入页之前的「发现」。
    tester.widget<FushiIconButton>(importButton).onTap!();
    await tester.pump();
    expect(gameSectionNotifier.value, GameSection.discover);
    expect(
      kGameSectionTabOrder.last,
      GameSection.importGames,
      reason: '模块内「设置」页签已移除（设置走全局「设置 › 游戏」），导入排末位',
    );
    expect(
      find.text(t.game_diagnostics),
      findsNothing,
      reason: '兼容性诊断不得继续占用游戏顶部高频页签',
    );

    // 诊断能力保留给捕获工作台 / 全局设置导航：程序化入口能进入详情。
    gameSectionNotifier.value = GameSection.diagnostics;
    await tester.pump();
    expect(find.byKey(HomeGamePage.diagnosticsKey), findsOneWidget);
    // 诊断页分段卡片的行首形状图标（M3E：FushiIcons 语义名）。
    expect(find.byIcon(FushiIcons.hub), findsOneWidget);
    expect(find.byIcon(FushiIcons.audio), findsOneWidget);
  });

  testWidgets('game tabs participate in managed focus navigation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FushiFocusRoot(
          child: HomeGamePage(
            libraryBuilder: _testLibrary,
            dashboardBuilder: _stubDashboard,
            discoverBuilder: _stubDiscover,
            streamBuilder: _stubStream,
            monitorBuilder: (_, __) => const Text('focused-monitor'),
          ),
        ),
      ),
    );
    await tester.pump();

    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.byType(HomeGamePage)),
    );
    // 首页 / 全部游戏 / 工作台 / 串流在「游戏库」组的二级胶囊里。
    expect(
      controller.requestById(
        const FushiFocusId('game-subsection-tab-sections'),
      ),
      isTrue,
    );
    await tester.pump();
    // 库 → 捕获。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(find.text('focused-monitor'), findsOneWidget);
  });

  for (final Size size in <Size>[const Size(420, 760), const Size(1280, 800)]) {
    testWidgets('game library lays out at ${size.width.toInt()}px', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: HomeGamePage(
            monitorBuilder: (_, __) => const SizedBox(),
            libraryBuilder: _testLibrary,
            dashboardBuilder: _stubDashboard,
            discoverBuilder: _stubDiscover,
            streamBuilder: _stubStream,
          ),
        ),
      );
      await _settleOnLibrary(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(HomeGamePage.libraryKey), findsOneWidget);
    });
  }

  testWidgets('Windows reaches the stream receiver from its own tab, lazily', (
    WidgetTester tester,
  ) async {
    _streamBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FushiFocusRoot(
          child: HomeGamePage(
            monitorBuilder: _testMonitorWithSections,
            libraryBuilder: _testLibrary,
            dashboardBuilder: _stubDashboard,
            discoverBuilder: _stubDiscover,
            streamBuilder: _stubStream,
          ),
        ),
      ),
    );
    await _settleOnLibrary(tester);
    // Building it would reach out to every paired host.
    expect(_streamBuilds, 0);
    expect(kGameSectionTabOrder, contains(GameSection.stream));

    gameSectionNotifier.value = GameSection.stream;
    await tester.pumpAndSettle();
    expect(_streamBuilds, greaterThan(0));
    expect(find.text('game-stream'), findsOneWidget);
  });
}

class _TestMonitor extends StatefulWidget {
  const _TestMonitor({
    required this.onShowLibrary,
    required this.onInit,
    required this.onDispose,
  });

  static const Key backKey = ValueKey<String>('test-monitor-back');

  final VoidCallback onShowLibrary;
  final VoidCallback onInit;
  final VoidCallback onDispose;

  @override
  State<_TestMonitor> createState() => _TestMonitorState();
}

class _TestMonitorState extends State<_TestMonitor> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const Text('monitor-session'),
        IconButton(
          key: _TestMonitor.backKey,
          onPressed: widget.onShowLibrary,
          icon: const Icon(Icons.arrow_back),
        ),
      ],
    );
  }
}
