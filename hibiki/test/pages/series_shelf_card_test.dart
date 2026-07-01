import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/pages/implementations/series_shelf_card.dart';

/// TODO-616 A2 SeriesShelfCard 守卫：
///  - 渲染系列名 + 成员数角标（series_item_count）。
///  - 点击触发 onTap。
///  - 选择态下点击走 onSelectionToggle 而非 onTap。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget wrap(Widget child) => TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 320,
              child: child,
            ),
          ),
        ),
      );

  testWidgets('renders series name and item-count badge', (tester) async {
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'My Series',
      itemCount: 3,
      cover: const ColoredBox(color: Colors.blue),
      slotAspectRatio: 160 / 260,
      onTap: () {},
    )));
    expect(find.text('My Series'), findsOneWidget);
    // series_item_count(n: 3) => "3 items" (en).
    expect(find.text('3 items'), findsOneWidget);
  });

  testWidgets('tap fires onTap when not in selection mode', (tester) async {
    int taps = 0;
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'S',
      itemCount: 2,
      cover: const ColoredBox(color: Colors.green),
      slotAspectRatio: 160 / 260,
      onTap: () => taps++,
    )));
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('selection mode routes tap to onSelectionToggle', (tester) async {
    int taps = 0;
    int toggles = 0;
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'S',
      itemCount: 2,
      cover: const ColoredBox(color: Colors.green),
      slotAspectRatio: 160 / 260,
      selectionMode: true,
      selectionKey: 'series_1',
      onSelectionToggle: () => toggles++,
      onTap: () => taps++,
    )));
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    expect(toggles, 1);
    expect(taps, 0);
  });

  testWidgets('registers a HibikiFocusTarget under a focus root with focusId',
      (tester) async {
    int taps = 0;
    await tester.pumpWidget(wrap(HibikiFocusRoot(
      child: SeriesShelfCard(
        name: 'S',
        itemCount: 2,
        cover: const ColoredBox(color: Colors.green),
        slotAspectRatio: 160 / 260,
        focusId: const HibikiFocusId('reader-shelf-series-42'),
        onTap: () => taps++,
      ),
    )));
    await tester.pump();

    expect(find.byType(HibikiFocusTarget), findsOneWidget);
    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(SeriesShelfCard)),
    );
    expect(
      controller.requestById(const HibikiFocusId('reader-shelf-series-42')),
      isTrue,
    );
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('reader-shelf-series-42'));

    // Enter / gamepad A activates the same onTap as a mouse.
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('stays a bare InkWell without a focusId (never-break)',
      (tester) async {
    await tester.pumpWidget(wrap(HibikiFocusRoot(
      child: SeriesShelfCard(
        name: 'S',
        itemCount: 2,
        cover: const ColoredBox(color: Colors.green),
        slotAspectRatio: 160 / 260,
        onTap: () {},
      ),
    )));
    await tester.pump();
    expect(find.byType(HibikiFocusTarget), findsNothing);
  });
}
