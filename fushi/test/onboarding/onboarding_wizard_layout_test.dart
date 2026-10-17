import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/visual/key_cap_widget.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart' show FushiPageScaffold;
import 'package:material_ui/material_ui.dart';

/// 桌面自绘标题行（`FushiDesktopTitleBar`）的高度：它以 MediaQuery 顶部 padding
/// 的形式交给整棵 Navigator，向导页 State 的 context 看到的就是这一份。
const double _kTitleBarInset = 32;

Widget _app(Widget home) => MaterialApp(
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(padding: const EdgeInsets.only(top: _kTitleBarInset)),
    child: child!,
  ),
  home: home,
);

void main() {
  // BUG-3202：向导正文的 removePadding 用了脚手架外层的 context，把脚手架报给
  // 正文的「标题行 + 页头 + 进度条」让位高度整个换回外层的 32px，步骤 hero 画到
  // 了进度条上。
  testWidgets('step hero starts below the header progress bar (BUG-3202)', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 960);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        const FushiPageScaffold(
          automaticallyImplyLeading: false,
          headerCompact: true,
          title: 'Onboarding',
          headerBottom: OnboardingProgressBar(current: 0, total: 9),
          body: OnboardingWizardBody(
            stepKey: 0,
            forward: true,
            step: OnboardingStepView(
              icon: FushiIcons.home,
              title: 'Welcome',
              body: 'Pick a language and a theme.',
            ),
            navigationBar: SizedBox(height: 56),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect progress = tester.getRect(find.byType(OnboardingProgressBar));
    final Rect hero = tester.getRect(find.byType(OnboardingStepHero));
    expect(progress.top, greaterThanOrEqualTo(_kTitleBarInset));
    expect(
      hero.top,
      greaterThanOrEqualTo(progress.bottom),
      reason: 'hero $hero must not overlap the progress bar $progress',
    );
  });

  // BUG-3203：macOS 上「全局查词」的热键显示成了 Ctrl / Alt / D，且三枚键帽各占
  // 满一整行。实际绑定就是 Control+Option+D（⌘⌥D 是系统「隐藏 Dock」），只是
  // 显示错了。
  testWidgets('hotkey keycaps show Apple symbols and size to content on macOS '
      '(BUG-3203)', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final InputBinding binding = ShortcutDefaults.forPlatform(
        TargetPlatform.macOS,
      )[ShortcutAction.globalExternalLookup]!.keyboardBindings.first;
      expect(binding.modifiers, <ModifierKey>{
        ModifierKey.ctrl,
        ModifierKey.alt,
      });
      expect(binding.key, LogicalKeyboardKey.keyD);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              child: OnboardingHotkeyKeycaps(binding: binding),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final List<String> labels = tester
          .widgetList<KeyCapWidget>(find.byType(KeyCapWidget))
          .map((KeyCapWidget w) => w.label)
          .toList();
      expect(labels, <String>['⌃', '⌥', 'D']);

      final List<Rect> caps = <Rect>[
        for (int i = 0; i < 3; i++)
          tester.getRect(
            find.byKey(ValueKey<String>('onboarding_hotkey_keycap_$i')),
          ),
      ];
      for (final Rect cap in caps) {
        expect(cap.width, lessThan(120), reason: 'keycap $cap fills the row');
        expect(cap.top, caps.first.top, reason: 'keycaps share one row');
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
