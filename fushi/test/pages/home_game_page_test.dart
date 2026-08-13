import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';
import 'package:fushi/src/pages/implementations/home_game_page.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/utils.dart';

import '../../integration_test/helpers/focus_driver.dart';

Widget _testLibrary(
  BuildContext _,
  GalHookSessionController __,
  VoidCallback ___,
) =>
    const Center(child: Icon(Icons.sports_esports_outlined));

/// 新增游戏首页（dashboard）后，游戏模块默认停在首页；这些针对库/工作台/诊断的
/// 断言仍要在「库」子区上验证。用桩 dashboard 绕开首页对 appProvider 的依赖，并在
/// setUp 里把 IndexedStack 起始子区切到库（与旧默认行为等价）。
Widget _stubDashboard(BuildContext _, VoidCallback __) => const SizedBox();

Widget _stubSettings(BuildContext _, Widget navigation) => Column(
      children: <Widget>[
        navigation,
        const Text('game-settings'),
      ],
    );

Widget _testMonitorWithSections(
  BuildContext _,
  VoidCallback onShowLibrary,
) {
  return FushiPageHeader.customTitle(
    title: GameSectionTabs(
      selected: GameSection.monitor,
      focusIdPrefix: 'game-capture-tab',
      onSelectDashboard: () =>
          gameSectionNotifier.value = GameSection.dashboard,
      onSelectLibrary: onShowLibrary,
      onSelectMonitor: () {},
      onSelectSettings: () => gameSectionNotifier.value = GameSection.settings,
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

  testWidgets('library shows real capture count and true empty state',
      (WidgetTester tester) async {
    TexthookerService.instance.appendLine('テスト台詞');
    await tester.pumpWidget(
      MaterialApp(
        home: HomeGamePage(
          monitorBuilder: (_, __) => const SizedBox(),
          libraryBuilder: _testLibrary,
          dashboardBuilder: _stubDashboard,
          settingsBuilder: _stubSettings,
        ),
      ),
    );
    await _settleOnLibrary(tester);

    expect(find.textContaining('1'), findsWidgets);
    expect(find.text('テスト台詞'), findsOneWidget);
    expect(find.byIcon(Icons.sports_esports_outlined), findsWidgets);
  });

  testWidgets('monitor state survives library/workbench switches',
      (WidgetTester tester) async {
    int initCount = 0;
    int disposeCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: HomeGamePage(
          libraryBuilder: _testLibrary,
          dashboardBuilder: _stubDashboard,
          settingsBuilder: _stubSettings,
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

  testWidgets('800x600 top tabs replace diagnostics with settings',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: FushiFocusRoot(
          child: HomeGamePage(
            monitorBuilder: _testMonitorWithSections,
            libraryBuilder: _testLibrary,
            dashboardBuilder: _stubDashboard,
            settingsBuilder: _stubSettings,
          ),
        ),
      ),
    );
    await _settleOnLibrary(tester);

    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.byType(HomeGamePage)),
    );
    final Finder gameSections =
        find.byType(FushiAdjustableSegmented<GameSection>);
    expect(gameSections, findsOneWidget);
    expect(find.text(t.game_dashboard), findsOneWidget);
    expect(find.text(t.game_library), findsOneWidget);
    expect(find.text(t.game_capture_workbench), findsOneWidget);
    expect(find.text(t.settings), findsOneWidget,
        reason: '800px 页头必须完整呈现首页、游戏库、捕获工作台、设置四个分段');
    expect(
      controller.requestById(
        const FushiFocusId('game-library-tab-sections'),
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
    await driver.adjust(steps: 1);
    expect(find.byKey(HomeGamePage.monitorKey), findsOneWidget);

    expect(
      controller.requestById(
        const FushiFocusId('game-capture-tab-sections'),
      ),
      isTrue,
      reason: '切到捕获页后，新的稳定分段 ID 必须可聚焦',
    );
    await tester.pump();
    expect(controller.primaryFocusIsManagedTarget, isTrue);
    await driver.adjust(steps: 1);

    // 2026-08-13 入库入口统一：捕获工作台与设置之间插入「导入」分段（与书 /
    // 漫画 / 视频库页的「导入在设置前一位」同构）。
    expect(find.byKey(HomeGamePage.importKey), findsOneWidget);
    expect(
      controller.requestById(
        const FushiFocusId('game-import-tab-sections'),
      ),
      isTrue,
      reason: '切到导入页后，新的稳定分段 ID 必须可聚焦',
    );
    await tester.pump();
    await driver.adjust(steps: 1);

    expect(find.byKey(HomeGamePage.settingsKey), findsOneWidget);
    expect(find.text('game-settings'), findsOneWidget);
    expect(find.text(t.game_diagnostics), findsNothing,
        reason: '兼容性诊断不得继续占用游戏顶部高频页签');

    // 诊断能力仍保留给设置页导航：程序化入口能进入详情，但顶部高亮设置。
    gameSectionNotifier.value = GameSection.diagnostics;
    await tester.pump();
    expect(find.byKey(HomeGamePage.diagnosticsKey), findsOneWidget);
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
    expect(find.byIcon(Icons.multitrack_audio_outlined), findsOneWidget);
  });

  testWidgets('game tabs participate in managed focus navigation',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FushiFocusRoot(
          child: HomeGamePage(
            libraryBuilder: _testLibrary,
            dashboardBuilder: _stubDashboard,
            settingsBuilder: _stubSettings,
            monitorBuilder: (_, __) => const Text('focused-monitor'),
          ),
        ),
      ),
    );
    await tester.pump();

    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.byType(HomeGamePage)),
    );
    expect(
      controller.requestById(
        const FushiFocusId('game-library-tab-sections'),
      ),
      isTrue,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(find.text('focused-monitor'), findsOneWidget);
  });

  for (final Size size in <Size>[const Size(420, 760), const Size(1280, 800)]) {
    testWidgets('game library lays out at ${size.width.toInt()}px',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: HomeGamePage(
            monitorBuilder: (_, __) => const SizedBox(),
            libraryBuilder: _testLibrary,
            dashboardBuilder: _stubDashboard,
            settingsBuilder: _stubSettings,
          ),
        ),
      );
      await _settleOnLibrary(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(HomeGamePage.libraryKey), findsOneWidget);
    });
  }
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
