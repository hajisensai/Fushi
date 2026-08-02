import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

const Duration _kSettle = Duration(milliseconds: 450);

/// 一段惯性回放的两个计数：用户看到的翻页数，以及 `onWheelPaginate` handler 走到
/// `_focusOwnership.reclaim(FocusReclaimCause.gesture)` 的次数。
typedef _BurstCounts = ({int pageTurns, int focusReclaims});

/// 复刻 `onWheelPaginate` handler（`reader_hibiki/webview.part.dart`）的真实判定顺序：
///   ① 横向 tick 先过 [ReaderWheelGestureGate]；判「属于已认领手势」→ 早退（不 reclaim）。
///   ② 放行的 tick **先** `_focusOwnership.reclaim(FocusReclaimCause.gesture)`；
///   ③ 再进 `_paginate`；`_paginationInFlight` 为真时被入口守卫直接丢弃。
///
/// ② 与 ① 的先后由源码守卫另行钉死（见本文件下半部分）——本回放器只是**复刻**这个
/// 顺序，改不了生产代码里的真实位置，所以两条守卫缺一不可。
_BurstCounts _replayBurst({
  required ReaderWheelGestureGate gate,
  required int totalMs,
  required int tickIntervalMs,
  required bool Function(int elapsedMs) paginationInFlight,
}) {
  final DateTime start = DateTime(2026, 8, 2);
  int pageTurns = 0;
  int focusReclaims = 0;
  for (int elapsed = 0; elapsed <= totalMs; elapsed += tickIntervalMs) {
    final DateTime now = start.add(Duration(milliseconds: elapsed));
    final bool inFlight = paginationInFlight(elapsed);
    if (!gate.shouldStartNewGesture(
      now: now,
      settleInterval: _kSettle,
      canTurnPage: !inFlight,
    )) {
      continue;
    }
    focusReclaims += 1;
    if (inFlight) continue;
    pageTurns += 1;
  }
  return (pageTurns: pageTurns, focusReclaims: focusReclaims);
}

/// 一段 [totalMs] / [tickIntervalMs] 的惯性里一共有多少个 tick（含 0ms 那个）。
int _tickCount({required int totalMs, required int tickIntervalMs}) =>
    totalMs ~/ tickIntervalMs + 1;

