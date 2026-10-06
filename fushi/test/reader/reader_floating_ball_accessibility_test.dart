// 悬浮球无障碍回归（Codex 第 5 轮审查 HBK026 / HBK027 / HBK028，复现原稿
// codex/sh-style-review-1006 的 floating_ball_accessibility_review_repro.dart）：
// - HBK027：触摸展开后焦点留在正文，Esc 仍要收起（键盘展开同样收起并还焦点）；
// - HBK026：动作按钮画 40dp，命中区仍 ≥ 48dp；
// - HBK028：MediaQuery.disableAnimations（系统减弱动态效果）下展开直接落位。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/reader/reader_floating_ball.dart';

const Key _ballKey = ValueKey<String>('fushi_reader_floating_ball_icon');
const Key _actionKey = ValueKey<String>('review-ball-action-0');

Future<void> _pumpBall(
  WidgetTester tester, {
  required FocusNode bodyFocus,
  required List<int> actions,
  bool disableAnimations = false,
  int actionCount = 1,
  Rect viewport = const Rect.fromLTWH(0, 0, 400, 600),
}) async {
  tester.view.physicalSize = const Size(400, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        platform: TargetPlatform.android,
        splashFactory: NoSplash.splashFactory,
      ),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Focus(
              focusNode: bodyFocus,
              child: const ColoredBox(color: Colors.white),
            ),
            ReaderFloatingBall(
              viewport: viewport,
              dock: ReaderFloatingBallDock.right,
              verticalFraction: 0.7,
              onDockChanged: (ReaderFloatingBallDock dock, double fraction) {},
              actions: <ReaderHeaderAction>[
                for (int index = 0; index < actionCount; index++)
                  ReaderHeaderAction(
                    key: ValueKey<String>('review-ball-action-$index'),
                    icon: Icons.add,
                    label: 'Action $index',
                    onPressed: () => actions.add(index),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  bodyFocus.requestFocus();
  await tester.pump();
}

void main() {
  for (final bool keyboardOpen in <bool>[false, true]) {
    testWidgets(
      'expanded ball handles Escape with keyboard mode $keyboardOpen',
      (WidgetTester tester) async {
        final FocusNode bodyFocus = FocusNode(debugLabel: 'reading-body');
        final FocusHighlightStrategy oldStrategy =
            FocusManager.instance.highlightStrategy;
        FocusManager.instance.highlightStrategy = keyboardOpen
            ? FocusHighlightStrategy.alwaysTraditional
            : FocusHighlightStrategy.alwaysTouch;
        try {
          await _pumpBall(tester, bodyFocus: bodyFocus, actions: <int>[]);
          await tester.tap(find.byKey(_ballKey));
          await tester.pumpAndSettle();
          expect(find.byKey(_actionKey), findsOneWidget);
          if (!keyboardOpen) {
            expect(
              bodyFocus.hasPrimaryFocus,
              isTrue,
              reason: 'Touch opening intentionally preserves body focus',
            );
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(
            find.byKey(_actionKey),
            findsNothing,
            reason: 'Escape should close an expanded ball regardless of opener',
          );
          expect(bodyFocus.hasPrimaryFocus, isTrue);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          bodyFocus.dispose();
          FocusManager.instance.highlightStrategy = oldStrategy;
        }
      },
    );
  }

  testWidgets('Android ball actions retain a 48dp actual touch target', (
    WidgetTester tester,
  ) async {
    final FocusNode bodyFocus = FocusNode();
    final List<int> actions = <int>[];
    try {
      // Short viewport produces multiple columns: there is no separate label
      // hit surface that could be mistaken for an expanded icon touch target.
      await _pumpBall(
        tester,
        bodyFocus: bodyFocus,
        actions: actions,
        actionCount: 6,
        viewport: const Rect.fromLTWH(0, 0, 400, 200),
      );
      await tester.tap(find.byKey(_ballKey));
      await tester.pumpAndSettle();
      final Rect target = tester.getRect(find.byKey(_actionKey));
      await tester.tapAt(target.center);
      await tester.pumpAndSettle();
      expect(actions, <int>[0], reason: 'Control: the action is enabled');
      await tester.tapAt(target.center - const Offset(0, 22));
      await tester.pumpAndSettle();
      expect(
        actions,
        <int>[0, 0],
        reason:
            '22dp from center is inside a 48dp target; painted box is $target',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      bodyFocus.dispose();
    }
  });

  testWidgets('ball respects MediaQuery disableAnimations on expansion', (
    WidgetTester tester,
  ) async {
    final FocusNode bodyFocus = FocusNode();
    try {
      await _pumpBall(
        tester,
        bodyFocus: bodyFocus,
        actions: <int>[],
        disableAnimations: true,
      );
      await tester.tap(find.byKey(_ballKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      final Rect immediate = tester.getRect(find.byKey(_ballKey));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(_ballKey)),
        immediate,
        reason: 'Reduced motion should reach final geometry immediately',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      bodyFocus.dispose();
    }
  });
}
