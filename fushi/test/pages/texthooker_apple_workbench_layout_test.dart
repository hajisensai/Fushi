// Cupertino（iOS 27 / macOS 27）捕获工作台版面：macOS 档三栏（浮动侧栏 / 纯行
// 台词 / 本句 Inspector）、iOS 档根列表 + 会话摘要；捕获中停止与游戏内查词常驻
// 视口；行动作悬停 / 选中才出现；「＋」收起点；键与焦点 id 不变；M3E 不受影响。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/texthooker_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

ThemeData _theme({required bool glass}) => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
  textTheme: Typography.material2021().black,
  glassDesign: glass,
).copyWith(platform: TargetPlatform.windows);

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  bool glass = true,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(
          testPlatformServices(isWindows: true, isDesktop: true),
        ),
      ],
      child: MaterialApp(
        theme: _theme(glass: glass),
        home: const Scaffold(body: TexthookerPage(embedded: true)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Finder _iconButtonWithFocus(String id) => find.byWidgetPredicate(
  (Widget w) => w is FushiIconButton && w.focusId == FushiFocusId(id),
);

/// 行动作按钮是否可交互：外层 IgnorePointer 不拦截即「出现」。
bool _actionsShown(WidgetTester tester, String lineId) {
  final Finder button = _iconButtonWithFocus('game-line-copy-$lineId');
  expect(button, findsOneWidget);
  final IgnorePointer gate = tester.widget<IgnorePointer>(
    find.ancestor(of: button, matching: find.byType(IgnorePointer)).first,
  );
  return !gate.ignoring;
}

void _setCapturing() {
  GalHookSessionController.instance.debugSetStateForTesting(
    const GalHookSessionState(
      phase: GalHookSessionPhase.running,
      gamePid: 4242,
      launchExe: r'C:\Games\demo\demo.exe',
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TexthookerService.instance.clear();
  });

  tearDown(() {
    GalHookSessionController.instance.debugSetStateForTesting(
      const GalHookSessionState(),
    );
    TexthookerService.instance.clear();
  });

  testWidgets('≥1040 是三栏；无选中时 Inspector 收起，选中一句展开', (
    WidgetTester tester,
  ) async {
    TexthookerService.instance.appendLine('第一行のテスト');
    await _pump(tester, size: const Size(1400, 900));
    expect(_key('game-apple-workbench-mac'), findsOneWidget);
    expect(_key('game-apple-sidebar'), findsOneWidget);
    expect(_key('game-apple-lines'), findsOneWidget);
    expect(_key('game-line-detail-pane-closed'), findsOneWidget);
    expect(_key('game-line-detail-pane'), findsNothing);

    final String id = TexthookerService.instance.entries.first.id;
    await tester.tapAt(
      tester.getTopLeft(_key('game-line-$id')) + const Offset(30, 12),
    );
    await tester.pumpAndSettle();
    expect(_key('game-line-detail-pane'), findsOneWidget);
    expect(_key('game-apple-inspector'), findsOneWidget);
    expect(_key('game-apple-line-actions'), findsOneWidget);

    // 工具栏开关收起（同时清选中）。
    await tester.tap(_key('game-inspector-toggle'));
    await tester.pumpAndSettle();
    expect(_key('game-line-detail-pane-closed'), findsOneWidget);
    // 无选中时开关手动钉开。
    await tester.tap(_key('game-inspector-toggle'));
    await tester.pumpAndSettle();
    expect(_key('game-line-detail-pane'), findsOneWidget);
    expect(find.text(t.game_no_active_line), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('<1040 走 iOS 档：根列表 + 会话摘要，没有侧栏 / Inspector', (
    WidgetTester tester,
  ) async {
    TexthookerService.instance.appendLine('第一行');
    await _pump(tester, size: const Size(900, 800));
    expect(_key('game-apple-workbench-compact'), findsOneWidget);
    expect(_key('game-apple-sidebar'), findsNothing);
    expect(_key('game-line-detail-pane'), findsNothing);
    expect(_key('game-session-overview'), findsOneWidget);
    expect(_key('game-apple-more-menu'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('捕获中停止监听与游戏内查词在视口内（两档）', (WidgetTester tester) async {
    _setCapturing();
    await _pump(tester, size: const Size(1400, 900));
    expect(_key('game-action-stop').hitTestable(), findsOneWidget);
    expect(_key('game-attached-lookup-workbench'), findsOneWidget);
    final Rect lookup = tester.getRect(_key('game-attached-lookup-workbench'));
    expect(lookup.top, lessThan(900));
    expect(lookup.bottom, greaterThan(0));

    await _pump(tester, size: const Size(900, 800));
    expect(_key('game-action-stop').hitTestable(), findsOneWidget);
    expect(_key('game-apple-lookup-status').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('捕获中「＋」下拉含启动 / 附着 / OCR', (WidgetTester tester) async {
    _setCapturing();
    await _pump(tester, size: const Size(1400, 900));
    // 起点不再作为工具行出现。
    expect(_iconButtonWithFocus('game-toolbar-attach'), findsNothing);
    await tester.tap(_key('game-apple-start-menu'));
    await tester.pumpAndSettle();
    expect(find.text(t.game_launch_and_capture), findsOneWidget);
    expect(find.text(t.game_attach_and_capture), findsOneWidget);
    expect(find.text(t.game_ocr_capture), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未开始：中间是三条欢迎行（键 / 焦点 id 同 M3E 起点）', (WidgetTester tester) async {
    await _pump(tester, size: const Size(1400, 900));
    for (final String id in <String>[
      'game-action-launch',
      'game-action-attach',
      'game-action-ocr',
    ]) {
      expect(_key(id), findsOneWidget, reason: id);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('行动作只在悬停 / 选中时出现', (WidgetTester tester) async {
    TexthookerService.instance.appendLine('第一行');
    TexthookerService.instance.appendLine('第二行');
    await _pump(tester, size: const Size(1400, 900));
    final String id = TexthookerService.instance.entries.first.id;
    expect(_actionsShown(tester, id), isFalse);

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(_key('game-line-$id')));
    await tester.pumpAndSettle();
    expect(_actionsShown(tester, id), isTrue);

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(_actionsShown(tester, id), isFalse);

    await tester.tapAt(
      tester.getTopLeft(_key('game-line-$id')) + const Offset(30, 12),
    );
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(_actionsShown(tester, id), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('既有键与焦点 id 仍在（macOS 档）', (WidgetTester tester) async {
    TexthookerService.instance.appendLine('第一行');
    await _pump(tester, size: const Size(1400, 900));
    final String id = TexthookerService.instance.entries.first.id;
    for (final String key in <String>[
      'game-text-thread-selector',
      'game-text-process-entry',
      'game-follow-live',
      'game-auto-lookup',
      'game-hook-code-menu',
      'game-live-lines-count',
      'game-session-overview',
      'game-session-actions',
      'game-session-tools',
      'game-toolbar-audio-fallback',
      'game-toolbar-external-window',
      'game-toolbar-hook-overlay',
      'game-toolbar-health',
      'game-line-$id',
    ]) {
      expect(_key(key), findsWidgets, reason: key);
    }
    for (final String focus in <String>[
      'game-follow-live',
      'game-auto-lookup',
      'game-hook-code-menu',
      'game-line-copy-$id',
    ]) {
      expect(_iconButtonWithFocus(focus), findsOneWidget, reason: focus);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('M3E 不受影响：仍是原拼贴版面', (WidgetTester tester) async {
    TexthookerService.instance.appendLine('第一行');
    await _pump(tester, size: const Size(1400, 900), glass: false);
    expect(_key('game-apple-sidebar'), findsNothing);
    expect(_key('game-apple-workbench-mac'), findsNothing);
    expect(_key('game-session-side'), findsOneWidget);
    expect(_key('game-session-overview'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
