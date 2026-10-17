// 共享 chip / 菜单的无障碍与动效回归（Codex 第六轮 HBK-AUDIT-038 / 041 / 042，
// 以及 2026-10-06 统计中心选中 chip 深色圆盘）。全部驱动真实共享组件。
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase, PrefCodec;

Future<void> _pumpChip(
  WidgetTester tester,
  Widget chip, {
  TargetPlatform platform = TargetPlatform.android,
  double textScale = 1,
  bool reduceMotion = true,
  TextDirection direction = TextDirection.ltr,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        platform: platform,
        splashFactory: NoSplash.splashFactory,
      ),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(390, 844),
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: Directionality(
          textDirection: direction,
          child: Scaffold(body: Center(child: chip)),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _RouteObserver extends NavigatorObserver {
  TransitionRoute<dynamic>? latest;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is TransitionRoute<dynamic>) latest = route;
  }
}

Future<_RouteObserver> _openMenu(
  WidgetTester tester, {
  required ThemeData theme,
  bool reduceMotion = false,
}) async {
  final _RouteObserver observer = _RouteObserver();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.copyWith(
        platform: TargetPlatform.android,
        splashFactory: NoSplash.splashFactory,
      ),
      navigatorObservers: <NavigatorObserver>[observer],
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: Scaffold(
        body: Center(
          child: FushiOverflowMenu<int>(
            tooltip: 'Review menu',
            onSelected: (_) {},
            items: <PopupMenuEntry<int>>[
              FushiPopupMenuItem<int>(
                label: 'Selected priority',
                value: 0,
                selected: true,
              ),
              FushiPopupMenuItem<int>(label: 'Other priority', value: 1),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byTooltip('Review menu'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(find.text('Selected priority'), findsOneWidget);
  return observer;
}

double _contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  group('FushiSelectableChip', () {
    testWidgets('meets the Android semantic touch target (HBK-AUDIT-038)', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        await _pumpChip(
          tester,
          FushiSelectableChip(
            label: 'Books',
            leadingIcon: Icons.book,
            selected: false,
            onSelected: (_) {},
          ),
        );
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      } finally {
        handle.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('stays compact on desktop precise pointers', (
      WidgetTester tester,
    ) async {
      await _pumpChip(
        tester,
        FushiSelectableChip(
          label: 'Books',
          leadingIcon: Icons.book,
          selected: false,
          onSelected: (_) {},
        ),
        platform: TargetPlatform.windows,
      );
      expect(tester.getSize(find.byType(ChoiceChip)).height, lessThan(40));
    });

    testWidgets('edge of the padded touch area still selects the chip', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      await _pumpChip(
        tester,
        FushiSelectableChip(
          label: 'Books',
          leadingIcon: Icons.book,
          selected: false,
          onSelected: (_) => calls++,
        ),
      );
      final Rect rect = tester.getRect(
        find
            .ancestor(
              of: find.byType(ChoiceChip),
              matching: find.byType(FushiTouchTargetPadding),
            )
            .first,
      );
      expect(rect.height, greaterThanOrEqualTo(48));
      await tester.tapAt(Offset(rect.center.dx, rect.top + 2));
      await tester.pump();
      await tester.tapAt(Offset(rect.center.dx, rect.bottom - 2));
      await tester.pump();
      expect(calls, 2);
    });

    testWidgets('selected leading icon swaps to a check without the RawChip '
        'avatar scrim', (WidgetTester tester) async {
      await _pumpChip(
        tester,
        FushiSelectableChip(
          label: 'Games',
          leadingIcon: Icons.sports_esports,
          selected: true,
          onSelected: (_) {},
        ),
      );
      final ChoiceChip chip = tester.widget<ChoiceChip>(
        find.byType(ChoiceChip),
      );
      // RawChip 自带对勾会在 avatar 上叠深色圆形 scrim；有前导图标时必须关掉。
      expect(chip.showCheckmark, isFalse);
      expect(
        find.byKey(const ValueKey<String>('fushi-chip-leading-check')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.sports_esports), findsNothing);
    });

    testWidgets('RTL long chip at scale two keeps keyboard selection '
        'semantics', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        int calls = 0;
        const String label = 'Bibliothèque de livres et de bandes dessinées';
        await _pumpChip(
          tester,
          SizedBox(
            width: 280,
            child: FushiSelectableChip(
              label: label,
              leadingIcon: Icons.book,
              selected: true,
              onSelected: (_) => calls++,
            ),
          ),
          textScale: 2,
          direction: TextDirection.rtl,
        );
        expect(tester.takeException(), isNull);
        expect(
          tester.getSemantics(find.byType(ChoiceChip)),
          matchesSemantics(
            label: label,
            isEnabled: true,
            hasEnabledState: true,
            isSelected: true,
            hasSelectedState: true,
            isButton: true,
            isFocusable: true,
            hasTapAction: true,
            hasFocusAction: true,
          ),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(calls, 1);
      } finally {
        handle.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });

  testWidgets('FushiFilterChip leading check swap has zero duration under '
      'reduced motion', (WidgetTester tester) async {
    await _pumpChip(
      tester,
      FushiFilterChip(
        avatar: const Icon(Icons.book),
        label: const Text('Books'),
        selected: true,
        onSelected: (_) {},
      ),
    );
    final Finder swap = find
        .ancestor(
          of: find.byKey(const ValueKey<String>('fushi-chip-leading-check')),
          matching: find.byType(AnimatedSwitcher),
        )
        .first;
    expect(tester.widget<AnimatedSwitcher>(swap).duration, Duration.zero);
    expect(tester.widget<FilterChip>(find.byType(FilterChip)).showCheckmark,
        isFalse);
    expect(tester.takeException(), isNull);
  });

  group('FushiPopupMenuItem / menu route', () {
    testWidgets('selected item text keeps contrast in a supported custom '
        'theme (HBK-AUDIT-041)', (WidgetTester tester) async {
      final FushiDatabase database = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final ThemeNotifier notifier = ThemeNotifier(
        database,
        () => const TextTheme(),
      );
      addTearDown(() async {
        notifier.dispose();
        await database.close();
      });
      const CustomThemeEntry entry = CustomThemeEntry(
        id: 'round6-menu',
        name: 'Light surface',
        seed: 0xFF6750A4,
        surfaceColor: 0xFFFFFFFF,
      );
      notifier.loadFromPrefsSnapshot(<String, String>{
        'app_theme_key': PrefCodec.encode('custom-theme:${entry.id}'),
        'custom_themes': PrefCodec.encode(<String>[
          jsonEncode(entry.toJson()),
        ]),
        'selected_custom_theme_id': PrefCodec.encode(entry.id),
        'brightness_mode': PrefCodec.encode('dark'),
      });
      final ThemeData theme = notifier.darkTheme;
      expect(theme.colorScheme.surface, Colors.white);
      await _openMenu(tester, theme: theme, reduceMotion: true);
      final RenderParagraph text = tester.renderObject<RenderParagraph>(
        find.text('Selected priority'),
      );
      final Color foreground = text.text.style!.color!;
      final Ink selectedInk = tester.widget<Ink>(
        find
            .ancestor(
              of: find.text('Selected priority'),
              matching: find.byType(Ink),
            )
            .first,
      );
      final Color background =
          (selectedInk.decoration! as BoxDecoration).color!;
      expect(background, theme.colorScheme.secondaryContainer);
      final double contrast = _contrast(
        Color.alphaBlend(foreground, background),
        background,
      );
      expect(contrast, greaterThanOrEqualTo(4.5),
          reason: 'foreground=$foreground background=$background');
    });

    testWidgets('menu entries meet Android semantic touch targets', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        await _openMenu(tester, theme: ThemeData(), reduceMotion: true);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      } finally {
        handle.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('eink menu route opens without decoration motion '
        '(HBK-AUDIT-042)', (WidgetTester tester) async {
      final ThemeData theme = buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        textTheme: const TextTheme(),
        eink: true,
      );
      final _RouteObserver observer = await _openMenu(tester, theme: theme);
      final BuildContext context = tester.element(
        find.text('Selected priority'),
      );
      expect(isEinkTheme(context), isTrue);
      expect(fushiMotionEnabled(context), isFalse);
      expect(observer.latest!.transitionDuration, Duration.zero);
      expect(observer.latest!.reverseTransitionDuration, Duration.zero);
    });

    testWidgets('system reduced motion also opens menu without animation', (
      WidgetTester tester,
    ) async {
      final _RouteObserver observer = await _openMenu(
        tester,
        theme: ThemeData(),
        reduceMotion: true,
      );
      expect(observer.latest!.transitionDuration, Duration.zero);
      expect(observer.latest!.reverseTransitionDuration, Duration.zero);
    });
  });
}