/// TODO-2617：钉死「翻页 in-flight 期间每个横向 wheel tick 都触发一次
/// `reclaim(FocusReclaimCause.gesture)`」这个频次，并写清为什么它是**可接受**的。
///
/// 由来：BUG-1380 之前，闸门无条件消费手势 token，于是换章加载期整段惯性只有**首个**
/// tick 能穿过闸门（后续全部早退）；修复把 token 的消费挪到「这一 tick 真能翻页」之后，
/// 连带效应就是 in-flight 期间**每个** tick 都穿过闸门、都走到 reclaim。
///
/// 判定：**无需收敛**（TODO-2617 结论 B），三条依据——
///
/// 1. `reclaim` 在节点已持焦时是**幂等快返**：`PageFocusOwnership.reclaim` 的全部动作
///    是「判据谓词 + `node.requestFocus()`」（`lib/src/focus/page_focus_ownership.dart:88`）；
///    Flutter 的 `FocusNode._doRequestFocus` 在 `hasPrimaryFocus` 时直接 return
///    （`packages/flutter/lib/src/widgets/focus_manager.dart`），而即使**没有**持焦，
///    `FocusManager._markNeedsUpdate` 也用 `_haveScheduledUpdate` 把同一帧内的 N 次请求
///    合并成一次 `applyFocusChangesIfNeeded` 微任务。没有 rebuild、没有平台通道、
///    没有逐 tick 的焦点抖动。
/// 2. 它**不会**重演历史上「触屏滚动被焦点修复拉回」：那条回归的根因是
///    `HibikiFocusController.ensureFocus()` → `_scheduleReveal` →
///    `HibikiFocusScroll.ensureVisible(alignment: 0.5)` 的**滚动进视口**动作
///    （已按 `highlightMode == traditional` 门控，`test/focus/focus_repair_touch_no_scroll_test.dart`）。
///    `PageFocusOwnership.reclaim` 里没有任何 reveal/滚动，是另一套子系统；
///    不变量由 `test/focus/page_focus_ownership_test.dart` 的「高频 reclaim 不滚动视口」钉住。
/// 3. **逐 tick reclaim 不是本次新引入的量级**：handler 的闸门只判
///    `axis == 'horizontal'`，**纵向**滚轮 tick 自 TODO-737 起就一直绕过闸门、每个 tick
///    都 reclaim——而纵向滚轮正是桌面端的主路径。横向 in-flight 现在只是**对齐**了这个
///    早已在跑的基准频率，不是开了新口子。
void main() {
  group('TODO-2617 wheel-tick focus reclaim frequency', () {
    test('a clean horizontal burst reclaims focus exactly once', () {
      final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
      final _BurstCounts counts = _replayBurst(
        gate: gate,
        totalMs: 1500,
        tickIntervalMs: 60,
        paginationInFlight: (_) => false,
      );
      expect(counts.pageTurns, 1);
      expect(counts.focusReclaims, 1,
          reason: '闸门在 reclaim 之上游：一次触控板惯性只认领一次手势，'
              '所以正常路径下 26 个 tick 只回收一次焦点');
    });

    test(
        'a burst fully covered by an in-flight navigation reclaims on every '
        'tick (accepted: reclaim is idempotent when already focused)', () {
      final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
      const int totalMs = 600;
      const int tickIntervalMs = 60;
      final _BurstCounts counts = _replayBurst(
        gate: gate,
        totalMs: totalMs,
        tickIntervalMs: tickIntervalMs,
        paginationInFlight: (_) => true,
      );
      expect(counts.pageTurns, 0, reason: '整段惯性都撞在换章加载里，一页也翻不动');
      expect(
        counts.focusReclaims,
        _tickCount(totalMs: totalMs, tickIntervalMs: tickIntervalMs),
        reason: 'BUG-1380 之后 in-flight 期间闸门只查询不认领 ⇒ 每个 tick 都穿过闸门、'
            '都调一次 reclaim。这是**有意接受**的频次：节点此时已持焦，'
            'requestFocus 在 hasPrimaryFocus 上快返，且 FocusManager 合并同帧请求。'
            '若这里退回 1，说明 token 又被翻不动页的 tick 提前吃掉了（BUG-1380 回归）',
      );
    });

    test(
        'a burst that opens during chapter loading reclaims once per swallowed '
        'tick plus once for the landed turn', () {
      final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
      // 前 300ms 换章加载在飞（elapsed 0/60/…/300 共 6 个 tick 被丢弃），之后落定。
      final _BurstCounts counts = _replayBurst(
        gate: gate,
        totalMs: 1500,
        tickIntervalMs: 60,
        paginationInFlight: (int elapsedMs) => elapsedMs <= 300,
      );
      expect(counts.pageTurns, 1, reason: '加载落定后恰好补翻一页（BUG-1380）');
      expect(counts.focusReclaims, 7,
          reason: '6 个被 _paginate 丢弃的 in-flight tick 各 reclaim 一次，'
              '外加真正落地那一次；上界是 tick 数，不随时间无限增长');
    });

    test('reclaim count never exceeds the tick count of the burst', () {
      for (final int inFlightUntilMs in <int>[0, 120, 300, 600, 1500]) {
        final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
        const int totalMs = 1500;
        const int tickIntervalMs = 60;
        final _BurstCounts counts = _replayBurst(
          gate: gate,
          totalMs: totalMs,
          tickIntervalMs: tickIntervalMs,
          paginationInFlight: (int elapsedMs) => elapsedMs <= inFlightUntilMs,
        );
        expect(
          counts.focusReclaims,
          lessThanOrEqualTo(
              _tickCount(totalMs: totalMs, tickIntervalMs: tickIntervalMs)),
          reason: 'reclaim 频次的上界是输入事件数本身（O(tick)），'
              '不存在「一个 tick 放大成多次回收」的路径',
        );
      }
    });
  });

  // ── 源码守卫：回放器复刻的那个顺序，必须真的是生产代码里的顺序 ──────────
  //
  // 上面的回放器把「闸门 → reclaim → _paginate」写死在 fixture 里，所以它抓不到
  // 「有人把 reclaim 挪到闸门之前」这种改法（那会让**每一个** tick 都 reclaim，
  // 包括已认领手势内的 25 个，频次从 O(手势) 掉到 O(事件)）。这一条由下面的结构
  // 守卫兜住：窗口由 addJavaScriptHandler 的圆括号配对给出，语料先做词法掩码，
  // 注释里出现同名符号一律不算数。
  group('TODO-2617 reclaim stays downstream of the wheel gesture gate', () {
    late String handlerBody;

    setUpAll(() {
      final String source = maskCommentsAndScriptLines(readReaderPageSource());
      final EnclosingCall handler =
          enclosingCallOf(source, "handlerName: 'onWheelPaginate'");
      expect(handler.name, endsWith('addJavaScriptHandler'),
          reason: 'onWheelPaginate 必须仍以 addJavaScriptHandler 的具名实参注册');
      handlerBody = handler.text;
    });

    test('the handler reclaims focus exactly once, after the gate early-return',
        () {
      expect(
        containsCodeLine(
            handlerBody, '_focusOwnership.reclaim(FocusReclaimCause.gesture)'),
        isTrue,
        reason: 'BUG-136：滚轮翻页同样把 OS 焦点交给了 WebView，必须夺回来',
      );
      expect(
        '_focusOwnership.reclaim('.allMatches(handlerBody).length,
        1,
        reason: '只允许一处回收点。多写一处（例如闸门之前补一个）就把频次从「一次手势一次」'
            '抬成「一个 tick 一次」，且两处的门控必然漂移——正是 PageFocusOwnership 要消灭的老路',
      );

      final int gate =
          handlerBody.indexOf('_pagedWheelGestureGate.shouldStartNewGesture');
      final int reclaim =
          handlerBody.indexOf('_focusOwnership.reclaim(FocusReclaimCause');
      expect(gate, isNonNegative);
      expect(reclaim, isNonNegative);
      expect(reclaim, greaterThan(gate),
          reason: 'reclaim 必须排在手势闸门之后：闸门早退的 tick（已认领手势内的惯性余波）'
              '不该再回收焦点，否则一次 1.5s 惯性会从 1 次回收变成 26 次');
    });

    test('the gate branch really early-returns before reaching the reclaim',
        () {
      final int gate =
          handlerBody.indexOf('_pagedWheelGestureGate.shouldStartNewGesture');
      expect(gate, isNonNegative);
      // 闸门所在 `if (...)` 的块本体：从条件表达式之后的第一个 `{` 起做花括号配对。
      final String branch = balancedBlockFrom(
        handlerBody,
        gate,
        what: 'onWheelPaginate 手势闸门分支',
      );
      expect(containsCodeLine(branch, 'return;'), isTrue,
          reason: '闸门判「属于已认领手势」必须直接 return；'
              '改成继续往下走就等于闸门对 reclaim 频次完全失效');
      expect(
        containsCodeLine(branch, '_focusOwnership.reclaim('),
        isFalse,
        reason: '回收点不得落进闸门的早退分支里（那是「这一 tick 不处理」的分支）',
      );
    });
  });
}
