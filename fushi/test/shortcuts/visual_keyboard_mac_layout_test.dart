import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/shortcuts/visual/key_cap_widget.dart';
import 'package:fushi/src/shortcuts/visual/keyboard_layout_view.dart';
import 'package:material_ui/material_ui.dart';

// BUG-3203（用户 10-09 拍板）：设置页键盘示意图在 macOS / iPad 上画 Mac 键盘的
// 修饰键行（fn ⌃ ⌥ ⌘ · Space · ⌘ ⌥），其它平台保持 PC 的 Ctrl Win Alt。改的是
// 布局数据，逻辑键不变。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  double flexOf(List<KeyboardKeySpec> row) =>
      row.fold<double>(0, (double a, KeyboardKeySpec s) => a + s.flex);

  test('macOS / iOS pick the Mac modifier row, others keep the PC row', () {
    final List<KeyboardKeySpec> mac = buildPhysicalKeyboardRows(
      platform: TargetPlatform.macOS,
    ).last;
    expect(mac.map((KeyboardKeySpec s) => s.key).toList(), <LogicalKeyboardKey>[
      LogicalKeyboardKey.fn,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.metaRight,
      LogicalKeyboardKey.altRight,
    ]);
    expect(mac.map((KeyboardKeySpec s) => s.label).toList(), <String>[
      'fn',
      '⌃\ncontrol',
      '⌥\noption',
      '⌘\ncommand',
      'Space',
      '⌘\ncommand',
      '⌥\noption',
    ]);
    expect(flexOf(mac), kAnsiMainRowFlex);
    expect(buildPhysicalKeyboardRows(platform: TargetPlatform.iOS).last, mac);

    for (final TargetPlatform p in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.android,
    ]) {
      final List<KeyboardKeySpec> pc = buildPhysicalKeyboardRows(
        platform: p,
      ).last;
      expect(pc.map((KeyboardKeySpec s) => s.label).toList(), <String>[
        'Ctrl',
        'Win',
        'Alt',
        'Space',
        'Alt',
        'Win',
        'Ctrl',
      ]);
      expect(flexOf(pc), kAnsiMainRowFlex);
    }
  });

  testWidgets(
    'keyboard view draws the Mac modifier row when platform is macOS',
    (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      tester.view.physicalSize = const Size(1400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.macOS);

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: KeyboardLayoutView(
                  registry: registry,
                  scope: ShortcutScope.reader,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final List<LogicalKeyboardKey> bottom = <LogicalKeyboardKey>[
        LogicalKeyboardKey.fn,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.metaRight,
        LogicalKeyboardKey.altRight,
      ];
      double previousLeft = double.negativeInfinity;
      for (final LogicalKeyboardKey key in bottom) {
        final Finder cap = find.byKey(Key('keycap_${key.keyId}'));
        expect(cap, findsOneWidget, reason: '$key');
        final double left = tester.getRect(cap).left;
        expect(left, greaterThan(previousLeft), reason: 'Mac order at $key');
        previousLeft = left;
      }
      expect(
        find.byKey(Key('keycap_${LogicalKeyboardKey.controlRight.keyId}')),
        findsNothing,
      );
      expect(
        tester
            .widget<KeyCapWidget>(
              find.byKey(Key('keycap_${LogicalKeyboardKey.metaLeft.keyId}')),
            )
            .label,
        '⌘\ncommand',
      );
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
