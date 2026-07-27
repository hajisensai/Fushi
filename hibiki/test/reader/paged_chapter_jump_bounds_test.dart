// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
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
    double? physicalMax,
  }) =>
      ReaderPaginationScripts.resolveContentBoundsForTesting(
        firstContentEdge: first,
        lastContentEdge: last,
        contextMaxScroll: ctxMax,
        physicalMaxScroll: physicalMax ?? ctxMax,
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

    test('chrome inset 后末内容落下一网格页时，以浏览器物理终点补一张非网格尾页', () {
      // 2026-07-13 macOS 真机 RED：底栏把 pageStep 从 635 改成 582.490967。
      // 末内容属于 62*P，但浏览器最多只能滚到 36041；若仍把 maxScroll 截在
      // 61*P=35531.949，m420 只露一小截，随后 paginate 直接报 limit。
      const double ps = 582.490967;
      const double logicalMax = 36093.509033;
      const double physicalMax = 36041;
      const double last = 36664.5;

      final r = bounds(
        first: 17,
        last: last,
        ctxMax: logicalMax,
        physicalMax: physicalMax,
        pageStep: ps,
      );

      expect(r.maxScroll, physicalMax, reason: '最后一个整页网格不可达时，必须保留浏览器可达的非网格章尾页');
      expect(r.maxScroll, greaterThan(61 * ps),
          reason: '章尾页必须越过最后一个整页网格，才能露出剩余正文');
      expect(r.maxScroll, lessThan(62 * ps), reason: '不得请求超过浏览器物理上限的下一整页网格');
    });

    test('物理终点远于末内容页时仍停在末内容整页，不制造空白尾页', () {
      const double ps = 800;
      const double last = 2 * ps + 200;
      final r = bounds(
        first: 17,
        last: last,
        ctxMax: 8 * ps,
        physicalMax: 8.75 * ps,
        pageStep: ps,
      );

      expect(r.maxScroll, 2 * ps);
    });
  });

  group('退化/边界输入', () {
    test('pageStep<=0 → (0,0)', () {
      final r = bounds(first: 100, last: 200, ctxMax: 300, pageStep: 0);
      expect(r.minScroll, 0);
      expect(r.maxScroll, 0);
    });

    test('pageStep<0 → (0,0)', () {
      final r = bounds(first: 100, last: 200, ctxMax: 300, pageStep: -1);
      expect(r.minScroll, 0);
      expect(r.maxScroll, 0);
    });

    test('无内容（last<=0）→ maxScroll = 0', () {
      final r = bounds(first: 0, last: 0, ctxMax: 500, pageStep: 800);
      expect(r.maxScroll, 0);
    });
  });

  group('非网格 terminal pageInfo', () {
    test('本机 61 条整页网格后追加物理终点，页数与当前位置均为 63', () {
      final info = ReaderPaginationScripts.resolvePageInfoForTesting(
        minScroll: 0,
        maxScroll: 36041,
        currentScroll: 36041,
        pageStep: 582.490967,
      );

      expect(info.totalPages, 63);
      expect(info.currentPage, 63);
    });

    test('整页终点不额外增加 terminal 页', () {
      const double ps = 582.490967;
      final info = ReaderPaginationScripts.resolvePageInfoForTesting(
        minScroll: 0,
        maxScroll: 61 * ps,
        currentScroll: 61 * ps,
        pageStep: ps,
      );

      expect(info.totalPages, 62);
      expect(info.currentPage, 62);
    });

    test('不足半页的非网格终点仍必须计作独立末页', () {
      const double ps = 800;
      final info = ReaderPaginationScripts.resolvePageInfoForTesting(
        minScroll: 0,
        maxScroll: 2 * ps + 20,
        currentScroll: 2 * ps + 20,
        pageStep: ps,
      );

      expect(info.totalPages, 4,
          reason: 'round(span/pageStep) 会漏掉不足半页但真实可读的 terminal 页');
      expect(info.currentPage, 4);
    });
  });
}
