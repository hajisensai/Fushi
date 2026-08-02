import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/collections/collection_one_key_sort.dart';

/// BUG-1436：批量「组合成合集」此前直接按选择集（`Set<String>`，迭代序 = 点选/
/// 框选顺序）逐条 `addToCollection`，sortIndex 就此定型——用户框选一整季建出来的
/// 合集，「选集」列表是乱的（E09、E10、E07、E12…），必须再手动跑一次「一键整理」。
///
/// [sortNewCollectionMembersNaturally] 是三个库页共用的落盘前排序真相源。
void main() {
  group('sortNewCollectionMembersNaturally', () {
    test('点选顺序被自然序取代（S01E02 < S01E10）', () {
      const List<String> picked = <String>[
        'Show.S01E09.出店してみますか!.WEBRip.mkv',
        'Show.S01E10.ただいま.WEBRip.mkv',
        'Show.S01E07.ずっと忘れないと思う.WEBRip.mkv',
        'Show.S01E02.この子は星なな.WEBRip.mkv',
      ];
      final List<String> sorted = sortNewCollectionMembersNaturally<String>(
        picked,
        titleOf: (String s) => s,
      );
      expect(sorted, <String>[
        'Show.S01E02.この子は星なな.WEBRip.mkv',
        'Show.S01E07.ずっと忘れないと思う.WEBRip.mkv',
        'Show.S01E09.出店してみますか!.WEBRip.mkv',
        'Show.S01E10.ただいま.WEBRip.mkv',
      ]);
    });

    test('卷号按数值而非字典序（卷2 < 卷10）', () {
      final List<String> sorted = sortNewCollectionMembersNaturally<String>(
        <String>['某系列 第10巻', '某系列 第2巻', '某系列 第1巻'],
        titleOf: (String s) => s,
      );
      expect(sorted, <String>['某系列 第1巻', '某系列 第2巻', '某系列 第10巻']);
    });

    test('标题相同 → 保持输入序（List.sort 非稳定，需下标兜底）', () {
      final List<({String id, String title})> items =
          <({String id, String title})>[
        (id: 'c', title: '同名'),
        (id: 'a', title: '同名'),
        (id: 'b', title: '同名'),
      ];
      final List<({String id, String title})> sorted =
          sortNewCollectionMembersNaturally<({String id, String title})>(
        items,
        titleOf: (({String id, String title}) e) => e.title,
      );
      expect(
        sorted.map((({String id, String title}) e) => e.id).toList(),
        <String>['c', 'a', 'b'],
      );
    });

    test('空表与单元素不炸', () {
      expect(
        sortNewCollectionMembersNaturally<String>(
          const <String>[],
          titleOf: (String s) => s,
        ),
        isEmpty,
      );
      expect(
        sortNewCollectionMembersNaturally<String>(
          const <String>['only'],
          titleOf: (String s) => s,
        ),
        <String>['only'],
      );
    });

    test('不改入参列表（调用方仍持原点选序）', () {
      final List<String> input = <String>['b', 'a'];
      sortNewCollectionMembersNaturally<String>(input,
          titleOf: (String s) => s);
      expect(input, <String>['b', 'a']);
    });
  });
}
