// Apple 设计系统下带倒计时的确认框（showFushiConfirmDialog(confirmDelay:)）：
// 倒计时确认键必须与取消键一样按 iOS alert 胶囊排布（两个并排等宽、都在
// FushiAlertActionScope 里）。曾经倒计时键是另一种组件类型，FushiAlertDialog
// 的「全是标准按钮」判定不认识它，整组动作退回横排、按钮也画成了普通样式。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';

void main() {
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          textTheme: Typography.material2021().black,
          glass: FushiGlassMaterial.off,
          glassDesign: true,
        ),
        builder: (BuildContext context, Widget? child) =>
            FushiGlassScope(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              hostContext = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return hostContext;
  }

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Finder inAlertScope(Finder of) =>
      find.ancestor(of: of, matching: find.byType(FushiAlertActionScope));

  for (final bool destructive in <bool>[false, true]) {
    testWidgets('Apple：倒计时确认框走 alert 排布（destructive: $destructive）', (
      WidgetTester tester,
    ) async {
      final BuildContext context = await pumpHost(tester);
      final Future<bool> result = showFushiConfirmDialog(
        context: context,
        title: 'Skip?',
        message: 'Body',
        confirmLabel: 'OK',
        cancelLabel: 'NO',
        destructive: destructive,
        confirmDelay: const Duration(seconds: 3),
      );
      await settle(tester);

      final Finder cancel = find.text('NO');
      final Finder countdown = find.text('OK (3)');
      expect(cancel, findsOneWidget);
      expect(countdown, findsOneWidget);
      // 两个键都在 alert 动作作用域里（按钮据此画成 alert 胶囊）。
      expect(inAlertScope(cancel), findsOneWidget);
      expect(inAlertScope(countdown), findsOneWidget);

      // iOS alert 两键：并排、等宽、同高。
      final Finder cancelButton = find.ancestor(
        of: cancel,
        matching: find.byType(FushiDialogAction),
      );
      final Finder confirmButton = find.byKey(
        const ValueKey<String>('fushi-confirm-countdown-action'),
      );
      final Rect a = tester.getRect(cancelButton);
      final Rect b = tester.getRect(confirmButton);
      expect(a.width, moreOrLessEquals(b.width, epsilon: 0.5));
      expect(a.height, moreOrLessEquals(b.height, epsilon: 0.5));
      expect(a.top, moreOrLessEquals(b.top, epsilon: 0.5));
      expect(a.right, lessThan(b.left));

      // 倒计时内点不动；归零后外观仍在 alert 作用域里，点了返回 true。
      await tester.tap(confirmButton, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(countdown, findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('OK'), findsOneWidget);
      expect(inAlertScope(find.text('OK')), findsOneWidget);
      expect(tester.getRect(confirmButton).width, moreOrLessEquals(b.width));
      await tester.tap(confirmButton);
      await settle(tester);
      expect(await result, isTrue);
    });
  }
}
