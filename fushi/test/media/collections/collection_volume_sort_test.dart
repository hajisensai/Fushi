import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_member_view.dart';
import 'package:fushi/src/media/collections/collection_one_key_sort.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-5309：合集「按卷号」（详情页默认排序）、一键整理 / 存为手动顺序、组合成合集
/// 落盘共用的卷号判据。用户实报合集「週に一度クラスメイトを買う話」10 卷正篇 + 9 本
/// BOOK☆WALKER 特典册：以前按显示名码元 natural 比，`『`（U+300E）小于 `週`
/// （U+9031），九本特典册整组排在第 1 卷前面。
void main() {
  const String subA = '～ふたりの時間、言い訳の五千円～';
  const String subB = '～ふたりの秘密は一つ屋根の下～';
  const List<String> fullWidth = <String>[
    '',
    '',
    '２',
    '３',
    '４',
    '５',
    '６',
    '７',
    '８',
    '９',
    '１０',
  ];
  String sub(int v) => v <= 4 ? subA : subB;
  String main(int v) => v == 1
      ? '週に一度クラスメイトを買う話　$subA'
      : '週に一度クラスメイトを買う話${fullWidth[v]}　${sub(v)}';
  String bonus(int v) =>
      '『週に一度クラスメイトを買う話${fullWidth[v]}　${sub(v)}』'
      'BOOK☆WALKER限定書き下ろしショートストーリー';

  // 期望：正篇按卷号，同卷特典册紧跟正篇之后。
  final List<String> expected = <String>[
    main(1),
    for (int v = 2; v <= 10; v++) ...<String>[main(v), bonus(v)],
  ];
  // 合集手动序（加入顺序）：特典册在前，正篇倒序——与「按卷号」结果毫无关系。
  final List<String> input = <String>[
    for (int v = 2; v <= 10; v++) bonus(v),
    for (int v = 10; v >= 1; v--) main(v),
  ];

  CollectionMemberEntry entry(String title, int i) => CollectionMemberEntry(
    row: MediaCollectionItemRow(
      collectionId: 1,
      mediaType: 'epub',
      entryKey: 'uid-$i',
      sortIndex: i,
      pinnedByUser: false,
    ),
    title: title,
    importedAt: i,
  );

  test('详情页「按卷号」：第 1 卷在最前，特典册跟在同卷正篇后面', () {
    final List<CollectionMemberEntry> entries = <CollectionMemberEntry>[
      for (int i = 0; i < input.length; i++) entry(input[i], i),
    ];
    final List<CollectionMemberEntry> arranged = arrangeCollectionMembers(
      entries,
      sort: CollectionMemberSort.volume,
    );
    expect(<String>[
      for (final CollectionMemberEntry e in arranged) e.displayTitle,
    ], expected);
  });

  test('一键整理 / 存为手动顺序（按卷号）与详情页视图同序', () {
    final List<CollectionSortMeta> metas =
        <CollectionSortMeta>[
          for (int i = 0; i < input.length; i++)
            (title: input[i], importedAt: 0, key: 'k$i'),
        ]..sort(
          (CollectionSortMeta a, CollectionSortMeta b) =>
              compareCollectionMembers(a, b, byTitle: true),
        );
    expect(<String>[
      for (final CollectionSortMeta m in metas) m.title,
    ], expected);
  });

  test('组合成合集落盘前的排序同一判据', () {
    expect(
      sortNewCollectionMembersNaturally<String>(
        input,
        titleOf: (String t) => t,
      ),
      expected,
    );
  });

  test('多个系列混在一个合集里：按系列成组、组内按卷号，无系列的书名 natural', () {
    final List<String> titles = <String>[
      '『安達としまむら２』特典SS',
      '安達としまむら10',
      'Bocchi 2',
      '安達としまむら２',
      'Bocchi',
      '安達としまむら',
    ];
    expect(
      sortNewCollectionMembersNaturally<String>(
        titles,
        titleOf: (String t) => t,
      ),
      <String>[
        'Bocchi',
        'Bocchi 2',
        '安達としまむら',
        '安達としまむら２',
        '『安達としまむら２』特典SS',
        '安達としまむら10',
      ],
    );
  });
}
