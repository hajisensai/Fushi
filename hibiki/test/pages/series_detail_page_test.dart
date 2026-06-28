import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/series_detail_page.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-616 A1 SeriesDetailPage 守卫：
///  - AppBar 有重命名 / 删除 / 排序按钮。
///  - 无成员 → series_empty 占位。
///  - 删除系列 → 确认后调 deleteSeries（FK setNull，不删书）。
///  - 移出成员 → setSeriesForEntry(null)，成员散回。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  late HibikiDatabase db;
  setUp(() {
    db = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );
  });
  tearDown(() => db.close());

  Widget wrap(Widget child) => TranslationProvider(
        child: MaterialApp(home: child),
      );

  testWidgets('appbar exposes rename / delete / reorder buttons', (
    tester,
  ) async {
    final int sid = await db.createSeries('S');
    await tester.pumpWidget(wrap(SeriesDetailPage(
      database: db,
      seriesId: sid,
      initialName: 'S',
      memberCardBuilder: (_) => null,
      onChanged: () {},
    )));
    await tester.pumpAndSettle();
    expect(
        find.widgetWithIcon(HibikiIconButton, Icons.swap_vert), findsOneWidget);
    expect(
        find.widgetWithIcon(HibikiIconButton, Icons.drive_file_rename_outline),
        findsOneWidget);
    expect(find.widgetWithIcon(HibikiIconButton, Icons.delete_outline),
        findsOneWidget);
  });

  testWidgets('empty series shows series_empty placeholder', (tester) async {
    final int sid = await db.createSeries('S');
    await tester.pumpWidget(wrap(SeriesDetailPage(
      database: db,
      seriesId: sid,
      initialName: 'S',
      memberCardBuilder: (_) => null,
      onChanged: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('No books in this series'), findsOneWidget);
  });

  testWidgets('delete series calls deleteSeries (FK setNull, keeps book row)', (
    tester,
  ) async {
    final int sid = await db.createSeries('S');
    await db.setSeriesForEntry('epub', 'bookA', sid);
    int changed = 0;
    await tester.pumpWidget(wrap(SeriesDetailPage(
      database: db,
      seriesId: sid,
      initialName: 'S',
      // render the member as a simple box so the grid is non-empty.
      memberCardBuilder: (_) => const ColoredBox(color: Colors.blue),
      onChanged: () => changed++,
    )));
    await tester.pumpAndSettle();

    await tester
        .tap(find.widgetWithIcon(HibikiIconButton, Icons.delete_outline));
    await tester.pumpAndSettle();
    // confirm dialog: tap the destructive Delete action.
    await tester.tap(find.text('Delete series').last);
    await tester.pumpAndSettle();

    expect(await db.getSeriesById(sid), isNull, reason: '系列删除');
    final shelfRow = await db.getShelfEntry('epub', 'bookA');
    expect(shelfRow, isNotNull, reason: 'FK setNull 散回，不删 shelf_entry 行');
    expect(shelfRow!.seriesId, isNull, reason: '成员归属归 NULL');
    expect(changed, greaterThanOrEqualTo(1));
  });

  testWidgets('remove member calls setSeriesForEntry(null)', (tester) async {
    final int sid = await db.createSeries('S');
    await db.setSeriesForEntry('epub', 'bookA', sid);
    await tester.pumpWidget(wrap(SeriesDetailPage(
      database: db,
      seriesId: sid,
      initialName: 'S',
      memberCardBuilder: (_) => const ColoredBox(color: Colors.blue),
      onChanged: () {},
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await tester.pumpAndSettle();

    final shelfRow = await db.getShelfEntry('epub', 'bookA');
    expect(shelfRow!.seriesId, isNull, reason: '移出系列 → seriesId NULL');
    expect(await db.getShelfEntriesBySeries(sid), isEmpty);
  });
}
