import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';

import 'reader_fushi_page_source_corpus.dart';

/// BUG-568 (TODO-1229) + BUG-1829：跨章去抖判据的守卫。
///
/// 要挡的危险窗是「**刚跨完一章**」那一段：残余惯性会在刚落地的短章(章首插图页/单页章)
/// 边界上再次触发跨章 → 跳两章。所以冷却锚定的是**跨章事件本身**，窗口只由两种真实事件
/// 推进：① 真正发起一次跨章；② 该次跨章落地的新章 content-ready 重锚（见
/// `chapter_turn_cooldown_ready_restamp_test.dart`）。
///
/// **BUG-1829**：v2 曾让调用方在「冷却期内被拒的跨章」和「在飞时被丢弃的输入」上也把时间
/// 戳滑到当下，想用「输入静默」当手势结束判据。v3 换成 content-ready 重锚后那条滑窗已经
/// 多余，却留了下来 —— 于是真实滚轮（每 30~100ms 一个事件）只要用户还在拨，窗口就被自己
/// 的输入无限续期、**永远等不到过期**：拨得越快越不动，单页章（封面/插图/目录/版权页，
/// 页内没有可滚的量，每一次滚轮都必须走跨章判定）直接成为滚轮死区。
/// 判据维度必须是「距上次**跨章**」，不是「距上次**输入**」——后者由被闸门拦住的那一方
/// 自己控制，等于把闸门的钥匙交给它。
void main() {
  const Duration cooldown = Duration(milliseconds: 450);
  final DateTime t0 = DateTime(2026, 7, 7, 12, 0, 0);

  group('chapterTurnCoolingDown 纯判据', () {
    test('从未跨章（lastTurnAt=null）恒放行', () {
      expect(
        chapterTurnCoolingDown(
          lastTurnAt: null,
          now: t0,
          cooldown: cooldown,
        ),
        isFalse,
      );
    });

    test('距上次跨章不足冷却窗 → 拦截（同一手势残余惯性）', () {
      // 第一次跨章 stamp 在 t0；restore 约 400ms 落地，残余惯性 tick 在 t0+300ms 到达。
      final DateTime tick = t0.add(const Duration(milliseconds: 300));
      expect(
        chapterTurnCoolingDown(
          lastTurnAt: t0,
          now: tick,
          cooldown: cooldown,
        ),
        isTrue,
        reason: '300ms < 450ms，属同一手势残余惯性，必须拦截二次跨章',
      );
    });

    test('边界：恰好等于冷却窗 → 放行（>= 语义）', () {
      final DateTime tick = t0.add(cooldown);
      expect(
        chapterTurnCoolingDown(
          lastTurnAt: t0,
          now: tick,
          cooldown: cooldown,
        ),
        isFalse,
        reason: '距上次跨章满冷却窗即放行',
      );
    });

    test('距上次跨章超过冷却窗 → 放行', () {
      final DateTime tick = t0.add(const Duration(milliseconds: 900));
      expect(
        chapterTurnCoolingDown(
          lastTurnAt: t0,
          now: tick,
          cooldown: cooldown,
        ),
        isFalse,
      );
    });
  });

  group('BUG-1829：持续输入不得让冷却窗自我续期', () {
    /// 把「一串以 [gapMs] 为间隔的惯性输入」喂给闸门，返回实际放行的跨章次数。
    /// [stampOnBlocked] = true 复刻**旧实现**（拦截时也把窗口滑到当下）。
    int turnsIn(
      int gapMs,
      int ticks, {
      required bool stampOnBlocked,
    }) {
      DateTime? lastTurnAt;
      int turns = 0;
      for (int i = 1; i <= ticks; i++) {
        final DateTime tick = t0.add(Duration(milliseconds: gapMs * i));
        final bool cooling = chapterTurnCoolingDown(
          lastTurnAt: lastTurnAt,
          now: tick,
          cooldown: cooldown,
        );
        if (cooling) {
          if (stampOnBlocked) lastTurnAt = tick;
          continue;
        }
        lastTurnAt = tick;
        turns++;
      }
      return turns;
    }

    test('复现旧实现的饥饿：拦截时滑窗 → 100ms 连续拨轮 3 秒只跨 1 章', () {
      expect(
        turnsIn(100, 30, stampOnBlocked: true),
        1,
        reason: '旧实现里第一次跨章之后，每个被拦的 tick 都把窗口推到当下，'
            '间隔 100ms < 450ms ⇒ 窗口永远不过期 ⇒ 用户拨到手酸也只跨了一章',
      );
    });

    test('修复后：同一串输入每满一个冷却窗就放行一次，不饥饿', () {
      // 3 秒 / 450ms ≈ 6 次；100ms 网格上落到 500ms 一次 ⇒ 6 次。
      expect(
        turnsIn(100, 30, stampOnBlocked: false),
        greaterThanOrEqualTo(5),
        reason: '窗口只由真跨章推进 ⇒ 持续拨轮稳定推进，不再被自己的输入锁死',
      );
    });

    test('旧实现的特征：只要输入间隔小于冷却窗，恒定只跨 1 章（与密度无关）', () {
      // 这才是滑窗的真实特征——不是「越快越少」，而是**任何**快于冷却窗的持续输入
      // 都被锁死在第一次跨章上。用户主观感受就是「拨不动」。
      for (final int gapMs in <int>[50, 100, 200, 400]) {
        expect(
          turnsIn(gapMs, 3000 ~/ gapMs, stampOnBlocked: true),
          1,
          reason: '间隔 ${gapMs}ms < 450ms：旧实现下 3 秒持续输入仍只跨 1 章',
        );
      }
      // 间隔满冷却窗后旧实现才恢复正常——这正是「拨慢一点反而能动」的来源。
      expect(
        turnsIn(500, 6, stampOnBlocked: true),
        greaterThan(1),
        reason: '间隔 500ms > 450ms 时旧实现也能连续跨章，佐证症状与密度直接相关',
      );
    });

    test('修复后：同样 3 秒，输入更密不该跨得更少', () {
      final int fast = turnsIn(50, 60, stampOnBlocked: false); // 3 秒，50ms 一个
      final int slow = turnsIn(200, 15, stampOnBlocked: false); // 3 秒，200ms 一个
      expect(
        fast,
        greaterThanOrEqualTo(slow),
        reason: '窗口只由跨章推进后，放行次数由冷却窗决定，与输入密度单调不冲突',
      );
      expect(fast, greaterThan(1), reason: '密集输入必须能连续跨章，不得退回饥饿');
    });

    test('单页章场景：每次输入都走跨章判定时仍能连续前进', () {
      // 单页章里 paginate() 恒返回 "limit"，所以每一个通过节流的滚轮事件都到闸门。
      // 滚轮节流 450ms 与冷却窗同长，落在网格上必须仍能推进。
      expect(
        turnsIn(450, 10, stampOnBlocked: false),
        greaterThanOrEqualTo(9),
        reason: '节流与冷却窗同长时，修复后每个节流放行的 tick 都能跨章；'
            '旧实现在这里恰好卡在边界上反复续期',
      );
    });
  });

  group('源码守卫：跨章冷却接线到位', () {
    late String source;
    setUpAll(() {
      source = readReaderPageSource();
    });

    String coolingGate() => _slice(
          source,
          'bool _chapterTurnCoolingDown()',
          'Future<void> _paginate(',
        );

    String paginateBody() => _slice(
          source,
          '  Future<void> _paginate(',
          '  // ── Image Viewer',
        );

    String boundarySwipeHandler() => _slice(
          source,
          "handlerName: 'onBoundarySwipe'",
          "handlerName: 'onImageDetected'",
        );

    test('_paginate 分页/连续两分支跨章前都过 _chapterTurnCoolingDown 闸门', () {
      final String paginate = paginateBody();
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

    test('BUG-1829：_chapterTurnCoolingDown 必须是纯读，不得写时间戳', () {
      expect(
        coolingGate(),
        isNot(contains('_lastChapterTurnAt =')),
        reason: '闸门在拦截时写时间戳＝被拦的输入自己续期，'
            '持续拨轮永远等不到窗口过期（BUG-1829 饥饿）',
      );
      expect(
        coolingGate(),
        isNot(contains('_noteChapterTurn()')),
        reason: '同上：闸门不得以任何形式推进冷却窗',
      );
    });

    test('BUG-1829：_paginate 的在飞丢弃路径不得滑动跨章冷却窗', () {
      final String paginate = paginateBody();
      final String inFlightBranch = _slice(
        paginate,
        'if (_paginationInFlight) {',
        '}',
      );
      expect(
        inFlightBranch,
        isNot(contains('_noteChapterTurn()')),
        reason: '被丢弃的输入不是跨章事件；这段窗口由新章 content-ready 重锚覆盖',
      );
    });

    test('BUG-1829：onBoundarySwipe 的在飞丢弃路径不得滑动跨章冷却窗', () {
      final String handler = boundarySwipeHandler();
      final String inFlightBranch = _slice(
        handler,
        'if (_paginationInFlight) {',
        '}',
      );
      expect(
        inFlightBranch,
        isNot(contains('_noteChapterTurn()')),
        reason: '与 _paginate 入口同一处理，两条路径不得分叉',
      );
    });

    test('onBoundarySwipe 跨章前过冷却闸门，且真跨章时 stamp', () {
      final String handler = boundarySwipeHandler();
      final int coolIdx =
          handler.indexOf('if (_chapterTurnCoolingDown()) return;');
      final int noteIdx = handler.indexOf('_noteChapterTurn();');
      final int limitIdx = handler.indexOf("_handlePageTurnLimit('");
      expect(coolIdx, isNonNegative, reason: 'onBoundarySwipe 跨章前必须过冷却闸门');
      expect(limitIdx, isNonNegative);
      expect(coolIdx, lessThan(limitIdx),
          reason: '冷却闸门必须先于 _handlePageTurnLimit 跨章');
      expect(noteIdx, isNonNegative,
          reason: '真正跨章时必须 stamp，否则冷却窗永不开启、跳两章回归');
      expect(noteIdx, lessThan(limitIdx), reason: 'stamp 必须先于跨章');
    });

    test('冷却窗只由 _noteChapterTurn 推进，且只在真跨章 / content-ready 上调用', () {
      // 全语料里写 _lastChapterTurnAt 的地方只能是 _noteChapterTurn 本体。
      expect(
        '_lastChapterTurnAt = '.allMatches(source).length,
        1,
        reason: '时间戳的唯一写入点必须是 _noteChapterTurn，'
            '多一个写入点就是多一条能让窗口被非跨章事件推进的路径',
      );
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
