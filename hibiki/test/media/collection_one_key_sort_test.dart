import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/collections/collection_one_key_sort.dart';

/// 合集「一键整理」比较规则的守卫。
///
/// 三个入口（库页合集右键菜单 / 书架网格详情页 / 视频合集详情页）共用
/// [compareCollectionMembers]，规则改一处就得三处同时改口径——所以规则本身要有
/// 测试钉死，而不是靠三份手写比较器各自「看起来一样」。
///
/// 重点是**平局兜底**：`List.sort` 不是稳定排序，同名同导入时刻的条目若不再比一个
/// 稳定的键，每次整理都可能换个顺序；而这个顺序是要落盘（`sortIndex`）的，用户看到
/// 的就是「列表自己在动」。视频详情页此前的「按名称」比较器就缺这层兜底。
void main() {
  CollectionSortMeta meta(String title, int importedAt, String key) =>
      (title: title, importedAt: importedAt, key: key);

  List<CollectionSortMeta> sorted(
    List<CollectionSortMeta> input, {
    required bool byTitle,
  }) =>
      List<CollectionSortMeta>.of(input)
        ..sort((CollectionSortMeta a, CollectionSortMeta b) =>
            compareCollectionMembers(a, b, byTitle: byTitle));

  List<String> keysOf(List<CollectionSortMeta> rows) =>
      <String>[for (final CollectionSortMeta r in rows) r.key];

  group('compareCollectionMembers — 按名称', () {
    test('natural 序：卷1 < 卷2 < 卷10（不是字典序）', () {
      final List<CollectionSortMeta> rows = sorted(
        <CollectionSortMeta>[
          meta('卷10', 0, 'c'),
          meta('卷2', 0, 'b'),
          meta('卷1', 0, 'a'),
        ],
        byTitle: true,
      );
      expect(keysOf(rows), <String>['a', 'b', 'c']);
    });

    test('同名时按导入时刻旧→新', () {
      final List<CollectionSortMeta> rows = sorted(
        <CollectionSortMeta>[
          meta('OP', 300, 'late'),
          meta('OP', 100, 'early'),
        ],
        byTitle: true,
      );
      expect(keysOf(rows), <String>['early', 'late']);
    });

    test('同名且同导入时刻：身份键定序，打乱输入结果不变', () {
      final List<CollectionSortMeta> a = <CollectionSortMeta>[
        meta('NCOP', 100, 'uid-c'),
        meta('NCOP', 100, 'uid-a'),
        meta('NCOP', 100, 'uid-b'),
      ];
      final List<CollectionSortMeta> b = <CollectionSortMeta>[
        meta('NCOP', 100, 'uid-b'),
        meta('NCOP', 100, 'uid-c'),
        meta('NCOP', 100, 'uid-a'),
      ];
      expect(
        keysOf(sorted(a, byTitle: true)),
        <String>['uid-a', 'uid-b', 'uid-c'],
      );
      expect(
        keysOf(sorted(b, byTitle: true)),
        keysOf(sorted(a, byTitle: true)),
        reason: '缺平局兜底时 List.sort 不稳定，同一批条目会排出两种顺序并落盘',
      );
    });
  });

  group('compareCollectionMembers — 按导入时间', () {
    test('旧→新', () {
      final List<CollectionSortMeta> rows = sorted(
        <CollectionSortMeta>[
          meta('b', 300, 'third'),
          meta('a', 100, 'first'),
          meta('c', 200, 'second'),
        ],
        byTitle: false,
      );
      expect(keysOf(rows), <String>['first', 'second', 'third']);
    });

    test('同导入时刻：先名称、再身份键，打乱输入结果不变', () {
      final List<CollectionSortMeta> a = <CollectionSortMeta>[
        meta('卷2', 100, 'v2'),
        meta('卷1', 100, 'v1-b'),
        meta('卷1', 100, 'v1-a'),
      ];
      final List<CollectionSortMeta> b = <CollectionSortMeta>[
        meta('卷1', 100, 'v1-a'),
        meta('卷2', 100, 'v2'),
        meta('卷1', 100, 'v1-b'),
      ];
      expect(
        keysOf(sorted(a, byTitle: false)),
        <String>['v1-a', 'v1-b', 'v2'],
      );
      expect(
          keysOf(sorted(b, byTitle: false)), keysOf(sorted(a, byTitle: false)));
    });
  });

  test('导入时刻缺失按 0（最旧）参与排序，不 throw', () {
    final List<CollectionSortMeta> rows = sorted(
      <CollectionSortMeta>[
        meta('有时间', 100, 'known'),
        meta('无时间', 0, 'unknown'),
      ],
      byTitle: false,
    );
    expect(keysOf(rows), <String>['unknown', 'known']);
  });
}
