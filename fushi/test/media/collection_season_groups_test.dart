import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_season_groups.dart';

/// 合集内分季：分组键派生 / 多组判定 / 分节 / tab 展示序 / 按季重排 纯函数契约。
/// 分组是**文件名的纯函数、不落库**（曾试过 schema 列的方案已撤销）。
void main() {
  group('collectionSeasonGroupKey', () {
    test('有集号无季号 → 视作第 1 季（与排序 null 视作 1 同口径）', () {
      expect(collectionSeasonGroupKey(season: null, episode: 5), 's1');
    });
    test('有季有集 → s<季号>', () {
      expect(collectionSeasonGroupKey(season: 2, episode: 1), 's2');
    });
    test('无集号 → PV/特典组', () {
      expect(
        collectionSeasonGroupKey(season: 1, episode: null),
        kCollectionExtrasGroupKey,
      );
    });
  });

  group('collectionGroupKeyForFilename', () {
    test('S02E01 → s2；季内集号不受首季长度影响', () {
      expect(
        collectionGroupKeyForFilename('Adachi to Shimamura S02E01.mkv'),
        's2',
      );
    });
    test('裸集号（无季记号）→ s1', () {
      expect(collectionGroupKeyForFilename('Adachi to Shimamura 05.mkv'), 's1');
    });
    test('解析不出集号 → extras', () {
      expect(
        collectionGroupKeyForFilename('Special Preview.mkv'),
        kCollectionExtrasGroupKey,
      );
    });
    test('带路径也只按文件名解析', () {
      expect(
        collectionGroupKeyForFilename(r'D:\anime\show\Show S03E04.mkv'),
        's3',
      );
    });
  });

  group('collectionGroupKeyForFilename：季标记形态（BUG-1543）', () {
    test('「标题 2 - 集号」与第 1 季分到不同组（用户实测的 Hibike! Euphonium）', () {
      expect(
        collectionGroupKeyForFilename(
          'Hibike! Euphonium - 01 (BD 1280x720 x264 AACx3).mkv',
        ),
        's1',
      );
      expect(
        collectionGroupKeyForFilename(
          'Hibike! Euphonium 2 - 01 (BD 1280x720 x264 AAC).mkv',
        ),
        's2',
      );
      expect(
          collectionGroupKeyForFilename('Hibike! Euphonium 3 - 05.mkv'), 's3');
    });

    test('多季混排 → isMultiSeasonGrouped 为真（详情页据此出季 tab）', () {
      expect(
        isMultiSeasonGrouped(<String>[
          for (final String f in <String>[
            'Hibike! Euphonium - 01.mkv',
            'Hibike! Euphonium - 02.mkv',
            'Hibike! Euphonium 2 - 01.mkv',
          ])
            collectionGroupKeyForFilename(f),
        ]),
        true,
      );
    });

    test('季号只写在父目录上（Season 2 / S02）时按目录归季', () {
      expect(
        collectionGroupKeyForFilename('/media/Show/Season 2/Show - 01.mkv'),
        's2',
      );
      expect(collectionGroupKeyForFilename(r'D:\anime\Show\S03\01.mkv'), 's3');
      expect(
        collectionGroupKeyForFilename('/media/Show/Hibike! Euphonium 2/01.mkv'),
        's2',
      );
    });

    test('文件名自带季号时目录不参与（文件名优先）', () {
      expect(
        collectionGroupKeyForFilename('/media/Show/Season 2/Show S01E04.mkv'),
        's1',
      );
    });

    test('无集号（PV/特典/电影）时目录季号不生效，仍归 extras', () {
      expect(
        collectionGroupKeyForFilename('/media/Ip Man 2/Ip Man 2.mkv'),
        kCollectionExtrasGroupKey,
      );
    });
  });

  group('seasonNumberOfGroupKey', () {
    test('s2 → 2', () => expect(seasonNumberOfGroupKey('s2'), 2));
    test('extras → null',
        () => expect(seasonNumberOfGroupKey(kCollectionExtrasGroupKey), null));
    test('裸 s → null', () => expect(seasonNumberOfGroupKey('s'), null));
  });

  group('isMultiSeasonGrouped', () {
    test('空 → false',
        () => expect(isMultiSeasonGrouped(const <String>[]), false));
    test('单组（单季/纯电影/全 PV）→ false', () {
      expect(isMultiSeasonGrouped(const <String>['s1', 's1']), false);
    });
    test('两组 → true', () {
      expect(isMultiSeasonGrouped(const <String>['s1', 's2']), true);
    });
    test('季 + PV 两组也算多组', () {
      expect(
        isMultiSeasonGrouped(const <String>['s1', kCollectionExtrasGroupKey]),
        true,
      );
    });
  });

  group('buildCollectionSeasonSections', () {
    test('按组键首次出现顺序聚合，组内保持相对序', () {
      final List<CollectionSeasonSection<String>> sections =
          buildCollectionSeasonSections<String>(
        members: <String>['a1', 'a2', 'b1', 'a3', 'c1'],
        keyOf: (String m) => switch (m[0]) {
          'a' => 's1',
          'b' => 's2',
          _ => kCollectionExtrasGroupKey,
        },
      );
      expect(sections.map((s) => s.groupKey), <String>['s1', 's2', 'extras']);
      expect(sections[0].items, <String>['a1', 'a2', 'a3']);
      expect(sections[1].items, <String>['b1']);
      expect(sections[2].items, <String>['c1']);
    });
  });

  group('sortCollectionSeasonSections（季 tab 展示序）', () {
    List<CollectionSeasonSection<String>> sectionsOf(List<String> keys) =>
        <CollectionSeasonSection<String>>[
          for (final String k in keys)
            CollectionSeasonSection<String>(groupKey: k, items: <String>[k]),
        ];

    test('季号升序、PV/特典殿后（首次出现序乱序也纠正）', () {
      expect(
        sortCollectionSeasonSections<String>(
          sectionsOf(<String>['s2', 'extras', 's1', 's10']),
        ).map((CollectionSeasonSection<String> s) => s.groupKey),
        <String>['s1', 's2', 's10', 'extras'],
      );
    });

    test('只重排分节，不动节内成员相对序', () {
      final List<CollectionSeasonSection<String>> sorted =
          sortCollectionSeasonSections<String>(
        <CollectionSeasonSection<String>>[
          const CollectionSeasonSection<String>(
              groupKey: 's2', items: <String>['b1', 'b2']),
          const CollectionSeasonSection<String>(
              groupKey: 's1', items: <String>['a2', 'a1']),
        ],
      );
      expect(sorted[0].items, <String>['a2', 'a1']);
      expect(sorted[1].items, <String>['b1', 'b2']);
    });

    test('不修改入参列表（调用方持有的分节序不被就地打乱）', () {
      final List<CollectionSeasonSection<String>> input =
          sectionsOf(<String>['s2', 's1']);
      sortCollectionSeasonSections<String>(input);
      expect(input.map((CollectionSeasonSection<String> s) => s.groupKey),
          <String>['s2', 's1']);
    });
  });

  group('regroupMembersBySeason', () {
    test('季→集→标题重排，PV/特典殿后，键与序一致', () {
      final List<String> files = <String>[
        'Show S02E02.mkv',
        'Show PV Special.mkv',
        'Show S02E01.mkv',
        'Show S01E01.mkv',
      ];
      final CollectionSeasonRegroup<String> regroup =
          regroupMembersBySeason<String>(
        members: files,
        filenameOf: (String f) => f,
        titleOf: (String f) => f,
      );
      expect(regroup.ordered, <String>[
        'Show S01E01.mkv',
        'Show S02E01.mkv',
        'Show S02E02.mkv',
        'Show PV Special.mkv',
      ]);
      expect(regroup.keyOf['Show S01E01.mkv'], 's1');
      expect(regroup.keyOf['Show S02E01.mkv'], 's2');
      expect(
        regroup.keyOf['Show PV Special.mkv'],
        kCollectionExtrasGroupKey,
      );
    });
  });
}
