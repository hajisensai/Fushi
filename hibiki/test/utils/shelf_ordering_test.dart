import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/shelf_ordering.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-616 groupAndSortShelfEntries 纯函数守卫（widget-free）：
///  - 空 ShelfEntries：退化为 importedAt 倒序（向后兼容）。
///  - 自定义 sortOrder 生效（asc）。
///  - 系列折叠成一个 group + 组内排序。
///  - 散书与系列卡片同层混排（按 group sortOrder）。
ShelfOrderingItem<String> _item(String key, int importedAt,
        {String mediaType = 'epub'}) =>
    ShelfOrderingItem<String>(
      mediaType: mediaType,
      entryKey: key,
      importedAt: importedAt,
      payload: key,
    );

ShelfEntryRow _entry(String key, int sortOrder, int? seriesId,
        {String mediaType = 'epub'}) =>
    ShelfEntryRow(
      mediaType: mediaType,
      entryKey: key,
      sortOrder: sortOrder,
      seriesId: seriesId,
    );

SeriesRow _series(int id, int sortOrder) => SeriesRow(
      id: id,
      name: 'S$id',
      coverSource: null,
      sortOrder: sortOrder,
      createdAt: 0,
    );

void main() {
  group('groupAndSortShelfEntries', () {
    test('空 ShelfEntries → importedAt 倒序（退化向后兼容）', () {
      final groups = groupAndSortShelfEntries<String>(
        items: <ShelfOrderingItem<String>>[
          _item('A', 100),
          _item('B', 300),
          _item('C', 200),
        ],
        shelfEntries: <ShelfEntryRow>[],
        seriesById: <int, SeriesRow>{},
      );
      // 全散书，每条一个 group；按 importedAt desc。
      expect(groups.map((g) => g.coverItem.entryKey).toList(),
          <String>['B', 'C', 'A']);
      expect(groups.every((g) => g.seriesId == null), isTrue);
    });

    test('自定义 sortOrder 生效（asc 覆盖 importedAt）', () {
      final groups = groupAndSortShelfEntries<String>(
        items: <ShelfOrderingItem<String>>[
          _item('A', 999), // 最新但 sortOrder 大 → 排后
          _item('B', 1),
        ],
        shelfEntries: <ShelfEntryRow>[
          _entry('A', 5, null),
          _entry('B', 1, null),
        ],
        seriesById: <int, SeriesRow>{},
      );
      expect(
          groups.map((g) => g.coverItem.entryKey).toList(), <String>['B', 'A']);
    });

    test('同 seriesId 折叠成一个 group + 组内 sortOrder 排序', () {
      final groups = groupAndSortShelfEntries<String>(
        items: <ShelfOrderingItem<String>>[
          _item('vol2', 200),
          _item('vol1', 100),
          _item('vol3', 300),
        ],
        shelfEntries: <ShelfEntryRow>[
          _entry('vol1', 0, 7),
          _entry('vol2', 1, 7),
          _entry('vol3', 2, 7),
        ],
        seriesById: <int, SeriesRow>{7: _series(7, 0)},
      );
      expect(groups, hasLength(1), reason: '三卷折叠成一个系列 group');
      expect(groups.single.seriesId, 7);
      expect(groups.single.items.map((i) => i.entryKey).toList(),
          <String>['vol1', 'vol2', 'vol3']);
      expect(groups.single.coverItem.entryKey, 'vol1',
          reason: '封面 = 组内排序最小成员（首卷自动）');
    });

    test('散书与系列卡片同层混排，按 group sortOrder', () {
      final groups = groupAndSortShelfEntries<String>(
        items: <ShelfOrderingItem<String>>[
          _item('loose', 50), // 散书 sortOrder=0 → 排在系列(10)前
          _item('s1', 100),
          _item('s2', 200),
        ],
        shelfEntries: <ShelfEntryRow>[
          _entry('s1', 0, 3),
          _entry('s2', 1, 3),
          // loose 无行 → sortOrder 0
        ],
        seriesById: <int, SeriesRow>{3: _series(3, 10)},
      );
      expect(groups, hasLength(2));
      expect(groups.first.seriesId, isNull, reason: '散书 sortOrder 0 在系列 10 前');
      expect(groups.first.coverItem.entryKey, 'loose');
      expect(groups.last.seriesId, 3);
    });

    test('不同 mediaType 同 entryKey 互不串组', () {
      final groups = groupAndSortShelfEntries<String>(
        items: <ShelfOrderingItem<String>>[
          _item('X', 100, mediaType: 'epub'),
          _item('X', 100, mediaType: 'video'),
        ],
        shelfEntries: <ShelfEntryRow>[
          _entry('X', 0, 1, mediaType: 'epub'),
          // video X 无行 → 散书
        ],
        seriesById: <int, SeriesRow>{1: _series(1, 0)},
      );
      // epub X 入系列1；video X 散书。两个 group。
      expect(groups, hasLength(2));
      final epubGroup = groups.firstWhere((g) => g.seriesId == 1);
      expect(epubGroup.items.single.mediaType, 'epub');
    });
  });
}
