import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/collections/shelf_sort.dart';

/// 排序交互重设计层次 A：排序模式纯函数（naturalCompare + compareShelfSortKeys）。
ShelfSortKey _key({
  int recentScore = 0,
  String title = '',
  int importedAt = 0,
  String tieKey = '',
}) =>
    ShelfSortKey(
      recentScore: recentScore,
      title: title,
      importedAt: importedAt,
      tieKey: tieKey,
    );

void main() {
  group('naturalCompare', () {
    test('数字段按数值比较：卷1 < 卷2 < 卷10', () {
      expect(naturalCompare('第1卷', '第2卷'), lessThan(0));
      expect(naturalCompare('第2卷', '第10卷'), lessThan(0));
      expect(naturalCompare('第10卷', '第9卷'), greaterThan(0));
    });

    test('前导零按数值等值，靠原文兜底确定性', () {
      expect(naturalCompare('ep01', 'ep1'), isNot(0), reason: '全序必须可定');
      expect(naturalCompare('ep01', 'ep2'), lessThan(0));
      expect(naturalCompare('ep010', 'ep9'), greaterThan(0));
    });

    test('超长数字段不溢出（先长度后逐位）', () {
      expect(
        naturalCompare('a99999999999999999999', 'a100000000000000000000'),
        lessThan(0),
      );
    });

    test('ASCII 不分大小写；完全相同返回 0', () {
      expect(naturalCompare('Abc', 'abC'), isNot(0), reason: '大小写全等兜底原文');
      expect(naturalCompare('abc', 'abd'), lessThan(0));
      expect(naturalCompare('ABC', 'abd'), lessThan(0));
      expect(naturalCompare('same', 'same'), 0);
    });

    test('前缀更短者在前', () {
      expect(naturalCompare('abc', 'abcd'), lessThan(0));
      expect(naturalCompare('第2卷·特典', '第2卷'), greaterThan(0));
    });
  });

  group('compareShelfSortKeys', () {
    test('recent：recentScore 大者在前，退 importedAt，再退名称', () {
      expect(
        compareShelfSortKeys(
          _key(recentScore: 200),
          _key(recentScore: 100),
          ShelfSortMode.recent,
        ),
        lessThan(0),
      );
      expect(
        compareShelfSortKeys(
          _key(recentScore: 100, importedAt: 5),
          _key(recentScore: 100, importedAt: 9),
          ShelfSortMode.recent,
        ),
        greaterThan(0),
      );
      expect(
        compareShelfSortKeys(
          _key(title: 'a'),
          _key(title: 'b'),
          ShelfSortMode.recent,
        ),
        lessThan(0),
      );
    });

    test('title：natural 序，同名退 importedAt 新者在前', () {
      expect(
        compareShelfSortKeys(
          _key(title: '第2卷'),
          _key(title: '第10卷'),
          ShelfSortMode.title,
        ),
        lessThan(0),
      );
      expect(
        compareShelfSortKeys(
          _key(title: 'x', importedAt: 9),
          _key(title: 'x', importedAt: 5),
          ShelfSortMode.title,
        ),
        lessThan(0),
      );
    });

    test('imported：新导入在前，同刻退名称', () {
      expect(
        compareShelfSortKeys(
          _key(importedAt: 9),
          _key(importedAt: 5),
          ShelfSortMode.imported,
        ),
        lessThan(0),
      );
      expect(
        compareShelfSortKeys(
          _key(importedAt: 5, title: 'a'),
          _key(importedAt: 5, title: 'b'),
          ShelfSortMode.imported,
        ),
        lessThan(0),
      );
    });

    test('全键相等靠 tieKey 决出稳定全序', () {
      for (final ShelfSortMode mode in ShelfSortMode.values) {
        expect(
          compareShelfSortKeys(_key(tieKey: 'a'), _key(tieKey: 'b'), mode),
          lessThan(0),
        );
        expect(
          compareShelfSortKeys(_key(tieKey: 'a'), _key(tieKey: 'a'), mode),
          0,
        );
      }
    });
  });

  group('ShelfSortMode.fromName', () {
    test('已知名解析，未知/旧残留退默认 recent', () {
      expect(ShelfSortMode.fromName('title'), ShelfSortMode.title);
      expect(ShelfSortMode.fromName('imported'), ShelfSortMode.imported);
      expect(ShelfSortMode.fromName('recent'), ShelfSortMode.recent);
      expect(ShelfSortMode.fromName('bogus'), ShelfSortMode.recent);
      expect(ShelfSortMode.fromName(''), ShelfSortMode.recent);
    });
  });

  group('tallyShelfProgress（BUG-804：概览统计 + hero 候选含有声书）', () {
    // 测试项 = (position, duration, lastReadAt)；有声书与纯 EPUB 在这一层无区别，
    // 都是有 position/duration 的 EPUB-backed 书——bug 在于旧调用点把有声书从
    // 输入里过滤掉了，这里锁死「只要喂进来就正确分类/入候选」。
    ({int position, int duration, int lastReadAt}) item(
      int position,
      int duration, {
      int lastReadAt = 0,
    }) =>
        (position: position, duration: duration, lastReadAt: lastReadAt);

    test('分类：读完 / 在读 / 无进度维度(duration<=0)跳过 / 未开始(position=0)不计', () {
      final tally = tallyShelfProgress(
        <({int position, int duration, int lastReadAt})>[
          item(100, 100), // 读完
          item(30, 100), // 在读
          item(0, 100), // 未开始（不计在读也不计读完）
          item(5, 0), // duration<=0：无进度维度，跳过
          item(200, 100), // position>=duration 也算读完（越界钳到读完）
        ],
        (it) => it.position,
        (it) => it.duration,
      );
      expect(tally.finished, 2, reason: 'position>=duration 计读完（含越界）');
      expect(tally.reading, 1);
      expect(tally.inProgress.length, 1, reason: '只有真在读的进候选');
      expect(tally.inProgress.single.position, 30);
    });

    test('复现 BUG-804：全量列表里「最近读的有声书」必须能当选 hero', () {
      // 模拟：一本更晚导入的纯 EPUB（在读，lastReadAt 旧）+ 一本有声书（在读，
      // lastReadAt 新——刚听完）。旧实现把有声书过滤出候选，hero 恒选纯 EPUB；
      // 修复后有声书在候选里，按 lastReadAt 胜出。
      final List<({int position, int duration, int lastReadAt})> allEpubBacked =
          <({int position, int duration, int lastReadAt})>[
        item(10, 100, lastReadAt: 100), // 纯 EPUB，较早读
        item(40, 100, lastReadAt: 500), // 有声书，刚听完（最近）
      ];
      final tally = tallyShelfProgress(
        allEpubBacked,
        (it) => it.position,
        (it) => it.duration,
      );
      expect(tally.inProgress.length, 2, reason: '有声书不得被排除在候选外');
      final hero = mostRecentlyReadCandidate(
        tally.inProgress,
        (it) => it.lastReadAt,
      );
      expect(hero?.lastReadAt, 500, reason: '刚听完的有声书必须赢过更早读的纯 EPUB');
    });

    test('空/全无进度 → 无候选（hero 整块只剩统计）', () {
      final tally = tallyShelfProgress(
        <({int position, int duration, int lastReadAt})>[
          item(0, 100),
          item(3, 0),
        ],
        (it) => it.position,
        (it) => it.duration,
      );
      expect(tally.reading, 0);
      expect(tally.finished, 0);
      expect(tally.inProgress, isEmpty);
    });

    test('isCompleted：手动标记的书计读完，不受进度约束、不进在读候选', () {
      // 用户诉求：跳过后记/附录进度停在 99% 的书，手动标记后必须计入 Completed。
      final List<({int position, int duration, int lastReadAt})> books =
          <({int position, int duration, int lastReadAt})>[
        item(99, 100, lastReadAt: 5), // 99%，若被标记完成 → 读完（否则在读）
        item(30, 100), // 在读、未标记
        item(0, 100), // 未开始，但被标记完成 → 仍计读完
      ];
      final tally = tallyShelfProgress(
        books,
        (it) => it.position,
        (it) => it.duration,
        // 第 0、2 本被标记完成（按 lastReadAt 区分：这里用 position 当身份代理）。
        isCompleted: (it) => it.position == 99 || it.position == 0,
      );
      expect(tally.finished, 2, reason: '两本标记完成的都计读完（含 position=0）');
      expect(tally.reading, 1, reason: '只有未标记的 30% 那本在读');
      expect(tally.inProgress.single.position, 30,
          reason: '标记完成的不进在读候选，即使进度 99%');
    });

    test('isCompleted 为 null → 退回纯进度派生（旧行为向后兼容）', () {
      final tally = tallyShelfProgress(
        <({int position, int duration, int lastReadAt})>[
          item(100, 100),
          item(30, 100),
        ],
        (it) => it.position,
        (it) => it.duration,
      );
      expect(tally.finished, 1);
      expect(tally.reading, 1);
    });
  });
}
