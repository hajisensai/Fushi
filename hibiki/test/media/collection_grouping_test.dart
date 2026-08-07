import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_grouping.dart';
import 'package:fushi_core/fushi_core.dart';

/// 统一合集 Phase 4 / 排序 v2：[groupByCollections] 折叠纯函数测试。
/// v2 后本函数只折叠不排卡（卡片间序由页面按排序模式做）；组内序真相源 =
/// memberSortIndex（[MediaCollectionItems].sortIndex），与详情页/播放器同源。
MediaCollectionRow _col(int id, String name) => MediaCollectionRow(
      id: id,
      name: name,
      collectionType: 'playlist',
      coverSource: null,
      sortOrder: 0,
      createdAt: 0,
      orderUpdatedAt: 0,
    );

CollectionOrderingItem<String> _item(String key, int importedAt) =>
    CollectionOrderingItem<String>(
      mediaType: MediaKind.video,
      entryKey: key,
      importedAt: importedAt,
      payload: key,
    );

void main() {
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
      collectionsById: <int, MediaCollectionRow>{1: _col(1, 'Show')},
      memberSortIndex: <String, int>{},
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
      memberSortIndex: <String, int>{},
    );
    expect(groups, hasLength(1));
    expect(groups.single.collection, isNull);
    expect(groups.single.coverItem.entryKey, 'v1');
  });

  test('组内序 = memberSortIndex 升序（与详情页/播放器 getCollectionItems 同源）', () {
    final List<CollectionGroup<String>> groups = groupByCollections<String>(
      items: <CollectionOrderingItem<String>>[
        _item('e2', 100), // importedAt 更新，但 sortIndex 靠后
        _item('e1', 50),
      ],
      primaryCollectionIdByEntry: <String, int>{
        'video|e1': 1,
        'video|e2': 1,
      },
      collectionsById: <int, MediaCollectionRow>{1: _col(1, 'S')},
      memberSortIndex: <String, int>{'video|e1': 0, 'video|e2': 1},
    );
    expect(
      groups.single.items.map((CollectionOrderingItem<String> i) => i.entryKey),
      <String>['e1', 'e2'],
      reason: 'sortIndex 优先于 importedAt',
    );
  });

  test('缺 sortIndex 行的成员退化 importedAt 倒序，排在有 sortIndex 成员之后', () {
    final List<CollectionGroup<String>> groups = groupByCollections<String>(
      items: <CollectionOrderingItem<String>>[
        _item('noIdxNew', 200),
        _item('noIdxOld', 100),
        _item('idx0', 1),
      ],
      primaryCollectionIdByEntry: <String, int>{
        'video|noIdxNew': 1,
        'video|noIdxOld': 1,
        'video|idx0': 1,
      },
      collectionsById: <int, MediaCollectionRow>{1: _col(1, 'S')},
      memberSortIndex: <String, int>{'video|idx0': 0},
    );
    expect(
      groups.single.items.map((CollectionOrderingItem<String> i) => i.entryKey),
      <String>['idx0', 'noIdxNew', 'noIdxOld'],
    );
  });

  test('v2 不排卡：散 group 保持输入序，合集 group 出现在首成员位置', () {
    final List<CollectionGroup<String>> groups = groupByCollections<String>(
      items: <CollectionOrderingItem<String>>[
        _item('looseA', 0),
        _item('m1', 0), // 合集 1 首成员 → 合集行占位于此
        _item('looseB', 0),
        _item('m2', 0), // 合集 1 后续成员，不再新增位置
      ],
      primaryCollectionIdByEntry: <String, int>{
        'video|m1': 1,
        'video|m2': 1,
      },
      collectionsById: <int, MediaCollectionRow>{1: _col(1, 'S')},
      memberSortIndex: <String, int>{'video|m1': 0, 'video|m2': 1},
    );
    expect(
      groups
          .map((CollectionGroup<String> g) =>
              g.collection?.name ?? g.coverItem.entryKey)
          .toList(),
      <String>['looseA', 'S', 'looseB'],
    );
  });

  group('keepMemberUnderTagFilter (BUG-940 合集标签救回成员)', () {
    test('成员自身命中标签 → 保留', () {
      expect(
        keepMemberUnderTagFilter(
          memberMatched: true,
          primaryCollectionId: null,
          collectionFilter: null,
        ),
        isTrue,
      );
    });

    test('根因场景：成员没命中、但所属合集命中标签 → 保留（旧逻辑会剥光成员→合集筛不出）', () {
      expect(
        keepMemberUnderTagFilter(
          memberMatched: false,
          primaryCollectionId: 7,
          collectionFilter: <int>{7},
        ),
        isTrue,
      );
    });

    test('成员没命中、所属合集也不在筛选集 → 剔除', () {
      expect(
        keepMemberUnderTagFilter(
          memberMatched: false,
          primaryCollectionId: 7,
          collectionFilter: <int>{3, 5},
        ),
        isFalse,
      );
    });

    test('散条目（无合集归属）没命中标签 → 剔除', () {
      expect(
        keepMemberUnderTagFilter(
          memberMatched: false,
          primaryCollectionId: null,
          collectionFilter: <int>{1},
        ),
        isFalse,
      );
    });

    test('collectionFilter 为 null（无合集标签维度）→ 仅按成员命中，与旧语义一致', () {
      expect(
        keepMemberUnderTagFilter(
          memberMatched: false,
          primaryCollectionId: 7,
          collectionFilter: null,
        ),
        isFalse,
      );
    });
  });
}
