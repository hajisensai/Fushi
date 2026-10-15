import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/collections/series_collection_placement.dart';

/// 远端占位卡按系列键归位到本地同系列合集（用户手机漫画库：「志乃と恋」1–2 卷
/// 已成组，对端下发的 3、4 卷占位卡不带 collection，散在合集旁边）。
void main() {
  const List<SeriesCollectionMember> shino = <SeriesCollectionMember>[
    (key: 'epub|v1', title: '志乃と恋 [3574f94a]', collectionId: 101, sortIndex: 0),
    (
      key: 'epub|v2',
      title: '志乃と恋 ２ [e11812e5]',
      collectionId: 101,
      sortIndex: 1,
    ),
  ];

  test('3、4 卷占位卡归进同系列合集，按卷号接在 1–2 卷之后', () {
    final SeriesCollectionPlacement r = placeLooseVolumesInSeriesCollections(
      members: shino,
      loose: const <SeriesLooseVolume>[
        (key: 'epub|r4', title: '志乃と恋 ４'),
        (key: 'epub|r3', title: '志乃と恋 3 [998c5526]'),
      ],
    );
    expect(r.collectionIdByKey, <String, int>{'epub|r3': 101, 'epub|r4': 101});
    expect(r.sortIndexByKey, <String, int>{
      'epub|v1': 0,
      'epub|v2': 1,
      'epub|r3': 2,
      'epub|r4': 3,
    });
  });

  test('缺中间卷的占位卡插到对应卷号位置，原成员相对顺序不变', () {
    final SeriesCollectionPlacement r = placeLooseVolumesInSeriesCollections(
      members: const <SeriesCollectionMember>[
        (key: 'epub|v1', title: '志乃と恋', collectionId: 7, sortIndex: 0),
        (key: 'epub|v3', title: '志乃と恋 3', collectionId: 7, sortIndex: 1),
      ],
      loose: const <SeriesLooseVolume>[(key: 'epub|r2', title: '志乃と恋 第2巻')],
    );
    expect(r.sortIndexByKey, <String, int>{
      'epub|v1': 0,
      'epub|r2': 1,
      'epub|v3': 2,
    });
  });

  test('只有一卷碰巧在主题合集里不算系列合集（与归组器同判据）', () {
    final SeriesCollectionPlacement r = placeLooseVolumesInSeriesCollections(
      members: const <SeriesCollectionMember>[
        (key: 'epub|v1', title: '志乃と恋', collectionId: 9, sortIndex: 0),
        (key: 'epub|x', title: 'やがて君になる', collectionId: 9, sortIndex: 1),
      ],
      loose: const <SeriesLooseVolume>[(key: 'epub|r2', title: '志乃と恋 2')],
    );
    expect(r.collectionIdByKey, isEmpty);
    expect(r.sortIndexByKey, isEmpty);
  });

  test('不同系列 / 解析不出系列的散卡不动', () {
    final SeriesCollectionPlacement r = placeLooseVolumesInSeriesCollections(
      members: shino,
      loose: const <SeriesLooseVolume>[
        (key: 'epub|a', title: '安達としまむら 3'),
        (key: 'epub|b', title: '86'),
      ],
    );
    expect(r.collectionIdByKey, isEmpty);
  });
}
