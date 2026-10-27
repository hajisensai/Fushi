import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart';

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

    test('BUG-3347：全角数字与半角数字同一把数值尺（用户漫画库实际书名）', () {
      // 「志乃と恋 ２」「志乃と恋 ４」是全角数字，「志乃と恋 3」是半角——旧实现按
      // 码元比，'3'(0x33) < '２'(0xFF12)，排成 3 < ２ < ４。
      final List<String> titles = <String>[
        '志乃と恋 ４',
        '志乃と恋 3',
        '志乃と恋',
        '志乃と恋 ２',
        '志乃と恋　10',
      ]..sort(naturalCompare);
      expect(titles, <String>[
        '志乃と恋',
        '志乃と恋 ２',
        '志乃と恋 3',
        '志乃と恋 ４',
        '志乃と恋　10',
      ]);
      expect(naturalCompare('第２卷', '第10卷'), lessThan(0));
      expect(naturalCompare('ＡＢＣ', 'abd'), lessThan(0), reason: '全角字母同样折半角');
    });
  });

  test('BUG-3347：书架排序键的名称取卡片显示名（改名覆盖层），不读 DB 原始列', () {
    // 用户改名「志乃と恋 [3574f94a]」→「志乃と恋」后，按原名排序会把它排到
    // 「志乃と恋 3」之后（'3' < '['），卡片上看就是乱序。
    final String source = File(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    ).readAsStringSync();
    final int start = source.indexOf('ShelfSortKey _shelfGroupSortKey(');
    expect(start, isNonNegative);
    final String titleOf = source.substring(
      source.indexOf('String titleOf(', start),
      source.indexOf('int recentOf(', start),
    );
    expect(titleOf, contains('displayTitleForBook('));
    expect(titleOf, isNot(contains('s.epub?.title')));
    expect(titleOf, isNot(contains('s.srt?.title')));
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

  group('手动排序（排序模式拖出来的顺序）', () {
    test('有名次按名次升序；没名次的排在前面、彼此按导入时间倒序', () {
      final Map<String, int> ranks = <String, int>{'b': 0, 'a': 1};
      int cmp(ShelfSortKey x, ShelfSortKey y) => compareShelfSortKeys(
            x,
            y,
            ShelfSortMode.manual,
            manualRanks: ranks,
          );
      expect(cmp(_key(tieKey: 'b'), _key(tieKey: 'a')), lessThan(0));
      expect(
        cmp(_key(tieKey: 'new', importedAt: 1), _key(tieKey: 'b')),
        lessThan(0),
        reason: '排好之后新导入的不沉底',
      );
      expect(
        cmp(
          _key(tieKey: 'n2', importedAt: 9),
          _key(tieKey: 'n1', importedAt: 3),
        ),
        lessThan(0),
      );
    });

    test('持久化往返保序，tieKey 里的逗号不切断', () {
      const List<String> order = <String>['c1', 'a,b|x', 'k'];
      final Map<String, int> ranks =
          decodeShelfManualOrder(encodeShelfManualOrder(order));
      expect(ranks, <String, int>{'c1': 0, 'a,b|x': 1, 'k': 2});
      expect(decodeShelfManualOrder(''), isEmpty);
    });

    test('一次拖动：可见槽按新序回填，被筛掉的单元原位不动', () {
      expect(
        moveInShelfManualOrder(
          all: <String>['a', 'h1', 'b', 'h2', 'c'],
          visible: <String>['a', 'b', 'c'],
          from: 0,
          to: 2,
        ),
        <String>['b', 'h1', 'c', 'h2', 'a'],
      );
      expect(
        moveInShelfManualOrder(
          all: <String>['a', 'b'],
          visible: <String>['a', 'b'],
          from: 5,
          to: 0,
        ),
        <String>['a', 'b'],
        reason: '越界 from 原样返回',
      );
    });

    test('fromName 认得 manual', () {
      expect(ShelfSortMode.fromName('manual'), ShelfSortMode.manual);
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

  group('classifyShelfReadStatus（书架 / 漫画库阅读状态筛选判据）', () {
    ShelfReadStatus classify({
      bool completed = false,
      required int position,
      required int duration,
    }) => classifyShelfReadStatus(
      completed: completed,
      position: position,
      duration: duration,
    );

    test('显式读完标记不受进度约束（停在 99% 的手动标记书）', () {
      expect(
        classify(completed: true, position: 99, duration: 100),
        ShelfReadStatus.finished,
      );
      expect(
        classify(completed: true, position: 0, duration: 0),
        ShelfReadStatus.finished,
      );
    });

    test('进度到底 = 读完；中途 = 在读；没翻开 = 未读', () {
      expect(classify(position: 100, duration: 100), ShelfReadStatus.finished);
      expect(classify(position: 30, duration: 100), ShelfReadStatus.reading);
      expect(classify(position: 0, duration: 100), ShelfReadStatus.unread);
    });

    test('没有进度维度（纯字幕书 / 无配对 EPUB 的有声书）归未读', () {
      expect(classify(position: 0, duration: 0), ShelfReadStatus.unread);
      expect(classify(position: 5, duration: 0), ShelfReadStatus.unread);
    });

    test('与概览统计同一口径：tally 的在读 / 读完计数等于逐条分类计数', () {
      final List<({bool done, int pos, int dur})> books =
          <({bool done, int pos, int dur})>[
            (done: false, pos: 0, dur: 100),
            (done: false, pos: 40, dur: 100),
            (done: false, pos: 100, dur: 100),
            (done: true, pos: 10, dur: 100),
            (done: false, pos: 0, dur: 0),
          ];
      final ShelfProgressTally<({bool done, int pos, int dur})> tally =
          tallyShelfProgress<({bool done, int pos, int dur})>(
            books,
            (b) => b.pos,
            (b) => b.dur,
            isCompleted: (b) => b.done,
          );
      int countOf(ShelfReadStatus status) => books
          .where(
            (b) =>
                classify(completed: b.done, position: b.pos, duration: b.dur) ==
                status,
          )
          .length;
      expect(tally.reading, countOf(ShelfReadStatus.reading));
      expect(tally.finished, countOf(ShelfReadStatus.finished));
      expect(tally.reading, 1);
      expect(tally.finished, 2);
    });

    test('书架「继续阅读」hero 的统计传了读完判据（已读完筛选下不再顶出读完的书）', () {
      final String source = File(
        'lib/src/pages/implementations/reader_fushi_history_page.dart',
      ).readAsStringSync();
      final int call = source.indexOf('tallyShelfProgress<MediaItem>(');
      expect(call, isNonNegative);
      final String args = source.substring(call, source.indexOf(');', call));
      expect(args, contains('isCompleted:'));
      expect(args, contains('_completedBookKeys.contains('));
    });
  });
}
