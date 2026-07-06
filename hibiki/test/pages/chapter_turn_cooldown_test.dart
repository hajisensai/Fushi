import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// BUG-568 (TODO-1229) v2：竖排跳章「跳两次」复诉的根因守卫。
///
/// 案A 的 `_paginationInFlight` 守卫只覆盖「换章加载+restore」瞬态窗口；滚轮/触控板一次
/// 连续惯性手势产生的 tick 流常长于该窗口 + 章内节流窗（两者都锚定手势起点第一 tick）。
/// 两窗口在手势中途失效后，残余惯性会在刚落地的短章(章首插图页/单页章)边界再次触发跨章
/// → 跳两章。修法：`chapterTurnCoolingDown` 纯判据把「下一次跨章」冷却锚定到输入真正停止
/// 那一刻，调用方在丢弃惯性 / 被拒跨章时滑动时间戳，冷却窗随惯性前推。
void main() {
  const Duration cooldown = Duration(milliseconds: 450);
  final DateTime t0 = DateTime(2026, 7, 7, 12, 0, 0);

  group('chapterTurnCoolingDown 纯判据', () {
    test('从未跨章（lastInputAt=null）恒放行', () {
      expect(
        chapterTurnCoolingDown(
          lastInputAt: null,
          now: t0,
          cooldown: cooldown,
        ),
        isFalse,
      );
    });

    test('距上次跨章输入不足冷却窗 → 拦截（同一手势残余惯性）', () {
      // 第一次跨章 stamp 在 t0；restore 约 400ms 落地后，残余惯性 tick 在 t0+470ms 到达。
      // 旧实现里节流窗(450ms 锚 t0)与在飞守卫都已失效 → 会二次跨章。新判据仍在冷却窗内。
      final DateTime tick = t0.add(const Duration(milliseconds: 470));
      // 关键：冷却窗随每个被丢弃的惯性 tick 滑动 → last 不是 t0 而是最后一次丢弃(约 t0+400)。
      final DateTime lastSlid = t0.add(const Duration(milliseconds: 400));
      expect(
        chapterTurnCoolingDown(
          lastInputAt: lastSlid,
          now: tick,
          cooldown: cooldown,
        ),
        isTrue,
        reason: '470-400=70ms < 450ms，属同一手势残余惯性，必须拦截二次跨章',
      );
    });

    test('边界：恰好等于冷却窗 → 放行（>= 语义）', () {
      final DateTime tick = t0.add(cooldown);
      expect(
        chapterTurnCoolingDown(
          lastInputAt: t0,
          now: tick,
          cooldown: cooldown,
        ),
        isFalse,
        reason: '静默满冷却窗即视为新手势，放行',
      );
    });

    test('输入静默超过冷却窗（新手势）→ 放行', () {
      final DateTime tick = t0.add(const Duration(milliseconds: 900));
      expect(
        chapterTurnCoolingDown(
          lastInputAt: t0,
          now: tick,
          cooldown: cooldown,
        ),
        isFalse,
      );
    });

    test('滑动语义：连续惯性把窗口不断前推 → 全程拦截', () {
      // 模拟一串每 60ms 一个的惯性 tick：每个被拦截时都把 last 滑到当下，
      // 下一个 tick 相对滑动后的 last 仍在冷却窗内 → 全部拦截，直到间隔 > 冷却窗。
      DateTime last = t0;
      for (int i = 1; i <= 12; i++) {
        final DateTime tick = t0.add(Duration(milliseconds: 60 * i));
        final bool cooling = chapterTurnCoolingDown(
          lastInputAt: last,
          now: tick,
          cooldown: cooldown,
        );
        expect(cooling, isTrue, reason: '第 $i 个惯性 tick（间隔 60ms < 450ms）必须持续拦截');
        // 调用方在拦截时滑动时间戳（镜像 _chapterTurnCoolingDown / _noteChapterTurnInput）。
        last = tick;
      }
      // 手势结束：静默 500ms 后的新 tick 放行。
      final DateTime resume = last.add(const Duration(milliseconds: 500));
      expect(
        chapterTurnCoolingDown(
          lastInputAt: last,
          now: resume,
          cooldown: cooldown,
        ),
        isFalse,
        reason: '输入静默超过冷却窗后，新手势的跨章放行',
      );
    });
  });

  group('源码守卫：跨章冷却接线到位', () {
    late String source;
    setUpAll(() {
      source = readReaderPageSource();
    });

    test('_paginate 分页/连续两分支跨章前都过 _chapterTurnCoolingDown 闸门', () {
      final String paginate = _slice(
        source,
        '  Future<void> _paginate(',
        '  // ── Image Viewer',
      );
      // 两处 _handlePageTurnLimit(direction.jsValue) 调用前都必须有冷却闸门。
      expect(
        'if (throttleMs > 0 && _chapterTurnCoolingDown()) return;'
            .allMatches(paginate)
            .length,
        greaterThanOrEqualTo(2),
        reason: '连续 + 分页两分支跨章前都要过惯性冷却闸门',
      );
      // 冷却闸门只对惯性输入(throttleMs>0)，键盘/手柄(throttleMs==0)不受限。
      expect(paginate, contains('throttleMs > 0 && _chapterTurnCoolingDown()'));
    });

    test('_paginate 的在飞丢弃路径滑动跨章冷却窗', () {
      final String paginate = _slice(
        source,
        '  Future<void> _paginate(',
        '  // ── Image Viewer',
      );
      final int guardIdx = paginate.indexOf('if (_paginationInFlight)');
      final int noteIdx = paginate.indexOf('_noteChapterTurnInput()');
      expect(guardIdx, isNonNegative);
      expect(noteIdx, isNonNegative,
          reason: '在飞丢弃惯性输入时必须滑动冷却窗，避免 restore 后残余惯性二次跨章');
    });

    test('onBoundarySwipe 跨章前过冷却闸门且在飞丢弃时滑动窗口', () {
      final String handler = _slice(
        source,
        "handlerName: 'onBoundarySwipe'",
        "handlerName: 'onImageDetected'",
      );
      final int coolIdx =
          handler.indexOf('if (_chapterTurnCoolingDown()) return;');
      final int limitIdx = handler.indexOf("_handlePageTurnLimit('");
      expect(coolIdx, isNonNegative, reason: 'onBoundarySwipe 跨章前必须过冷却闸门');
      expect(limitIdx, isNonNegative);
      expect(coolIdx, lessThan(limitIdx),
          reason: '冷却闸门必须先于 _handlePageTurnLimit 跨章');
      expect(handler, contains('_noteChapterTurnInput()'),
          reason: '在飞丢弃 / 跨章落地都要滑动/播种冷却窗');
    });
  });
}

String _slice(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
