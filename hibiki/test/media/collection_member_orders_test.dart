import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/shelf_reorder_page.dart';

/// UI v2 Phase E（对抗审查确认后补）：整理页组内成员序必须写穿
/// MediaCollectionItems.sortIndex——[collectionMemberOrders] 把最终顺序按 groupId
/// 聚成每合集的有序成员清单（喂 reorderCollectionItems），保证库页行序与播放器
/// 剧集面板/合集详情页同源。
void main() {
  ShelfReorderItem item(String key, {int? groupId}) => ShelfReorderItem(
        mediaType: 'video',
        entryKey: key,
        card: const SizedBox.shrink(),
        groupId: groupId,
      );

  test('按 groupId 聚组、保持出现序；散条目不参与', () {
    final Map<int, List<({String mediaType, String entryKey})>> orders =
        collectionMemberOrders(<ShelfReorderItem>[
      item('b2', groupId: 7),
      item('loose'),
      item('a1', groupId: 3),
      item('b1', groupId: 7),
      item('a2', groupId: 3),
    ]);
    expect(orders.keys.toSet(), <int>{3, 7});
    expect(orders[7]!.map((e) => e.entryKey).toList(), <String>['b2', 'b1']);
    expect(orders[3]!.map((e) => e.entryKey).toList(), <String>['a1', 'a2']);
  });

  test('全散条目 → 空映射（不做任何合集写）', () {
    expect(
      collectionMemberOrders(<ShelfReorderItem>[item('x'), item('y')]),
      isEmpty,
    );
  });
}
