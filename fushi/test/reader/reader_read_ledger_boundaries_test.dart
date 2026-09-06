import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show absoluteCharOffsetOf, restoreIsInPlace;
import 'package:fushi/src/stats/read_unit_ledger.dart';

/// EPUB 侧「读过」判据的边界表（`docs/plans/2026-09-06-read-unit-ledger.md` 第 2 节）：
///
///  * [absoluteCharOffsetOf]：JS 回传的章内学习单位偏移 → 全书绝对偏移（账本坐标）；
///  * [restoreIsInPlace]：恢复完成是否原位（只换坐标不结算）；
///  * 用 [ReadUnitLedger] 按页面接线（`_refreshProgress` 每次采样 arrive、跳句 leave、
///    原位恢复 rebase、字数补算 reset、导航失败 discard）模拟每一行边界场景，断言
///    交给 `StudyClock.addChars` 的字数。
void main() {
  // 三章书：字数 [1000, 2000, 3000]，章首累计 [0, 1000, 3000]。
  const List<int> counts = <int>[1000, 2000, 3000];
  const List<int> cumulative = <int>[0, 1000, 3000];

  int abs(int chapter, int offset) => absoluteCharOffsetOf(
    chapterCumulativeChars: cumulative,
    chapterCharCounts: counts,
    chapter: chapter,
    charOffset: offset,
  );

  group('absoluteCharOffsetOf：章内偏移 → 全书绝对偏移', () {
    test('章首累计 + 章内偏移', () {
      expect(abs(0, 0), 0);
      expect(abs(0, 345), 345);
      expect(abs(1, 0), 1000);
      expect(abs(1, 1999), 2999);
      expect(abs(2, 3000), 6000);
    });

    test('章内偏移超过本章字数 → clamp 到章末（不越章）', () {
      expect(abs(0, 1200), 1000);
      expect(abs(1, 99999), 3000);
    });

    test('偏移 < 0（JS 拿不到 caret）→ -1，不当章首', () {
      expect(abs(0, -1), -1);
      expect(abs(1, -7), -1);
    });

    test('章越界 / 计数未就绪 → -1', () {
      expect(abs(-1, 10), -1);
      expect(abs(3, 10), -1);
      expect(
        absoluteCharOffsetOf(
          chapterCumulativeChars: const <int>[],
          chapterCharCounts: const <int>[],
          chapter: 0,
          charOffset: 10,
        ),
        -1,
      );
      expect(
        absoluteCharOffsetOf(
          chapterCumulativeChars: cumulative,
          chapterCharCounts: const <int>[1000],
          chapter: 1,
          charOffset: 10,
        ),
        -1,
        reason: '两表长度不齐（计数尚在补算）时按未就绪处理',
      );
    });
  });

  group('restoreIsInPlace：原位恢复判据', () {
    test('同章、偏移相差 ≤ 1 → 原位（重排 / 宽变 / 模式切换）', () {
      expect(
        restoreIsInPlace(
          restoredChapter: 2,
          restoredCharOffset: 500,
          lastChapter: 2,
          lastCharOffset: 500,
        ),
        isTrue,
      );
      expect(
        restoreIsInPlace(
          restoredChapter: 2,
          restoredCharOffset: 501,
          lastChapter: 2,
          lastCharOffset: 500,
        ),
        isTrue,
      );
      expect(
        restoreIsInPlace(
          restoredChapter: 2,
          restoredCharOffset: 499,
          lastChapter: 2,
          lastCharOffset: 500,
        ),
        isTrue,
      );
    });

    test('偏移相差 ≥ 2 → 不是原位（同章跳转）', () {
      expect(
        restoreIsInPlace(
          restoredChapter: 2,
          restoredCharOffset: 502,
          lastChapter: 2,
          lastCharOffset: 500,
        ),
        isFalse,
      );
    });

    test('跨章 → 不是原位（跨章跳转 / 翻章）', () {
      expect(
        restoreIsInPlace(
          restoredChapter: 3,
          restoredCharOffset: 0,
          lastChapter: 2,
          lastCharOffset: 0,
        ),
        isFalse,
      );
    });

    test('恢复锚无效（-1）→ 不是原位（分数口径导航）', () {
      expect(
        restoreIsInPlace(
          restoredChapter: 2,
          restoredCharOffset: -1,
          lastChapter: 2,
          lastCharOffset: -1,
        ),
        isFalse,
      );
    });

    test('没有过实时采样（null）/ 上次采样无锚 → 不是原位', () {
      expect(
        restoreIsInPlace(
          restoredChapter: 0,
          restoredCharOffset: 0,
          lastChapter: null,
          lastCharOffset: null,
        ),
        isFalse,
      );
      expect(
        restoreIsInPlace(
          restoredChapter: 0,
          restoredCharOffset: 0,
          lastChapter: 0,
          lastCharOffset: -1,
        ),
        isFalse,
      );
    });
  });

  group('账本模拟：计划文档第 2 节边界表', () {
    late int credited;
    late ReadUnitLedger ledger;

    setUp(() {
      credited = 0;
      ledger = ReadUnitLedger(
        onCredit: (List<(int, int)> fresh) =>
            credited += readUnitsLength(fresh),
      );
    });

    /// 页面接线：`_refreshProgress` 拿到 (章, start, end) 后的 arrive 门。
    void sample(int chapter, int start, int end) {
      final int s = abs(chapter, start);
      final int e = abs(chapter, end);
      if (s >= 0 && e > s) ledger.arrive(s, e);
    }

    test('顺序读到章末翻入下一章：末页在新章首页 arrive 时结算，章边界透明', () {
      sample(0, 0, 400);
      sample(0, 400, 800);
      expect(credited, 400);
      sample(0, 800, 1000); // 章末页
      expect(credited, 800);
      sample(1, 0, 500); // 翻入下一章首页
      expect(credited, 1000, reason: '末页 [800,1000) 在新章首页到达时结算');
      sample(1, 500, 1000);
      expect(credited, 1500, reason: '新章首页翻走时全额计');
    });

    test('章末页 JS 报 end 超章字数：clamp 到章末，不吞下一章', () {
      sample(0, 800, 1500);
      sample(1, 0, 400);
      expect(credited, 200);
    });

    test('往回翻到上一章：并集已覆盖 → 0；越过此前最远处才计', () {
      sample(0, 600, 1000);
      sample(1, 0, 400);
      sample(1, 400, 800); // 已计 600..1400
      expect(credited, 800);
      sample(1, 0, 400); // 回翻：结算 [1400,1800)
      expect(credited, 1200);
      sample(0, 600, 1000); // 回到上一章末页：结算 [1000,1400) 已覆盖
      expect(credited, 1200);
      sample(1, 0, 400); // 再前翻：结算 [600,1000) 已覆盖
      sample(1, 400, 800); // 结算 [1000,1400) 已覆盖
      sample(1, 800, 1200); // 结算 [1400,1800) 已覆盖
      expect(credited, 1200);
      sample(1, 1200, 1600); // 结算 [1800,2200)：新页
      expect(credited, 1600);
    });

    test('目录 / 进度条 / 搜索 / 收藏跳转：跳走前那页计、跳过的不计、落点页翻走时计', () {
      sample(0, 0, 400);
      // 跳转（页面不做任何账本动作），落点直接 arrive。
      sample(2, 1000, 1400);
      expect(credited, 400, reason: '跳走前那页 [0,400) 计入');
      sample(2, 1400, 1800);
      expect(credited, 800, reason: '落点页翻走时计；被跳过的 [400,4000) 从未成为当前单元');
    });

    test('听书显式跳句：leave() 结算当前页，跳过的段落不计', () {
      sample(0, 0, 400);
      ledger.leave(); // onExplicitCueJump
      expect(credited, 400);
      sample(0, 700, 1000); // 跟随滚动落到目标 cue
      expect(credited, 400, reason: '到达不计，[400,700) 不计');
      sample(1, 0, 300);
      expect(credited, 700);
    });

    test('听书跳句回到上一句（后跳）：目标页已在并集 → 翻走时 0', () {
      sample(0, 0, 400);
      sample(0, 400, 800);
      ledger.leave();
      expect(credited, 800);
      sample(0, 0, 400);
      sample(0, 400, 800);
      expect(credited, 800);
    });

    test('改字号 / 旋屏 / 分页↔连续（原位恢复）：rebase 后同页换边界不结算', () {
      sample(0, 0, 400);
      ledger.rebaseOnNextArrive(); // _onRestoreComplete 判原位
      sample(0, 0, 520); // 缩字号后同页多露出的行
      expect(credited, 0, reason: '同页换坐标不是翻页');
      expect(ledger.current, (0, 520));
      sample(0, 520, 1000);
      expect(credited, 520, reason: '多露出的行属新单元，翻走时计');
    });

    test('rebase 后落到的不是同一页（判据误判兜底）：单元换成新坐标、旧单元不结算', () {
      sample(0, 0, 400);
      ledger.rebaseOnNextArrive();
      sample(1, 0, 400);
      expect(credited, 0);
      expect(ledger.current, (1000, 1400));
    });

    test('首次开书 / 恢复到存档页：存档页是当前单元，翻走时计一次，不预置', () {
      sample(1, 600, 1000); // 存档页
      expect(credited, 0);
      expect(ledger.coverage.isEmpty, isTrue, reason: '不预置存档页之前的正文');
      sample(1, 1000, 1400);
      expect(credited, 400);
    });

    test('纯图片章 / 封面：snapshot == null 不 arrive，账本不动', () {
      sample(0, 800, 1000);
      // 图片章：页面不调 arrive。
      sample(2, 0, 400);
      expect(credited, 200);
    });

    test('内容就绪兜底超时 / 导航失败：discard() 当前单元不结算', () {
      sample(0, 0, 400);
      ledger.discard();
      expect(credited, 0);
      sample(1, 0, 400);
      expect(credited, 0, reason: '丢弃的单元不在并集里也不结算');
      sample(1, 400, 800);
      expect(credited, 400);
    });

    test('章字数后台补算落定：reset() 清并集 + 丢当前，之后从头起单元', () {
      sample(0, 0, 400);
      sample(0, 400, 800);
      expect(credited, 400);
      ledger.reset();
      expect(ledger.coverage.isEmpty, isTrue);
      expect(ledger.current, isNull);
      sample(0, 0, 400); // 新口径下同一页：到达不计
      expect(credited, 400);
      sample(0, 400, 800);
      expect(credited, 800, reason: '旧口径的并集不再有意义，新坐标下重新计');
    });

    test('连续模式惯性滚动：每次落定采样一个单元，相邻重叠只计新露出', () {
      sample(0, 0, 500);
      sample(0, 300, 800);
      sample(0, 600, 1100); // end clamp 到 1000
      expect(credited, 800);
      sample(1, 0, 500);
      expect(credited, 1000);
    });

    test('JS 拿不到终点（三段协议 / 探测失败，end = -1）：不 arrive，宁可不计', () {
      sample(0, 0, -1);
      expect(ledger.current, isNull);
      sample(0, 400, 800);
      expect(credited, 0);
      sample(0, 800, 1000);
      expect(credited, 400);
    });

    test('JS 拿不到起点（start = -1）：不 arrive，也不把章首当起点', () {
      sample(0, -1, 400);
      expect(ledger.current, isNull);
    });

    test('end <= start（探测倒挂）：不 arrive', () {
      sample(0, 400, 400);
      sample(0, 400, 300);
      expect(ledger.current, isNull);
    });

    test('关书：leave() 结算最后一页，同一会话对象不再复用', () {
      sample(0, 0, 400);
      sample(0, 400, 800);
      ledger.leave();
      expect(credited, 800);
      expect(ledger.current, isNull);
    });
  });
}
