import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/focus/hibiki_focus_target.dart';
import 'package:fushi/src/pages/implementations/series_shelf_card.dart';

/// TODO-616 A2 / TODO-947 SeriesShelfCard guard:
///  - renders series name + member-count badge (series_item_count).
///  - tap fires onTap; in selection mode routes to onSelectionToggle.
///  - phone-folder mosaic: >=2 covers tile into a 2x2 member-cover grid;
///    a single cover degrades to a full cover (no grid); the grid is capped
///    at 4 cells; the selection check stays visible over the mosaic.
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

  // 用带 Key 的封面 widget，便于精确 find 后层是否真实渲染。
  Widget coverBox(String id, Color color) =>
      ColoredBox(key: ValueKey<String>('cover_$id'), color: color);

  testWidgets('renders series name and item-count badge', (tester) async {
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'My Series',
      itemCount: 3,
      covers: <Widget>[coverBox('a', Colors.blue)],
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
      covers: <Widget>[coverBox('a', Colors.green)],
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
      covers: <Widget>[coverBox('a', Colors.green)],
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
        covers: <Widget>[coverBox('a', Colors.green)],
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
        covers: <Widget>[coverBox('a', Colors.green)],
        slotAspectRatio: 160 / 260,
        onTap: () {},
      ),
    )));
    await tester.pump();
    expect(find.byType(HibikiFocusTarget), findsNothing);
  });

  // ---- TODO-947 phone-folder mosaic ----

  testWidgets('multi-cover tiles member covers into a folder grid',
      (tester) async {
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'Folder',
      itemCount: 3,
      covers: <Widget>[
        coverBox('a', Colors.red),
        coverBox('b', Colors.green),
        coverBox('c', Colors.blue),
      ],
      slotAspectRatio: 160 / 260,
      onTap: () {},
    )));
    // All three member covers render inside the mosaic (folder shows the books).
    expect(find.byKey(const ValueKey<String>('cover_a')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_b')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_c')), findsOneWidget);
    // 2x2 mosaic: cells 0..2 hold covers; cell 3 is an empty placeholder.
    expect(find.byKey(const ValueKey<String>('series-folder-cell-0')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('series-folder-cell-1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('series-folder-cell-2')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('series-folder-cell-3')),
        findsNothing);
  });

  testWidgets('single cover degrades to a full cover (no mosaic grid)',
      (tester) async {
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'Solo',
      itemCount: 1,
      covers: <Widget>[coverBox('main', Colors.red)],
      slotAspectRatio: 160 / 260,
      onTap: () {},
    )));
    expect(find.byKey(const ValueKey<String>('cover_main')), findsOneWidget);
    // No mosaic cells: the single cover fills the tile directly.
    expect(find.byKey(const ValueKey<String>('series-folder-cell-0')),
        findsNothing);
    expect(find.byKey(const ValueKey<String>('series-folder-cell-1')),
        findsNothing);
  });

  testWidgets('mosaic caps at 4 cells even with more members', (tester) async {
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'Many',
      itemCount: 6,
      covers: <Widget>[
        coverBox('c0', Colors.red),
        coverBox('c1', Colors.green),
        coverBox('c2', Colors.blue),
        coverBox('c3', Colors.yellow),
        coverBox('c4', Colors.purple),
      ],
      slotAspectRatio: 160 / 260,
      onTap: () {},
    )));
    // Exactly four cells; the fifth cover is not rendered.
    expect(find.byKey(const ValueKey<String>('cover_c0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_c3')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_c4')), findsNothing);
    expect(find.byKey(const ValueKey<String>('series-folder-cell-3')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('series-folder-cell-4')),
        findsNothing);
    // Badge still reports the true total (6), not the capped preview count.
    expect(find.text('6 items'), findsOneWidget);
  });

  testWidgets('selection check stays visible over the folder mosaic',
      (tester) async {
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'Sel',
      itemCount: 3,
      covers: <Widget>[
        coverBox('a', Colors.red),
        coverBox('b', Colors.green),
        coverBox('c', Colors.blue),
      ],
      slotAspectRatio: 160 / 260,
      selectionMode: true,
      selectionKey: 'series_9',
      selected: true,
      onSelectionToggle: () {},
      onTap: () {},
    )));
    await tester.pump();
    final Finder check = find.byIcon(Icons.check);
    expect(check, findsOneWidget);
    expect(tester.getSize(check).width, greaterThan(0));
  });

  testWidgets('SeriesFolderCover renders N member covers in the grid',
      (tester) async {
    // 3 covers -> 3 cells filled, cell 3 empty.
    await tester.pumpWidget(wrap(SeriesFolderCover(
      covers: <Widget>[
        coverBox('x', Colors.red),
        coverBox('y', Colors.green),
        coverBox('z', Colors.blue),
      ],
    )));
    expect(find.byKey(const ValueKey<String>('cover_x')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_y')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_z')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('series-folder-cell-2')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('series-folder-cell-3')),
        findsNothing);
  });
}
