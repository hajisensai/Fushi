import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_grouping.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2968：标签筛选下「书打了标签、所在合集没打」时书从库页消失。
///
/// 成员级过滤（[keepMemberUnderTagFilter]）放行了自己命中标签的书，书被折进合集组，
/// 随后库页又按「合集自身是否命中标签」整组删掉——书就找不到了。组级判据收口到
/// [keepCollectionGroupUnderTagFilter]，书架与视频库共用。
void main() {
  MediaCollectionRow collection(int id, String name) => MediaCollectionRow(
        id: id,
        name: name,
        collectionType: 'playlist',
        coverSource: null,
        sortOrder: 0,
        createdAt: 0,
        orderUpdatedAt: 0,
      );

  group('keepCollectionGroupUnderTagFilter', () {
    test('无选中标签 → 恒保留', () {
      expect(
        keepCollectionGroupUnderTagFilter(
          collectionId: 1,
          collectionFilter: null,
          anyMemberMatched: false,
        ),
        isTrue,
      );
    });

    test('合集自身命中标签 → 保留', () {
      expect(
        keepCollectionGroupUnderTagFilter(
          collectionId: 1,
          collectionFilter: <int>{1},
          anyMemberMatched: false,
        ),
        isTrue,
      );
    });

    test('根因场景：合集没打标签、但组内有书自己命中 → 保留', () {
      expect(
        keepCollectionGroupUnderTagFilter(
          collectionId: 1,
          collectionFilter: <int>{},
          anyMemberMatched: true,
        ),
        isTrue,
      );
    });

    test('合集与成员都没命中 → 剔除', () {
      expect(
        keepCollectionGroupUnderTagFilter(
          collectionId: 1,
          collectionFilter: <int>{2},
          anyMemberMatched: false,
        ),
        isFalse,
      );
    });
  });

  test('整条筛选管线：合集内打了标签的书在筛选后仍可见（只露命中的那本）', () {
    // 合集 1 = {a, b}，只有 a 打了标签；合集本身没打。散书 c 没打标签。
    const Set<String> taggedMembers = <String>{'a'};
    const Set<int> taggedCollections = <int>{};
    final Map<String, int> primary = <String, int>{
      MediaKind.epub.compositeKey('a'): 1,
      MediaKind.epub.compositeKey('b'): 1,
    };
    final List<CollectionOrderingItem<String>> items =
        <CollectionOrderingItem<String>>[
      for (final String key in <String>['a', 'b', 'c'])
        if (keepMemberUnderTagFilter(
          memberMatched: taggedMembers.contains(key),
          primaryCollectionId: primary[MediaKind.epub.compositeKey(key)],
          collectionFilter: taggedCollections,
        ))
          CollectionOrderingItem<String>(
            mediaType: MediaKind.epub,
            entryKey: key,
            importedAt: 0,
            payload: key,
          ),
    ];
    final List<CollectionGroup<String>> groups = groupByCollections<String>(
      items: items,
      primaryCollectionIdByEntry: primary,
      collectionsById: <int, MediaCollectionRow>{1: collection(1, 'S')},
      memberSortIndex: const <String, int>{},
    )..removeWhere((CollectionGroup<String> g) =>
        g.collection != null &&
        !keepCollectionGroupUnderTagFilter(
          collectionId: g.collection!.id,
          collectionFilter: taggedCollections,
          anyMemberMatched: g.items.any(
            (CollectionOrderingItem<String> it) =>
                taggedMembers.contains(it.payload),
          ),
        ));

    final List<String> visible = <String>[
      for (final CollectionGroup<String> g in groups)
        for (final CollectionOrderingItem<String> it in g.items) it.payload,
    ];
    expect(visible, <String>['a'], reason: '打了标签的 a 必须留下（旧逻辑随未打标签的合集一起被删）');
    expect(groups.single.collection?.id, 1, reason: 'a 仍按合集折叠显示');
  });

  test('书架与视频库的组级筛选都走 keepCollectionGroupUnderTagFilter（源码守卫）', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
      'lib/src/pages/implementations/home_video_page.dart',
    ]) {
      final String src = File(path).readAsStringSync();
      expect(src.contains('keepCollectionGroupUnderTagFilter('), isTrue,
          reason: '$path 的合集组标签筛选必须走共享判据（BUG-2968）');
      expect(
          src.contains('!collectionFilter.contains(g.collection!.id)'), isFalse,
          reason: '$path 不得再只按合集自身标签整组删除（BUG-2968）');
    }
  });
}
