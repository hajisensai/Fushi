/// 合集子篇判据（BUG-1393）：谁是子篇、它的作品海报该落到哪个合集。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/collection_member_policy.dart';
import 'package:hibiki_core/hibiki_core.dart';

MediaCollectionItemRow _item(int collectionId, String mediaType, String key) =>
    MediaCollectionItemRow(
      collectionId: collectionId,
      mediaType: mediaType,
      entryKey: key,
      sortIndex: 0,
    );

void main() {
  group('multiMemberCollectionIdByVideoUid', () {
    test('成员数 ≥2 合集的视频成员判为子篇并带出 collectionId；单成员合集不判', () {
      final Map<String, int> uids = multiMemberCollectionIdByVideoUid(
        <MediaCollectionItemRow>[
          // 双成员 playlist：两集都是子篇，海报归 collection 1。
          _item(1, 'video', 'video/ep1'),
          _item(1, 'video', 'video/ep2'),
          // 单成员合集：单片，可照旧刮成员海报。
          _item(2, 'video', 'video/solo'),
        ],
      );
      expect(uids, <String, int>{'video/ep1': 1, 'video/ep2': 1});
      expect(uids.containsKey('video/solo'), isFalse);
    });

    test('混编合集按全部成员计数，非 video 成员不进结果', () {
      final Map<String, int> uids = multiMemberCollectionIdByVideoUid(
        <MediaCollectionItemRow>[
          // 视频 + 书混编：合集有 2 个成员，视频成员是子篇；书成员不属视频域。
          _item(3, 'video', 'video/mixed'),
          _item(3, 'epub', 'book/one'),
        ],
      );
      expect(uids, <String, int>{'video/mixed': 3});
    });

    test('空输入 → 空映射', () {
      expect(
        multiMemberCollectionIdByVideoUid(const <MediaCollectionItemRow>[]),
        isEmpty,
      );
    });

    test('同条目跨多个多成员合集：取最小 collectionId（与折叠归属同口径）', () {
      final Map<String, int> uids = multiMemberCollectionIdByVideoUid(
        <MediaCollectionItemRow>[
          _item(9, 'video', 'video/both'),
          _item(9, 'video', 'video/nine'),
          _item(5, 'video', 'video/both'),
          _item(5, 'video', 'video/five'),
        ],
      );
      expect(uids['video/both'], 5, reason: '海报该落到库网格里折叠进的那张卡');
    });

    test('单成员合集不参与取最小：只在多成员合集里挑', () {
      final Map<String, int> uids = multiMemberCollectionIdByVideoUid(
        <MediaCollectionItemRow>[
          _item(4, 'video', 'video/both'), // 单成员合集，id 更小
          _item(5, 'video', 'video/both'),
          _item(5, 'video', 'video/other'),
        ],
      );
      expect(uids['video/both'], 5, reason: 'id 4 是单成员合集，不该被选成子篇归属');
    });

    test('输入序无关', () {
      final List<MediaCollectionItemRow> items = <MediaCollectionItemRow>[
        _item(7, 'video', 'video/a'),
        _item(7, 'video', 'video/b'),
        _item(8, 'video', 'video/a'),
        _item(8, 'video', 'video/c'),
      ];
      expect(
        multiMemberCollectionIdByVideoUid(items),
        multiMemberCollectionIdByVideoUid(items.reversed.toList()),
      );
    });
  });
}
