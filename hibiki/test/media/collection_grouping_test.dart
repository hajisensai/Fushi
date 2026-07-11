import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/collections/collection_grouping.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 统一合集 Phase 4：[groupByCollections] 折叠归属 + 排序纯函数测试。
MediaCollectionRow _col(int id, String name, int sortOrder) =>
    MediaCollectionRow(
      id: id,
      name: name,
      collectionType: 'playlist',
      coverSource: null,
      sortOrder: sortOrder,
      createdAt: 0,
    );

CollectionOrderingItem<String> _item(String key, int importedAt) =>
    CollectionOrderingItem<String>(
      mediaType: 'video',
      entryKey: key,
      importedAt: importedAt,
      payload: key,
    );

void main() {
  // 让 drift Value 的 import 有实际使用（生成行类构造）。
  test('MediaCollectionRow 构造可用', () {
    expect(_col(1, 'A', 0).name, 'A');
    // ignore: unnecessary_type_check
    expect(const Value<int>(0) is Value<int>, isTrue);
  });

  test('属同一合集的条目折叠成一个合集 group，散条目各自单卡', () {
    final List<CollectionGroup<String>> groups = groupByCollections<String>(
      items: <CollectionOrderingItem<String>>[
        _item('v1', -0),
        _item('v2', -1),
        _item('v3', -2), // 散条目
      ],
      primaryCollectionIdByEntry: <String, int>{
        'video|v1': 1,
        'video|v2': 1,
      },
      collectionsById: <int, MediaCollectionRow>{1: _col(1, 'Show', 5)},
      itemSortOrder: <String, int>{},
    );

    // 合集卡 + 散条目卡。
    final CollectionGroup<String> col =
        groups.firstWhere((CollectionGroup<String> g) => g.collection != null);
    expect(col.collection!.name, 'Show');
    expect(col.items.map((CollectionOrderingItem<String> i) => i.entryKey),
        <String>['v1', 'v2']);
    final Iterable<CollectionGroup<String>> loose =
        groups.where((CollectionGroup<String> g) => g.collection == null);
    expect(loose, hasLength(1));
    expect(loose.single.coverItem.entryKey, 'v3');
  });

  test('归属 id 不在 collectionsById（合集已删的孤儿引用）→ 退化为散条目', () {
    final List<CollectionGroup<String>> groups = groupByCollections<String>(
      items: <CollectionOrderingItem<String>>[_item('v1', 0)],
      primaryCollectionIdByEntry: <String, int>{'video|v1': 99},
      collectionsById: const <int, MediaCollectionRow>{}, // 99 不存在
      itemSortOrder: <String, int>{},
    );
    expect(groups, hasLength(1));
    expect(groups.single.collection, isNull);
    expect(groups.single.coverItem.entryKey, 'v1');
  });

  test('卡片间按 groupSortOrder 排序（合集用 sortOrder，散条目用 shelf sortOrder）', () {
    final List<CollectionGroup<String>> groups = groupByCollections<String>(
      items: <CollectionOrderingItem<String>>[
        _item('loose', 0),
        _item('m1', 0),
      ],
      primaryCollectionIdByEntry: <String, int>{'video|m1': 1},
      collectionsById: <int, MediaCollectionRow>{1: _col(1, 'Col', 2)},
      itemSortOrder: <String, int>{'video|loose': 9}, // 散条目排后
    );
    // 合集(sortOrder 2) 在散条目(sortOrder 9) 之前。
    expect(groups.first.collection?.name, 'Col');
    expect(groups.last.collection, isNull);
  });
}
