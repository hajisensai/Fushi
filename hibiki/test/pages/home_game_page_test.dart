import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_game_page.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';

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
    await tester.ensureVisible(find.byKey(HomeGamePage.openCaptureKey));
    await tester.tap(find.byKey(HomeGamePage.openCaptureKey));
    await tester.pump();
    expect(find.text('monitor-session'), findsOneWidget);

    await tester.tap(find.byKey(_TestMonitor.backKey));
    await tester.pump();
    expect(disposeCount, 0, reason: '返回游戏库只能 Offstage，不能停止 Hook 会话');

    await tester.ensureVisible(find.byKey(HomeGamePage.openCaptureKey));
    await tester.tap(find.byKey(HomeGamePage.openCaptureKey));
    await tester.pump();
    expect(initCount, 1);
    expect(disposeCount, 0);
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
