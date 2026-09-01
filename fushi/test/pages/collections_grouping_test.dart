import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart';

/// 阶段 3（收藏夹按「合集 → 媒体」分节）的纯函数守卫 [groupCollectionItems]：
///  * 合集节按「节内最新行」倒序（= 输入时间倒序下的首见序）；未分组恒殿后，
///    且只有存在具名节时才出未分组头；
///  * 节内媒体小节同按首见序；媒体键空的行平铺殿后、不出媒体头；
///  * 行保持输入顺序（时间倒序）。
typedef _Row = ({String id, int? cid, String mediaKey, String? mediaLabel});

List<CollectionGroupRow<_Row>> _group(List<_Row> items) => groupCollectionItems(
      items: items,
      collectionIdOf: (_Row r) => r.cid,
      mediaKeyOf: (_Row r) => r.mediaKey,
      mediaLabelOf: (_Row r) => r.mediaLabel,
    );

_Row _row(String id, {int? cid, String mediaKey = '', String? mediaLabel}) =>
    (id: id, cid: cid, mediaKey: mediaKey, mediaLabel: mediaLabel);

void main() {
  test('合集节按最新行倒序，未分组殿后并挂头', () {
    // 输入时间倒序：a(合集2) b(合集1) c(未分组) d(合集1)。
    final List<CollectionGroupRow<_Row>> rows = _group(<_Row>[
      _row('a', cid: 2, mediaKey: 'm1', mediaLabel: 'M1'),
      _row('b', cid: 1, mediaKey: 'm2', mediaLabel: 'M2'),
      _row('c', mediaKey: 'm3', mediaLabel: 'M3'),
      _row('d', cid: 1, mediaKey: 'm2', mediaLabel: 'M2'),
    ]);
    final List<int?> headerOrder = <int?>[
      for (final CollectionGroupRow<_Row> r in rows)
        if (r.kind == CollectionGroupRowKind.collectionHeader) r.collectionId,
    ];
    expect(headerOrder, <int?>[2, 1, null], reason: '合集 2 含最新行排最前；未分组殿后');
  });

  test('全部未分组时不出任何合集头', () {
    final List<CollectionGroupRow<_Row>> rows = _group(<_Row>[
      _row('a', mediaKey: 'm1', mediaLabel: 'M1'),
      _row('b'),
    ]);
    expect(
      rows.any((CollectionGroupRow<_Row> r) =>
          r.kind == CollectionGroupRowKind.collectionHeader),
      isFalse,
      reason: '孤零零一个「未分组」头是噪音',
    );
  });

  test('媒体小节：有键出头、空键平铺殿后、行保持输入序', () {
    final List<CollectionGroupRow<_Row>> rows = _group(<_Row>[
      _row('a', cid: 1, mediaKey: 'm1', mediaLabel: 'M1'),
      _row('b', cid: 1, mediaKey: '', mediaLabel: null),
      _row('c', cid: 1, mediaKey: 'm1', mediaLabel: 'M1'),
    ]);
    final List<String> shape = <String>[
      for (final CollectionGroupRow<_Row> r in rows)
        switch (r.kind) {
          CollectionGroupRowKind.collectionHeader => 'C${r.collectionId}',
          CollectionGroupRowKind.mediaHeader => 'H${r.mediaLabel}',
          CollectionGroupRowKind.item => r.item!.id,
        },
    ];
    expect(shape, <String>['C1', 'HM1', 'a', 'c', 'b'],
        reason: '媒体组内 a、c 保持输入序；无媒体键的 b 平铺殿后');
  });

  test('媒体标签空时不出媒体头，行仍在', () {
    final List<CollectionGroupRow<_Row>> rows = _group(<_Row>[
      _row('a', cid: 1, mediaKey: 'm1', mediaLabel: null),
    ]);
    expect(
      rows.any((CollectionGroupRow<_Row> r) =>
          r.kind == CollectionGroupRowKind.mediaHeader),
      isFalse,
    );
    expect(
      rows
          .where((CollectionGroupRow<_Row> r) =>
              r.kind == CollectionGroupRowKind.item)
          .length,
      1,
    );
  });
}
