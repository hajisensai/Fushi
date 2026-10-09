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

  test('macOS / iOS name keys the Mac way and use the Mac nav cluster', () {
    String labelsOf(List<List<KeyboardKeySpec>> rows) => <String>[
      for (final List<KeyboardKeySpec> row in rows)
        for (final KeyboardKeySpec s in row)
          if (!s.isSpacer) s.label,
    ].join('|');

    final String mac = labelsOf(
      buildPhysicalKeyboardRows(platform: TargetPlatform.macOS),
    );
    for (final String name in <String>[
      'esc',
      'tab',
      'caps lock',
      'delete',
      'return',
    ]) {
      expect(mac.split('|'), contains(name));
    }
    for (final String pc in <String>['Esc', 'Tab', 'Caps', 'Bksp', 'Enter']) {
      expect(mac.split('|'), isNot(contains(pc)));
    }

    final List<List<KeyboardKeySpec>> macNav = buildNavClusterRows(
      platform: TargetPlatform.macOS,
    );
    expect(
      labelsOf(macNav),
      'fn|home|page\nup|⌦\ndelete|end|page\ndown|↑|←|↓|→',
    );
    // Insert 位置在 Mac 上是只读的 fn；逻辑键不变（⌦ 仍是 delete，方向键不变）。
    expect(macNav.first.first.key, LogicalKeyboardKey.fn);
    expect(macNav.first.first.kind, KeyCapKind.modifier);
    expect(macNav[1].first.key, LogicalKeyboardKey.delete);
    expect(buildNavClusterRows(platform: TargetPlatform.iOS), macNav);

    final String pc = labelsOf(
      buildPhysicalKeyboardRows(platform: TargetPlatform.windows),
    );
    for (final String name in <String>['Esc', 'Tab', 'Caps', 'Bksp', 'Enter']) {
      expect(pc.split('|'), contains(name));
    }
    expect(
      labelsOf(buildNavClusterRows(platform: TargetPlatform.windows)),
      'Ins|Home|PgUp|Del|End|PgDn|Up|Left|Down|Right',
    );
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
        // fn 在 Mac 示意图上出现两次（左下角 + 导航簇 Insert 位），取底行那枚。
        final Finder all = find.byKey(Key('keycap_${key.keyId}'));
        expect(
          all,
          key == LogicalKeyboardKey.fn ? findsNWidgets(2) : findsOneWidget,
          reason: '$key',
        );
        final Finder cap = key == LogicalKeyboardKey.fn ? all.first : all;
        final double left = tester.getRect(cap).left;
        expect(left, greaterThan(previousLeft), reason: 'Mac order at $key');
        previousLeft = left;
      }
      expect(
        find.byKey(Key('keycap_${LogicalKeyboardKey.controlRight.keyId}')),
        findsNothing,
      );
      expect(
        find.byKey(Key('keycap_${LogicalKeyboardKey.insert.keyId}')),
        findsNothing,
        reason: 'Mac keyboards have no Insert key',
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
