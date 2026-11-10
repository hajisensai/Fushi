import 'package:fushi/src/stats/lyrics_read_unit.dart';
import 'package:fushi/src/stats/read_unit_ledger.dart';
import 'package:test/test.dart';

/// 歌词模式的统计口径（2026-11-10 所有者拍板：歌词模式是独立模式，单独一套统计，
/// 尽量贴近阅读器）：单元 = 当前句，账本与正文是同一本 `ReadUnitLedger`。
///
/// 这里钉的是**行为**：把「一本书 = 两章、每句 10 个学习单位」按歌词模式的接线喂给
/// 真账本，看入账额。
void main() {
  // 两章：第 0 章 100 字、第 1 章 60 字。
  const List<int> counts = <int>[100, 60];
  const List<int> cumulative = <int>[0, 100];

  (int, int)? unit(int chapter, int offset, [int length = 10]) =>
      lyricsCueReadUnit(
        chapterCumulativeChars: cumulative,
        chapterCharCounts: counts,
        chapter: chapter,
        offset: offset,
        length: length,
      );

  group('lyricsCueReadUnit 坐标换算', () {
    test('章内句子 → 全书绝对区间', () {
      expect(unit(0, 20), (20, 30));
      expect(unit(1, 0), (100, 110));
      expect(unit(1, 50), (150, 160));
    });

    test('越过章尾的部分夹到章尾', () {
      expect(unit(0, 95, 20), (95, 100));
    });

    test('解不出的一律 null（不计）', () {
      expect(unit(-1, 0), isNull);
      expect(unit(2, 0), isNull, reason: '章号越界');
      expect(unit(0, -1), isNull);
      expect(unit(0, 10, 0), isNull, reason: '空句');
      expect(unit(0, 100), isNull, reason: '起点已在章尾之外');
      expect(
        lyricsCueReadUnit(
          chapterCumulativeChars: const <int>[],
          chapterCharCounts: const <int>[],
          chapter: 0,
          offset: 0,
          length: 10,
        ),
        isNull,
        reason: '章字数表未就绪',
      );
    });
  });

  group('歌词模式按句入账（真账本）', () {
    late int credited;
    late List<int> deltas;
    late ReadUnitLedger ledger;

    void arriveCue(int chapter, int offset, [int length = 10]) {
      final (int, int)? range = unit(chapter, offset, length);
      if (range == null) return;
      ledger.arrive(range.$1, range.$2);
    }

    setUp(() {
      credited = 0;
      deltas = <int>[];
      ledger = ReadUnitLedger(
        onCredit: (List<(int, int)> fresh) {
          final int n = readUnitsLength(fresh);
          credited += n;
          deltas.add(n);
        },
        onRetract: (List<(int, int)> retracted) {
          final int n = readUnitsLength(retracted);
          credited -= n;
          deltas.add(-n);
        },
      );
    });

    test('顺着听：每换一句入账上一句，字数按句流入而不是整页跳涨', () {
      arriveCue(0, 0);
      expect(credited, 0, reason: '站着的这一句还没翻走，不计');
      arriveCue(0, 10);
      arriveCue(0, 20);
      arriveCue(0, 30);
      expect(credited, 30);
      expect(deltas, <int>[10, 10, 10], reason: '一句一笔，没有攒到一起的大额入账');
    });

    test('跨章照常：章尾句在进下一章首句时入账', () {
      arriveCue(0, 90);
      arriveCue(1, 0);
      expect(credited, 10);
      arriveCue(1, 10);
      expect(credited, 20);
    });

    test('回听撤回，再听过去按并集恢复、不重复计', () {
      arriveCue(0, 0);
      arriveCue(0, 10);
      arriveCue(0, 20);
      arriveCue(0, 30);
      expect(credited, 30);
      // 拖回第 2 句（offset 10）：其后已入账的撤回。
      arriveCue(0, 10);
      expect(credited, 10);
      // 再听过去：恢复，不超过原先的额度。
      arriveCue(0, 20);
      arriveCue(0, 30);
      arriveCue(0, 40);
      expect(credited, 40);
    });

    test('往前跳：跳过的句子不计，只计跳走前那一句', () {
      arriveCue(0, 0);
      arriveCue(0, 10);
      // 点行 / 拖进度跳到第 8 句。
      arriveCue(0, 70);
      expect(credited, 20, reason: '0-10、10-20 两句；20-70 从未成为当前句');
      arriveCue(0, 80);
      expect(credited, 30);
    });

    test('重播同一句不入账；映射不出的句子保持上一句不动', () {
      arriveCue(0, 0);
      arriveCue(0, 0);
      expect(credited, 0);
      // 没匹配上正文的句子（null → 不 arrive）：当前单元仍是上一句。
      arriveCue(5, 0);
      expect(ledger.current, (0, 10));
      arriveCue(0, 10);
      expect(credited, 10);
    });

    test('句子之间的缝（没有 cue 认领的正文）不计', () {
      arriveCue(0, 0);
      // 第二句从 25 开始：[10, 25) 没有句子认领。
      arriveCue(0, 25);
      arriveCue(0, 35);
      expect(credited, 20, reason: '只计 [0,10) 与 [25,35)');
    });

    test('进歌词：正文那页在离开时结算，站到当前句后只留句首之前的部分', () {
      // 正文站在页 [0, 50)，音频当前句在 [20, 30)。
      ledger.arrive(0, 50);
      ledger.leave(); // 进歌词：离开正文页
      expect(credited, 50);
      arriveCue(0, 20); // 当前句成为单元
      expect(credited, 20, reason: '读到当前句为止：[0, 20)');
      arriveCue(0, 30);
      arriveCue(0, 40);
      expect(credited, 40, reason: '页内后续句子随位置推进按并集恢复 + 新句入账');
      arriveCue(0, 50);
      arriveCue(0, 60);
      expect(credited, 60, reason: '走出那一页之后照常按句入账，不双计');
    });

    test('出歌词：离开当前句，正文落到含该句的页，翻走这页时总额不双计', () {
      arriveCue(0, 0);
      arriveCue(0, 10);
      arriveCue(0, 20);
      expect(credited, 20);
      ledger.leave(); // 出歌词：离开当前句 [20, 30)
      expect(credited, 30);
      // 正文落到含当前句的页 [0, 50)：站着的这页此刻不计（与正文口径一致）。
      ledger.arrive(0, 50);
      expect(credited, 0);
      // 翻走这页：整页入账，歌词里听过的三句不重复计。
      ledger.arrive(50, 100);
      expect(credited, 50);
    });
  });
}
