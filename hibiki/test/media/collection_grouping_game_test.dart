import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_grouping.dart';
import 'package:fushi_core/fushi_core.dart';

/// 游戏进合集：'game' mediaType 经 [groupByCollections] 折叠的纯函数测试。
///
/// 分组核心是纯键运算（`'<mediaType>|<entryKey>'`），本测试钉住：game 成员正常
/// 折进合集组、与同名 entryKey 的其它 mediaType 不串键、组内按 sortIndex 排序、
/// 散游戏保持输入序。
MediaCollectionRow _collection(int id, String name) => MediaCollectionRow(
      id: id,
      name: name,
      collectionType: 'collection',
      sortOrder: 0,
      coverSource: null,
      createdAt: 0,
      orderUpdatedAt: 0,
    );

CollectionOrderingItem<String> _game(
  String id, {
  int importedAt = 0,
}) =>
    CollectionOrderingItem<String>(
      mediaType: MediaKind.game,
      entryKey: id,
      importedAt: importedAt,
      payload: 'game:$id',
    );

void main() {
  test('game 成员折进合集组，散游戏保持输入序', () {
    final Map<int, MediaCollectionRow> collections = <int, MediaCollectionRow>{
      7: _collection(7, 'ネコぱら'),
    };
    final List<CollectionGroup<String>> groups = groupByCollections<String>(
      items: <CollectionOrderingItem<String>>[
        _game('g1'),
        _game('g2'),
        _game('g3'),
      ],
      primaryCollectionIdByEntry: <String, int>{
        'game|g1': 7,
        'game|g3': 7,
      },
      collectionsById: collections,
      memberSortIndex: <String, int>{'game|g1': 1, 'game|g3': 0},
    );

    // g1 是合集首成员 → 合集组出现在 g1 的位置（首位）；g2 散卡随后。
    expect(groups, hasLength(2));
    expect(groups[0].collection?.id, 7);
    // 组内按 memberSortIndex 升序：g3(0) 在 g1(1) 前。
    expect(
      groups[0].items.map((CollectionOrderingItem<String> it) => it.entryKey),
      <String>['g3', 'g1'],
    );
    expect(groups[1].collection, isNull);
    expect(groups[1].coverItem.entryKey, 'g2');
  });

  test('game 与同名 entryKey 的其它 mediaType 不串键', () {
    final Map<int, MediaCollectionRow> collections = <int, MediaCollectionRow>{
      1: _collection(1, 'mixed'),
    };
    final List<CollectionGroup<String>> groups = groupByCollections<String>(
      items: <CollectionOrderingItem<String>>[
        _game('same-key'),
        const CollectionOrderingItem<String>(
          mediaType: MediaKind.video,
          entryKey: 'same-key',
          importedAt: 0,
          payload: 'video:same-key',
        ),
      ],
      // 只有 video|same-key 归属合集；game|same-key 必须留在散卡。
      primaryCollectionIdByEntry: <String, int>{'video|same-key': 1},
      collectionsById: collections,
      memberSortIndex: const <String, int>{},
    );

    expect(groups, hasLength(2));
    expect(groups[0].collection, isNull);
    expect(groups[0].coverItem.mediaType, MediaKind.game);
    expect(groups[1].collection?.id, 1);
    expect(groups[1].coverItem.mediaType, MediaKind.video);
  });

  test('归属合集已删（孤儿引用）→ game 退化为散卡，不丢条目', () {
    final List<CollectionGroup<String>> groups = groupByCollections<String>(
      items: <CollectionOrderingItem<String>>[_game('g1')],
      primaryCollectionIdByEntry: <String, int>{'game|g1': 999},
      collectionsById: const <int, MediaCollectionRow>{},
      memberSortIndex: const <String, int>{},
    );
    expect(groups, hasLength(1));
    expect(groups[0].collection, isNull);
    expect(groups[0].coverItem.entryKey, 'g1');
  });
}
