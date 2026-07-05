import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// TODO-1179「分页模式跳章时开头或末尾一两行被跳过」守卫。
///
/// 手动跳章 charOffset=-1 → setup 走粗粒度 restoreProgress：前进 progress=0.0 落
/// `contentFirstPageScroll`(=minScroll)、后退 progress=0.99 落
/// `contentLastPageScroll`(=maxScroll)。两者的落页取整边界是首/末行是否被跳的唯一
/// 决定因素（`buildPaginationMetrics`）。本测试用纯函数影子
/// `resolveContentBoundsForTesting`（JS 同算法，headless WebView 不可用）锁住：
///   ① 章首落点只能 floor（含首行内容边那页），绝不 round-up 抬一页跳过首行；
///   ② 末页落点在单一量纲 sub-pixel 下溢下仍覆盖真实末行所在页；
///   ③ maxScroll 永不越过末内容页（容差不引入空白末页）。
/// 绝不回退 BUG-169/TODO-729 的粗粒度分数跳页模型——这里只夹落页边界取整。
void main() {
  ({double minScroll, double maxScroll}) bounds({
    required double first,
    required double last,
    required double ctxMax,
    required double pageStep,
  }) =>
      ReaderPaginationScripts.resolveContentBoundsForTesting(
        firstContentEdge: first,
        lastContentEdge: last,
        contextMaxScroll: ctxMax,
        pageStep: pageStep,
      );

  group('章首 minScroll：floor 落含首行页，绝不 round-up 跳首行', () {
    test('普通章首（内容边≈padding）→ minScroll = 0', () {
      const double ps = 815.28;
      final r = bounds(first: 17.36, last: 3339.20, ctxMax: 4000, pageStep: ps);
      expect(r.minScroll, 0, reason: '章首内容边落第 0 页，前进跳章必须显示首行');
    });

    test('内容起始边落页边界下方 <1px（k*pageStep-ε）→ floor 到页 k-1，不抬到页 k', () {
      const double ps = 815.28;
      // firstContentEdge 恰在第 3 页边界下方 0.4px：round 会向上取整到 3*ps（跳掉首行页），
      // floor 必须落到含该内容边的第 2 页边界 2*ps。
      const double edge = 3 * ps - 0.4;
      final r =
          bounds(first: edge, last: 10 * ps, ctxMax: 12 * ps, pageStep: ps);
      expect(r.minScroll, 2 * ps,
          reason: '内容边在页 k-1，minScroll 必须 floor 到 k-1，绝不 round-up 抬到 k 跳过首行');
      expect(r.minScroll, lessThan(edge),
          reason: 'minScroll 不得越过首行内容边（越过=首行被滚出视口）');
    });

    test('内容起始边落页边界上方 <1px（k*pageStep+ε）→ floor 仍到页 k（首行本在页 k）', () {
      const double ps = 800;
      const double edge = 4 * ps + 0.3;
      final r =
          bounds(first: edge, last: 20 * ps, ctxMax: 25 * ps, pageStep: ps);
      expect(r.minScroll, 4 * ps);
    });
  });

  group('末页 maxScroll：单一量纲 sub-pixel 下溢仍覆盖真实末行页', () {
    test('ctxMax = P*pageStep − ε（sub-pixel 下溢）→ maxScroll 仍达 P*pageStep（末行页）',
        () {
      const double ps = 815.28;
      const int p = 6;
      // 末列内容边落在第 P 页内；物理 ctxMax 因 sub-pixel 比 P*ps 少 0.4px：
      // 裸 floor 会砍成 (P-1)*ps（末行整页不可达），+1 容差必须恢复到 P*ps。
      const double ctxMax = p * ps - 0.4;
      const double last = p * ps + ps * 0.5; // 末内容边在第 P 页中段
      final r = bounds(first: 17.0, last: last, ctxMax: ctxMax, pageStep: ps);
      expect(r.maxScroll, p * ps,
          reason: 'sub-pixel 下溢不得让 maxScroll 掉一页，否则后退跳章末行被跳');
    });

    test('无 sub-pixel 下溢时 maxScroll 行为不变（floor 到 ctxMax 所在整页 == 末内容页）', () {
      const double ps = 800;
      const int p = 5;
      const double ctxMax = p * ps + 10; // 干净落在第 P 页
      const double last = p * ps + 300;
      final r = bounds(first: 16.0, last: last, ctxMax: ctxMax, pageStep: ps);
      expect(r.maxScroll, p * ps);
    });

    test('maxScroll 永不越过末内容页（容差不引入空白末页）', () {
      const double ps = 815.28;
      // 物理可滚很远（尾随空白多列），但内容只到第 2 页 → maxScroll 必须夹在第 2 页。
      const double last = 2 * ps + 200;
      final r = bounds(first: 17.0, last: last, ctxMax: 8 * ps, pageStep: ps);
      final double lastContentScroll = ((last - 1) / ps).floorToDouble() * ps;
      expect(r.maxScroll, lastContentScroll);
      expect(r.maxScroll, lessThanOrEqualTo(last),
          reason: 'maxScroll 不得越过末内容边所在页（否则末页空白）');
    });
  });

  group('退化/边界输入', () {
    test('pageStep<=0 → (0,0)', () {
      final r = bounds(first: 100, last: 200, ctxMax: 300, pageStep: 0);
      expect(r.minScroll, 0);
      expect(r.maxScroll, 0);
    });

    test('无内容（last<=0）→ maxScroll = 0', () {
      final r = bounds(first: 0, last: 0, ctxMax: 500, pageStep: 800);
      expect(r.maxScroll, 0);
    });
  });
}
