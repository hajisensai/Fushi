import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_hibiki_page.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// TODO-1229 第三次复诉（滚轮仍双跳）守卫。
///
/// v2 冷却窗只靠「换章加载期不断到达的惯性 tick」把 [chapterTurnCoolingDown] 的时间戳
/// 滑到当下来维持。但鼠标滚轮是**离散**事件流——用户拨两三格越过章末后 burst 就结束，
/// 换章加载(整章解析+渲染+restore，常 >450ms)期间没有后续 tick 续窗；等新章(短插图/
/// 单页章)在边界上出现时冷却窗早已过期，紧随其后的残余滚动在新章边界二次跨章 →
/// 「第一次正常然后很快又跳一次」。
///
/// 根因=冷却窗锚在「输入」，长加载把「输入停止」与「新章刚出现」拉开出一个洞。修法：
/// 惯性跨章落地的新章 content-ready 那一刻把冷却窗重新 stamp 到当下，无论加载多久、
/// 期间有没有续窗 tick，新章一出现就有一个完整冷却窗挡住残余惯性。
void main() {
  const Duration cooldown = Duration(milliseconds: 450);
  final DateTime t0 = DateTime(2026, 7, 7, 12, 0, 0);

  group('content-ready 重新 stamp 冷却窗（离散滚轮真因）', () {
    test('长加载后残余滚轮：无 ready-restamp 会漏拦（复现 bug）', () {
      // 第一次跨章 stamp 在 t0。鼠标滚轮 burst 结束，加载期间无续窗 tick。
      // 换章加载 600ms 后新章就绪，残余滚轮在 ready+40ms 到达边界二次跨章。
      final DateTime residualTick = t0.add(const Duration(milliseconds: 640));
      // 旧行为：lastInputAt 停在 t0（无续窗、无 ready-restamp）。
      expect(
        chapterTurnCoolingDown(
          lastInputAt: t0,
          now: residualTick,
          cooldown: cooldown,
        ),
        isFalse,
        reason: '640-0=640ms > 450ms → 冷却窗已过期 → 漏拦 → 二次跨章（正是复诉现象）',
      );
    });

    test('长加载后残余滚轮：ready-restamp 后被拦（本次修复）', () {
      // 修复：新章 content-ready(t0+600) 那一刻把冷却窗 stamp 到当下。
      final DateTime chapterReadyAt = t0.add(const Duration(milliseconds: 600));
      final DateTime residualTick = t0.add(const Duration(milliseconds: 640));
      expect(
        chapterTurnCoolingDown(
          lastInputAt: chapterReadyAt, // ready 时重新 stamp
          now: residualTick,
          cooldown: cooldown,
        ),
        isTrue,
        reason: '640-600=40ms < 450ms → 新章刚出现的残余滚轮被拦，一次手势=一次跨章',
      );
    });

    test('刻意的第二次跨章（静默满冷却窗后再滚）仍放行', () {
      // 新章 ready 于 t0+600 重新 stamp；用户停手、超过冷却窗后刻意再滚。
      final DateTime chapterReadyAt = t0.add(const Duration(milliseconds: 600));
      final DateTime deliberate = chapterReadyAt.add(
        const Duration(milliseconds: 500),
      );
      expect(
        chapterTurnCoolingDown(
          lastInputAt: chapterReadyAt,
          now: deliberate,
          cooldown: cooldown,
        ),
        isFalse,
        reason: '距新章就绪静默 500ms > 450ms → 视为新手势 → 刻意跨章放行（不误伤连续阅读）',
      );
    });
  });

  group('源码守卫：content-ready 重新 stamp 冷却窗接线到位', () {
    late String source;
    setUpAll(() {
      source = readReaderPageSource();
    });

    test('存在 pending 旗与消费 helper', () {
      expect(source, contains('bool _inertiaChapterTurnPending = false;'));
      expect(source, contains('void _markInertiaChapterTurnPending()'));
      expect(source, contains('void _noteChapterTurnSettledIfPending()'));
      // 消费 helper 必须复位旗子并重新 stamp 冷却窗。
      final String helper = _slice(
        source,
        'void _noteChapterTurnSettledIfPending()',
        'Future<void> _paginate(',
      );
      expect(helper, contains('_inertiaChapterTurnPending = false;'));
      expect(helper, contains('_noteChapterTurnInput();'));
    });

    test('_handlePageTurnLimit 带 inertia 参数，且惯性跨章导航前置 pending 旗', () {
      final String limit = _slice(
        source,
        'void _handlePageTurnLimit(String direction',
        'Future<void> _refreshProgress()',
      );
      expect(limit, contains('{bool inertia = false}'));
      // 每处真正导航前都以 inertia 门控置旗（spread 前进/后退 + 兜底裸翻章）。
      expect(
        'if (inertia) _markInertiaChapterTurnPending();'
            .allMatches(limit)
            .length,
        greaterThanOrEqualTo(3),
        reason: 'spread 前进/后退 + 兜底裸翻章三处导航前都要按 inertia 置旗',
      );
    });

    test('三条惯性跨章入口都传 inertia:true / inertia:throttleMs>0', () {
      // onBoundarySwipe（连续滚轮/触摸跨章）。
      expect(
          source, contains("_handlePageTurnLimit('forward', inertia: true)"));
      expect(
          source, contains("_handlePageTurnLimit('backward', inertia: true)"));
      // _paginate 两分支（滚轮 throttleMs>0=惯性，键盘/手柄 throttleMs==0 不置旗）。
      expect(
        'inertia: throttleMs > 0'.allMatches(source).length,
        greaterThanOrEqualTo(2),
        reason: '_paginate 连续 + 分页两分支跨章都按 throttleMs>0 门控 inertia',
      );
    });

    test('content-ready 完成点消费 pending：_onRestoreComplete', () {
      final String restore = _slice(
        source,
        'void _onRestoreComplete()',
        'void _handlePageTurnLimit(String direction',
      );
      expect(restore, contains('_noteChapterTurnSettledIfPending();'),
          reason: '正文章 content-ready（最常见路径）必须重新 stamp 冷却窗');
    });

    test('content-ready 完成点消费 pending：spreadReady + 兜底超时', () {
      // spreadReady handler。
      final String spread = _slice(
        source,
        "handlerName: 'spreadReady'",
        "handlerName: 'onCueTap'",
      );
      expect(spread, contains('_noteChapterTurnSettledIfPending();'),
          reason: 'spread(漫画双页) content-ready 也要重新 stamp 冷却窗');
      // 兜底超时（content ready timeout）。
      final String timeout = _slice(
        source,
        'void _startContentReadyTimeout()',
        'void _clearContentReadyTimeout()',
      );
      expect(timeout, contains('_noteChapterTurnSettledIfPending();'),
          reason: '兜底超时也算就绪，必须消费 pending 避免旗子悬空');
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
