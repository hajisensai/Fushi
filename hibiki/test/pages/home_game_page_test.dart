import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/pages/implementations/home_game_page.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';

Widget _testLibrary(
  BuildContext _,
  GalHookSessionController __,
  VoidCallback ___,
) =>
    const Center(child: Icon(Icons.sports_esports_outlined));

void main() {
  setUp(() => TexthookerService.instance.clear());
  tearDown(() => TexthookerService.instance.clear());

  testWidgets('library shows real capture count and true empty state',
      (WidgetTester tester) async {
    TexthookerService.instance.appendLine('テスト台詞');
    await tester.pumpWidget(
      MaterialApp(
        home: HomeGamePage(
          monitorBuilder: (_, __) => const SizedBox(),
          libraryBuilder: _testLibrary,
        ),
      ),
    );
    await tester.pump();

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
          monitorBuilder: (_, VoidCallback onShowLibrary) => _TestMonitor(
            onShowLibrary: onShowLibrary,
            onInit: () => initCount++,
            onDispose: () => disposeCount++,
          ),
        ),
      ),
    );
    await tester.pump();

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

  testWidgets('library opens real diagnostics section via section tab',
      (WidgetTester tester) async {
    // 诊断总览大卡已删除，诊断页现只经顶部页签进入（焦点驱动激活，与 itest 一致）。
    await tester.pumpWidget(
      MaterialApp(
        home: HibikiFocusRoot(
          child: HomeGamePage(
            monitorBuilder: (_, __) => const SizedBox(),
            libraryBuilder: _testLibrary,
          ),
        ),
      ),
    );
    await tester.pump();

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(HomeGamePage)),
    );
    expect(
      controller.requestById(
        const HibikiFocusId('game-library-tab-diagnostics'),
      ),
      isTrue,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(find.byKey(HomeGamePage.diagnosticsKey), findsOneWidget);
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
    expect(find.byIcon(Icons.multitrack_audio_outlined), findsOneWidget);
  });

  testWidgets('game tabs participate in managed focus navigation',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HibikiFocusRoot(
          child: HomeGamePage(
            libraryBuilder: _testLibrary,
            monitorBuilder: (_, __) => const Text('focused-monitor'),
          ),
        ),
      ),
    );
    await tester.pump();

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(HomeGamePage)),
    );
    expect(
      controller.requestById(
        const HibikiFocusId('game-library-tab-capture'),
      ),
      isTrue,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
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
          ),
        ),
      );
      await tester.pump();
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
