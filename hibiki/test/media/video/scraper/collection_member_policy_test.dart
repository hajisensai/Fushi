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
  group('videoUidsInMultiMemberCollections（合集子篇判据）', () {
    test('成员数 ≥2 合集的视频成员判为子篇；单成员合集不判', () {
      final Set<String> uids = videoUidsInMultiMemberCollections(
        <MediaCollectionItemRow>[
          // 双成员 playlist：两集都是子篇。
          _item(1, 'video', 'video/ep1'),
          _item(1, 'video', 'video/ep2'),
          // 单成员合集：单片，可照旧刮海报。
          _item(2, 'video', 'video/solo'),
        ],
      );
      expect(uids, <String>{'video/ep1', 'video/ep2'});
    });

    test('混编合集按全部成员计数，非 video 成员不进结果', () {
      final Set<String> uids = videoUidsInMultiMemberCollections(
        <MediaCollectionItemRow>[
          // 视频 + 书混编：合集有 2 个成员，视频成员是子篇；书成员不属视频域。
          _item(3, 'video', 'video/mixed'),
          _item(3, 'epub', 'book/one'),
        ],
      );
      expect(uids, <String>{'video/mixed'});
    });

    test('空输入 → 空集合', () {
      expect(
        videoUidsInMultiMemberCollections(const <MediaCollectionItemRow>[]),
        isEmpty,
      );
    });

    test('同条目跨多个合集：任一合集成员数 ≥2 即判子篇', () {
      final Set<String> uids = videoUidsInMultiMemberCollections(
        <MediaCollectionItemRow>[
          _item(4, 'video', 'video/both'), // 单成员合集
          _item(5, 'video', 'video/both'), // 双成员合集
          _item(5, 'video', 'video/other'),
        ],
      );
      expect(uids, contains('video/both'));
    });
  });
}
