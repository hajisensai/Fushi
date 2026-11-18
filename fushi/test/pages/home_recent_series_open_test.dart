import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/shelf_collection_open_request.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_page.dart';

/// 设计稿 H8：首页「最近添加」系列合并卡点开去哪——同属合集进合集详情页，
/// 仅按书名系列键归的组打开卷号最小的一卷；以及首页 → 书架 / 漫画库的打开请求。
MediaItem _book(String key) => MediaItem(
  mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(key),
  title: key,
  mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
  mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey,
  position: 0,
  duration: 100,
  canDelete: false,
  canEdit: true,
);

({MediaItem item, String title}) _vol(String title) =>
    (item: _book(title), title: title);

void main() {
  group('recentBookGroupTarget', () {
    test('两卷以上且同属合集 → 进合集', () {
      final RecentBookGroupTarget target = recentBookGroupTarget(
        group: <({MediaItem item, String title})>[
          _vol('志乃と恋 3'),
          _vol('志乃と恋 2'),
        ],
        collectionId: 42,
      );
      expect(target, isA<RecentBookGroupCollection>());
      expect((target as RecentBookGroupCollection).collectionId, 42);
    });

    test('没有合集（仅按系列键归组）→ 打开卷号最小的一卷', () {
      final List<({MediaItem item, String title})> group =
          <({MediaItem item, String title})>[
            _vol('志乃と恋 4'),
            _vol('志乃と恋 2'),
            _vol('志乃と恋 3'),
          ];
      final RecentBookGroupTarget target = recentBookGroupTarget(
        group: group,
        collectionId: null,
      );
      expect(target, isA<RecentBookGroupVolume>());
      expect((target as RecentBookGroupVolume).item, same(group[1].item));
    });

    test('合集里只新加了一卷 → 仍打开那一卷（散卡）', () {
      final ({MediaItem item, String title}) only = _vol('志乃と恋 5');
      final RecentBookGroupTarget target = recentBookGroupTarget(
        group: <({MediaItem item, String title})>[only],
        collectionId: 7,
      );
      expect((target as RecentBookGroupVolume).item, same(only.item));
    });
  });

  group('recentBookGroupFirstVolume', () {
    test('解析不出卷号的沉底；卷号相同取较新加入的（列表在前的）', () {
      final List<({MediaItem item, String title})> group =
          <({MediaItem item, String title})>[
            _vol('志乃と恋 外伝'),
            _vol('志乃と恋 第2巻'),
            _vol('志乃と恋 2'),
          ];
      expect(recentBookGroupFirstVolume(group).item, same(group[1].item));
    });

    test('书店写法「卷号<系列名> (文库名)」也按卷号挑（BUG-4904）', () {
      const String rezero = 'Re：ゼロから始める異世界生活';
      final List<({MediaItem item, String title})> group =
          <({MediaItem item, String title})>[
            _vol('$rezero 3<$rezero> (MF文庫J)'),
            _vol('$rezero 1<$rezero> (MF文庫J)'),
            _vol('$rezero 2<$rezero> (MF文庫J)'),
          ];
      expect(recentBookGroupFirstVolume(group).item, same(group[1].item));
    });
  });

  group('shelfCollectionOpenRequest', () {
    tearDown(() => shelfCollectionOpenRequest.value = null);

    test('只由对应实例接单，接走后清空', () {
      requestShelfCollectionOpen(collectionId: 9, manga: false);
      expect(takeShelfCollectionOpenRequest(manga: true), isNull);
      expect(shelfCollectionOpenRequest.value, isNotNull, reason: '漫画库不接书架的单');
      expect(takeShelfCollectionOpenRequest(manga: false), 9);
      expect(shelfCollectionOpenRequest.value, isNull);
      expect(takeShelfCollectionOpenRequest(manga: false), isNull);
    });

    test('新请求覆盖未接走的旧请求，并通知订阅者', () {
      int notified = 0;
      void listener() => notified++;
      shelfCollectionOpenRequest.addListener(listener);
      addTearDown(() => shelfCollectionOpenRequest.removeListener(listener));
      requestShelfCollectionOpen(collectionId: 1, manga: true);
      requestShelfCollectionOpen(collectionId: 2, manga: true);
      expect(notified, 2);
      expect(takeShelfCollectionOpenRequest(manga: true), 2);
    });
  });
}
