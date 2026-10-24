import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/pages/implementations/series_shelf_card.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

/// TODO-616 A2 / TODO-947 SeriesShelfCard guard:
///  - renders series name + member-count subtitle (series_item_count).
///  - tap fires onTap; in selection mode routes to onSelectionToggle.
///  - 2026-10-25 库页定版: no badges on the cover; count / kind / tags / progress
///    live in the ShelfCardMeta below the cover. Under the glossy-book material
///    the members fan out (ShelfCoverPile, up to 4 covers, first = front); the
///    selection check stays visible over the front cover.
///  - SeriesFolderCover (name-dialog preview) keeps the 2x2 folder mosaic.
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget wrap(Widget child) => TranslationProvider(
    child: MaterialApp(
      home: Scaffold(body: SizedBox(width: 200, height: 320, child: child)),
    ),
  );

  // 用带 Key 的封面 widget，便于精确 find 后层是否真实渲染。
  Widget coverBox(String id, Color color) =>
      ColoredBox(key: ValueKey<String>('cover_$id'), color: color);

  testWidgets('renders series name and item-count badge', (tester) async {
    await tester.pumpWidget(
      wrap(
        SeriesShelfCard(
          name: 'My Series',
          itemCount: 3,
          covers: <Widget>[coverBox('a', Colors.blue)],
          slotAspectRatio: 160 / 260,
          onTap: () {},
        ),
      ),
    );
    expect(find.text('My Series'), findsOneWidget);
    // series_item_count(n: 3) => "3 items" (en).
    expect(find.text('3 items'), findsOneWidget);
  });

  testWidgets('tap fires onTap when not in selection mode', (tester) async {
    int taps = 0;
    await tester.pumpWidget(
      wrap(
        SeriesShelfCard(
          name: 'S',
          itemCount: 2,
          covers: <Widget>[coverBox('a', Colors.green)],
          slotAspectRatio: 160 / 260,
          onTap: () => taps++,
        ),
      ),
    );
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('selection mode routes tap to onSelectionToggle', (tester) async {
    int taps = 0;
    int toggles = 0;
    await tester.pumpWidget(
      wrap(
        SeriesShelfCard(
          name: 'S',
          itemCount: 2,
          covers: <Widget>[coverBox('a', Colors.green)],
          slotAspectRatio: 160 / 260,
          selectionMode: true,
          selectionKey: 'series_1',
          onSelectionToggle: () => toggles++,
          onTap: () => taps++,
        ),
      ),
    );
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    expect(toggles, 1);
    expect(taps, 0);
  });

  testWidgets('registers a FushiFocusTarget under a focus root with focusId', (
    tester,
  ) async {
    int taps = 0;
    await tester.pumpWidget(
      wrap(
        FushiFocusRoot(
          child: SeriesShelfCard(
            name: 'S',
            itemCount: 2,
            covers: <Widget>[coverBox('a', Colors.green)],
            slotAspectRatio: 160 / 260,
            focusId: const FushiFocusId('reader-shelf-series-42'),
            onTap: () => taps++,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(FushiFocusTarget), findsOneWidget);
    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.byType(SeriesShelfCard)),
    );
    expect(
      controller.requestById(const FushiFocusId('reader-shelf-series-42')),
      isTrue,
    );
    await tester.pump();
    expect(controller.activeId, const FushiFocusId('reader-shelf-series-42'));

    // Enter / gamepad A activates the same onTap as a mouse.
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('stays a bare InkWell without a focusId (never-break)', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        FushiFocusRoot(
          child: SeriesShelfCard(
            name: 'S',
            itemCount: 2,
            covers: <Widget>[coverBox('a', Colors.green)],
            slotAspectRatio: 160 / 260,
            onTap: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(FushiFocusTarget), findsNothing);
  });

  // ---- 2026-10 书架重设计：叠层封面（与视频库「系列」卡同一个 ShelfCoverFrame）----

  testWidgets('stacked cover: front cover sits in a stacked ShelfCoverFrame', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SeriesShelfCard(
          name: 'Stack',
          itemCount: 3,
          covers: <Widget>[coverBox('front', Colors.red)],
          slotAspectRatio: 160 / 260,
          onTap: () {},
        ),
      ),
    );
    final ShelfCoverFrame frame = tester.widget<ShelfCoverFrame>(
      find.byType(ShelfCoverFrame),
    );
    expect(
      frame.stackedBehind,
      isNotNull,
      reason: '合集格子必须走共享叠层（stackedBehind），不是自绘拼图',
    );
    expect(find.byKey(const ValueKey<String>('cover_front')), findsWidgets);
    // 不再自绘 2x2 文件夹拼图。
    expect(find.byType(SeriesFolderCover), findsNothing);
  });

  testWidgets('subtitle + progress live below the cover, no cover badges', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SeriesShelfCard(
          name: 'Badges',
          itemCount: 6,
          subtitle: '6 vols · reading vol. 2 · #fav',
          progress: 0.5,
          covers: <Widget>[coverBox('a', Colors.red)],
          slotAspectRatio: 160 / 260,
          onTap: () {},
        ),
      ),
    );
    final ShelfCardMeta meta = tester.widget<ShelfCardMeta>(
      find.byType(ShelfCardMeta),
    );
    expect(meta.title, 'Badges');
    expect(meta.subtitle, '6 vols · reading vol. 2 · #fav');
    expect(meta.progress, 0.5);
    expect(find.text('6 vols · reading vol. 2 · #fav'), findsOneWidget);
    expect(
      find.byType(CoverProgressStrip),
      findsNothing,
      reason: '进度条在封面下的文字块里，不压封面',
    );
    expect(
      find.descendant(
        of: find.byType(ShelfCoverFrame),
        matching: find.byType(Text),
      ),
      findsNothing,
      reason: '封面上不得再有「N 册」「系列」之类的文字角标',
    );
  });

  testWidgets('glossy-book material fans out up to 4 member covers', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        ShelfCoverMaterialScope(
          material: ShelfCoverMaterial.glossyBook,
          child: SeriesShelfCard(
            name: 'Fan',
            itemCount: 5,
            covers: <Widget>[
              coverBox('v1', Colors.red),
              coverBox('v2', Colors.green),
              coverBox('v3', Colors.blue),
              coverBox('v4', Colors.orange),
            ],
            slotAspectRatio: 160 / 260,
            onTap: () {},
          ),
        ),
      ),
    );
    final ShelfCoverPile pile = tester.widget<ShelfCoverPile>(
      find.byType(ShelfCoverPile),
    );
    expect(pile.behind, hasLength(3), reason: '最前那本之后依次 3 本');
    for (final String id in <String>['v1', 'v2', 'v3', 'v4']) {
      expect(find.byKey(ValueKey<String>('cover_$id')), findsOneWidget);
    }
  });

  testWidgets('no progress bar when nothing has a progress value', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SeriesShelfCard(
          name: 'Fresh',
          itemCount: 2,
          covers: <Widget>[coverBox('a', Colors.red)],
          slotAspectRatio: 160 / 260,
          onTap: () {},
        ),
      ),
    );
    expect(
      tester.widget<ShelfCardMeta>(find.byType(ShelfCardMeta)).progress,
      isNull,
    );
  });

  testWidgets('selection check stays visible over the stacked cover', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SeriesShelfCard(
          name: 'Sel',
          itemCount: 3,
          covers: <Widget>[coverBox('a', Colors.red)],
          slotAspectRatio: 160 / 260,
          selectionMode: true,
          selectionKey: 'series_9',
          selected: true,
          onSelectionToggle: () {},
          onTap: () {},
        ),
      ),
    );
    await tester.pump();
    final Finder check = find.byIcon(Icons.check);
    expect(check, findsOneWidget);
    expect(tester.getSize(check).width, greaterThan(0));
    // 多选态副行照常可见。
    expect(find.text('3 items'), findsOneWidget);
  });

  // ---- TODO-947 phone-folder mosaic（「组合成系列」命名弹窗预览仍在用）----

  testWidgets('SeriesFolderCover tiles member covers into a folder grid', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SeriesFolderCover(
          covers: <Widget>[
            coverBox('a', Colors.red),
            coverBox('b', Colors.green),
            coverBox('c', Colors.blue),
          ],
        ),
      ),
    );
    expect(find.byKey(const ValueKey<String>('cover_a')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_b')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_c')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('series-folder-cell-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('series-folder-cell-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('series-folder-cell-3')),
      findsNothing,
    );
  });

  testWidgets('SeriesFolderCover single cover degrades to a full cover', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(SeriesFolderCover(covers: <Widget>[coverBox('main', Colors.red)])),
    );
    expect(find.byKey(const ValueKey<String>('cover_main')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('series-folder-cell-0')),
      findsNothing,
    );
  });

  testWidgets('SeriesFolderCover renders N member covers in the grid', (
    tester,
  ) async {
    // 3 covers -> 3 cells filled, cell 3 empty.
    await tester.pumpWidget(
      wrap(
        SeriesFolderCover(
          covers: <Widget>[
            coverBox('x', Colors.red),
            coverBox('y', Colors.green),
            coverBox('z', Colors.blue),
          ],
        ),
      ),
    );
    expect(find.byKey(const ValueKey<String>('cover_x')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_y')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_z')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('series-folder-cell-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('series-folder-cell-3')),
      findsNothing,
    );
  });
}
