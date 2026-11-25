import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_shelf_row.dart';
import 'package:fushi/src/models/library_grid_columns.dart';
import 'package:fushi/src/pages/implementations/library_view_options.dart';
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart'
    show LibraryViewSection;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:material_ui/material_ui.dart';

// BUG-4219 + 库页「每行数量」（2026-11-07）。
void main() {
  group('shelfGridCardLayout（书架 / 漫画库网格）', () {
    test('BUG-4219：360dp 手机 80% 缩放（逻辑宽 450）自动出 3 列', () {
      // 网格左右各缩 gap 8 只是封面外缘对齐顶栏，不能吃掉列数：
      // 旧实现按 450 − 16 = 434 算，434 / 150 向下取整 = 2 列。
      final ({int columns, double cardWidth}) layout = shelfGridCardLayout(
        contentWidth: 450,
        gridInset: 8,
        targetWidth: readerShelfGridExtentForWidth(450),
      );
      expect(layout.columns, 3);
      expect(layout.cardWidth, closeTo((450 - 16) / 3, 1e-9));
    });

    test('100% 缩放的 360dp 手机自动仍是 2 列（不放大回归面）', () {
      final ({int columns, double cardWidth}) layout = shelfGridCardLayout(
        contentWidth: 360,
        gridInset: 8,
        targetWidth: readerShelfGridExtentForWidth(360),
      );
      expect(layout.columns, 2);
    });

    test('定了列数就用它，格宽 = 内缩后的宽平分', () {
      final ({int columns, double cardWidth}) layout = shelfGridCardLayout(
        contentWidth: 360,
        gridInset: 8,
        targetWidth: 150,
        fixedColumns: 4,
      );
      expect(layout.columns, 4);
      expect(layout.cardWidth, closeTo(344 / 4, 1e-9));
    });
  });

  test('unifiedShelfCardLayout 的 fixedColumns 覆盖自动列数（视频库）', () {
    final ({int columns, double cardWidth}) auto = unifiedShelfCardLayout(
      availableWidth: 336,
      targetWidth: 150,
    );
    expect(auto.columns, 2);
    final ({int columns, double cardWidth}) fixed = unifiedShelfCardLayout(
      availableWidth: 336,
      targetWidth: 150,
      fixedColumns: 3,
    );
    expect(fixed.columns, 3);
    expect(fixed.cardWidth, closeTo((336 - 2 * 12) / 3, 1e-9));
  });

  test('格宽 < 130dp 时书架格子内边距减半（紧凑间距）', () {
    expect(shelfGridCellInsetFor(344 / 3, 12), 6);
    expect(shelfGridCellInsetFor(434 / 3, 12), 12);
    expect(shelfGridCellInsetFor(172, 12), 12);
  });

  test('书架格子比例按格宽现算：封面区恒为书封比例（材质不溢出）', () {
    const double footer = 60;
    for (final double cellWidth in <double>[86, 114.7, 172, 230]) {
      final double inset = shelfGridCellInsetFor(cellWidth, 12);
      final double ratio = shelfBookCellAspectRatio(
        cellWidth: cellWidth,
        inset: inset,
        footerHeight: footer,
      );
      final double cellHeight = cellWidth / ratio;
      final double coverWidth = cellWidth - inset * 2;
      final double coverHeight = cellHeight - inset * 2 - footer;
      expect(
        coverWidth / coverHeight,
        closeTo(kShelfBookCoverAspectRatio, 1e-9),
        reason: '格宽 $cellWidth',
      );
    }
  });

  group('每行数量偏好表', () {
    test('手机竖屏最多 4 列', () {
      expect(libraryGridColumnChoices(WindowSizeClass.compact), <int>[2, 3, 4]);
    });

    test('按库 × 尺寸档分别记，写 null 恢复自动', () {
      Map<String, int> table = const <String, int>{};
      table = withLibraryGridColumns(
        table,
        LibraryGridDomain.books,
        WindowSizeClass.compact,
        3,
      );
      table = withLibraryGridColumns(
        table,
        LibraryGridDomain.video,
        WindowSizeClass.expanded,
        8,
      );
      final Map<String, int> decoded = decodeLibraryGridColumns(
        encodeLibraryGridColumns(table),
      );
      expect(
        libraryGridFixedColumnsFrom(
          decoded,
          LibraryGridDomain.books,
          WindowSizeClass.compact,
        ),
        3,
      );
      // 漫画库与书架同一页面类，但分开记。
      expect(
        libraryGridFixedColumnsFrom(
          decoded,
          LibraryGridDomain.manga,
          WindowSizeClass.compact,
        ),
        isNull,
      );
      // 手机上定的值不带到平板档。
      expect(
        libraryGridFixedColumnsFrom(
          decoded,
          LibraryGridDomain.books,
          WindowSizeClass.medium,
        ),
        isNull,
      );
      final Map<String, int> cleared = withLibraryGridColumns(
        decoded,
        LibraryGridDomain.books,
        WindowSizeClass.compact,
        null,
      );
      expect(
        libraryGridFixedColumnsFrom(
          cleared,
          LibraryGridDomain.books,
          WindowSizeClass.compact,
        ),
        isNull,
      );
    });

    test('坏值一律当自动', () {
      expect(decodeLibraryGridColumns('not json'), isEmpty);
      expect(decodeLibraryGridColumns('[1,2]'), isEmpty);
      // 不在该档可选范围内的值（手改过 / 选项收窄过）。
      expect(
        libraryGridFixedColumnsFrom(
          const <String, int>{'books.compact': 7},
          LibraryGridDomain.books,
          WindowSizeClass.compact,
        ),
        isNull,
      );
    });

    test('设备本地：不随备份 / 同步 / Profile 走', () {
      expect(
        SyncRepository.deviceLocalPrefKeys,
        contains(kLibraryGridColumnsPrefKey),
      );
    });
  });

  testWidgets('窄窗抽屉：点一项生效、抽屉不关、选中态跟着重画', (WidgetTester tester) async {
    int? columns;
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            hostContext = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );
    showLibraryViewSheet(
      context: hostContext,
      title: 'Sort and layout',
      sections: () => <LibraryViewSection>[
        libraryGridColumnsSection(
          sizeClass: WindowSizeClass.compact,
          selected: columns,
          onSelected: (int? value) => columns = value,
        ),
      ],
    );
    await tester.pumpAndSettle();

    FushiChoiceChip chip(String key) =>
        tester.widget<FushiChoiceChip>(find.byKey(ValueKey<String>(key)));

    expect(chip('library_grid_columns_auto').selected, isTrue);
    expect(
      find.byKey(const ValueKey<String>('library_grid_columns_5')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('library_grid_columns_3')),
    );
    await tester.pumpAndSettle();

    expect(columns, 3);
    expect(
      find.byKey(const ValueKey<String>('library_view_sheet')),
      findsOneWidget,
    );
    expect(chip('library_grid_columns_3').selected, isTrue);
    expect(chip('library_grid_columns_auto').selected, isFalse);
  });
}
