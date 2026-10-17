import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';

Widget _host(Widget child, {bool reduceMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets('floating toolbar renders grouped items, labels and overflow', (
    WidgetTester tester,
  ) async {
    int tapped = 0;
    await tester.pumpWidget(
      _host(
        FushiFloatingToolbar(
          showLabels: true,
          groups: <List<FushiToolbarItem>>[
            <FushiToolbarItem>[
              FushiToolbarItem(
                icon: Icons.list,
                label: 'Contents',
                onPressed: () => tapped++,
              ),
            ],
            const <FushiToolbarItem>[
              FushiToolbarItem(
                icon: Icons.tune,
                label: 'Settings',
                onPressed: null,
                selected: true,
              ),
            ],
            const <FushiToolbarItem>[],
          ],
          overflow: <FushiToolbarItem>[
            FushiToolbarItem(
              icon: Icons.photo,
              label: 'Gallery',
              onPressed: () => tapped += 10,
            ),
          ],
          fab: FushiToolbarFab(
            icon: Icons.play_arrow,
            tooltip: 'Play',
            onPressed: () => tapped += 100,
          ),
        ),
      ),
    );
    expect(find.text('Contents'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    // 组间分隔：两组非空 → 一条分隔线（空组跳过）。
    expect(
      find.byKey(const ValueKey<String>('fushi_floating_toolbar_overflow')),
      findsOneWidget,
    );
    await tester.tap(find.text('Contents'));
    expect(tapped, 1);
    await tester.tap(find.byKey(const ValueKey<String>('fushi_toolbar_fab')));
    expect(tapped, 101);
    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_floating_toolbar_overflow')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Gallery'), findsOneWidget);
    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();
    expect(tapped, 111);
  });

  testWidgets('top bar shows separate pills and title tap callback', (
    WidgetTester tester,
  ) async {
    bool titleTapped = false;
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 800,
          child: FushiFloatingTopBar(
            leading: <FushiToolbarItem>[
              FushiToolbarItem(
                icon: Icons.arrow_back,
                label: 'Back',
                onPressed: () {},
              ),
            ],
            title: 'Book',
            subtitle: 'Chapter 1',
            onTitleTap: () => titleTapped = true,
            actions: <List<FushiToolbarItem>>[
              <FushiToolbarItem>[
                FushiToolbarItem(
                  icon: Icons.tune,
                  label: 'Settings',
                  onPressed: () {},
                ),
              ],
            ],
          ),
        ),
      ),
    );
    expect(find.text('Book'), findsOneWidget);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.byType(FushiFloatingPill), findsNWidgets(3));
    await tester.tap(find.text('Book'));
    expect(titleTapped, isTrue);
  });

  testWidgets('chrome reveal springs in and out; hidden is offstage', (
    WidgetTester tester,
  ) async {
    Widget build(bool visible) => _host(
      FushiChromeReveal(
        visible: visible,
        from: AxisDirection.down,
        child: const Text('bar'),
      ),
    );
    await tester.pumpWidget(build(false));
    expect(find.text('bar'), findsNothing);
    await tester.pumpWidget(build(true));
    await tester.pump(const Duration(milliseconds: 16));
    // 动画中途：已上台、正在滑入。
    expect(find.text('bar'), findsOneWidget);
    await tester.pumpAndSettle();
    final Opacity shown = tester.widget<Opacity>(
      find.ancestor(of: find.text('bar'), matching: find.byType(Opacity)),
    );
    expect(shown.opacity, closeTo(1, 0.01));
    await tester.pumpWidget(build(false));
    await tester.pumpAndSettle();
    expect(find.text('bar'), findsNothing);
  });

  testWidgets('chrome reveal is instant under reduce motion', (
    WidgetTester tester,
  ) async {
    Widget build(bool visible) => _host(
      FushiChromeReveal(visible: visible, child: const Text('bar')),
      reduceMotion: true,
    );
    await tester.pumpWidget(build(false));
    await tester.pumpWidget(build(true));
    await tester.pump();
    final Opacity shown = tester.widget<Opacity>(
      find.ancestor(of: find.text('bar'), matching: find.byType(Opacity)),
    );
    expect(shown.opacity, 1);
  });

  testWidgets('morphing fab animates between round and rounded square', (
    WidgetTester tester,
  ) async {
    Widget build(bool playing) => _host(
      FushiToolbarFab(
        icon: playing ? Icons.pause : Icons.play_arrow,
        tooltip: 'Play',
        onPressed: () {},
        morphing: true,
        rounded: playing,
      ),
    );
    await tester.pumpWidget(build(false));
    await tester.pumpWidget(build(true));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.pause), findsOneWidget);
  });

  test('toolbar extent follows M3E spec', () {
    expect(FushiFloatingToolbar.extentFor(), kFushiFloatingToolbarExtent);
    expect(
      FushiFloatingToolbar.extentFor(compact: true),
      kFushiFloatingToolbarCompactExtent,
    );
    expect(
      FushiFloatingToolbar.extentFor(compact: true, showLabels: true),
      kFushiFloatingToolbarExtent,
    );
  });

  // 2026-10-06 用户「小说的底部栏文字也砍掉」：阅读器底部悬浮工具栏是纯图标的
  // M3E floating toolbar——不画文字、名称进 tooltip 与无障碍语义、每颗 >= 48。
  testWidgets(
    'icon-only toolbar keeps tooltip + semantics name, 48dp targets',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      int tapped = 0;
      await tester.pumpWidget(
        _host(
          FushiFloatingToolbar(
            groups: <List<FushiToolbarItem>>[
              <FushiToolbarItem>[
                FushiToolbarItem(
                  key: const ValueKey<String>('nav'),
                  icon: Icons.list,
                  label: 'Navigation',
                  onPressed: () => tapped++,
                ),
                FushiToolbarItem(
                  key: const ValueKey<String>('settings'),
                  icon: Icons.tune,
                  label: 'Reading settings',
                  tooltip: 'Reading settings (Ctrl+M)',
                  onPressed: () => tapped += 10,
                ),
              ],
            ],
          ),
        ),
      );
      expect(find.text('Navigation'), findsNothing);
      expect(find.text('Reading settings'), findsNothing);
      expect(find.byTooltip('Navigation'), findsOneWidget);
      expect(find.byTooltip('Reading settings (Ctrl+M)'), findsOneWidget);
      expect(find.bySemanticsLabel('Navigation'), findsWidgets);
      expect(find.bySemanticsLabel(RegExp(r'^Reading settings')), findsWidgets);
      for (final String k in <String>['nav', 'settings']) {
        final Size size = tester.getSize(find.byKey(ValueKey<String>(k)));
        expect(size.width, greaterThanOrEqualTo(48), reason: k);
        expect(size.height, greaterThanOrEqualTo(48), reason: k);
      }
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey<String>('fushi_floating_toolbar')),
            )
            .height,
        kFushiFloatingToolbarExtent,
      );
      await tester.tap(find.byKey(const ValueKey<String>('settings')));
      expect(tapped, 10);
      semantics.dispose();
    },
  );

  test('novel reader floating dock is icon-only without group dividers', () {
    final String source = File(
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
    ).readAsStringSync();
    final int start = source.indexOf('Widget _buildFloatingBottomChrome()');
    expect(start, isNonNegative);
    final int dock = source.indexOf(
      "ValueKey<String>('fushi_reader_floating_dock')",
      start,
    );
    expect(dock, isNonNegative);
    // FushiFloatingToolbar(...) 调用体：到 `colors: colors,` 为止。
    final String call = source.substring(
      dock,
      source.indexOf('colors: colors,', dock),
    );
    expect(call, isNot(contains('showLabels')), reason: '底栏不画文字');
    // 全部按钮并成一组：组间不插竖分隔线。
    expect(call, contains('for (final List<FushiToolbarItem> g in dock) ...g'));
  });
}
