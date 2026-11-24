import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/anki/mine_failure_notice.dart';

/// 给「后台写卡」一个可以被查词卡等到的结局（反馈 Va3bdT-X0r，BUG-5386 遗留）。
///
/// gal 查词卡制卡只陪到采样结束就回 `queued`（反馈 y90oiVojic），编码与写卡在宿主后台
/// 落地。以前落地结局只走主窗 FushiToast——游戏全屏时主窗在游戏后面，写卡阶段的失败
/// （Anki 没开、字段映射不对……）用户一个也看不见；查词卡上那颗「已加入」✓ 还一直
/// 挂着，像是成功了。
///
/// app 外覆盖窗（裸 WebView2）宿主只能**回答** popup.js 发起的桥调用，不能主动往页面里
/// 推东西。所以「推送」做成一根长挂的 deferred 桥：
///
/// 1. 宿主开一张单（[open]），令牌随 `queued` 回包交给 popup.js（[tokenKey]）；
/// 2. 转交回包的桥处理器顺手登记发起这张卡的「还在不在屏上」探针（[bindOrigin]）；
/// 3. popup.js 拿到 `queued` 立刻调 `awaitMineSettled`（[wait]），这颗 promise 一直挂到
///    写卡有结局；
/// 4. 宿主落地时 [land] / [fail]，挂着的 promise 被兑现，查词卡就地翻 ✓ 或说失败原因，
///    失败且可重写时按钮进入「重试」态，点它走 `retryQueuedMine`（[retry]）用原画面与
///    原句音重写，不重抓窗口。
///
/// 失败原因**恰好说一次**（与 [MineFailureNotice] 同一纪律）：发起的那张卡还在屏上 →
/// 交给它就地说；已经关了 / 换了词 → 由调用方给的 `onUnseen` 在主窗 toast（带重试）。
/// 「卡在不在」只问宿主自己的 route 真值，不靠任何延时。
class QueuedMineSettlements {
  /// 生产用单例；测试各自 new 一个。
  @visibleForTesting
  QueuedMineSettlements({this.capacity = 64});

  static final QueuedMineSettlements instance = QueuedMineSettlements();

  /// `queued` 回包里携带令牌的键（popup.js `parseMineResult` 读同名字段）。
  static const String tokenKey = 'settleToken';

  /// 同时记住的单数上限。超出时最老的一张被逐出：还挂着的等待者拿到 `unknown`，
  /// 结局还没说出口的失败改由 `onUnseen` 说。
  final int capacity;

  int _nextToken = 0;
  final LinkedHashMap<int, _Ticket> _tickets = LinkedHashMap<int, _Ticket>();

  @visibleForTesting
  int get debugTicketCount => _tickets.length;

  /// 开一张后台写卡单，返回交给 popup.js 的令牌。
  int open() {
    final int token = ++_nextToken;
    _tickets[token] = _Ticket();
    while (_tickets.length > capacity) {
      final int oldest = _tickets.keys.first;
      _evict(_tickets.remove(oldest)!);
    }
    return token;
  }

  /// 登记发起 [token] 那张查词卡「此刻还在不在屏上」的探针。由转交 `queued` 回包的
  /// 桥处理器调（它握着发起这次查词的 route）。
  void bindOrigin(int token, MineOriginOnScreen origin) {
    final _Ticket? ticket = _tickets[token];
    if (ticket == null) return;
    ticket.origin = origin;
    // 结局抢在回包之前就出来了（极快的失败）：现在才知道卡在不在。
    _settleHeldIfOriginGone(ticket);
  }

  /// popup.js `awaitMineSettled` 桥：等 [token] 的结局。[origin] 是这次桥调用所在查词
  /// 卡的探针。回包形状：
  /// * `{settled: 'landed', noteId}`；
  /// * `{settled: 'failed', message?, duplicate?, retryable, hostReported?}`；
  /// * `{settled: 'unknown'}`：没有这张单（被逐出 / 不是本宿主开的）。
  Future<Map<String, Object?>> wait(
    int token, {
    required MineOriginOnScreen origin,
  }) {
    final _Ticket? ticket = _tickets[token];
    if (ticket == null) {
      return Future<Map<String, Object?>>.value(_unknown);
    }
    switch (ticket.state) {
      case _TicketState.pending:
        // 同一张单只认最后一个等待者（同一颗按钮重试后会重新等）。
        ticket.waiter?.complete(_unknown);
        final Completer<Map<String, Object?>> waiter =
            Completer<Map<String, Object?>>();
        ticket
          ..waiter = waiter
          ..waiterOrigin = origin;
        return waiter.future;
      case _TicketState.landed:
        return Future<Map<String, Object?>>.value(ticket.outcome!);
      case _TicketState.failed:
        final VoidCallback? held = ticket.onUnseen;
        if (held != null) {
          ticket.onUnseen = null;
          if (!origin()) {
            ticket.outcome = _hostReported(ticket.outcome!);
            held();
          }
        }
        return Future<Map<String, Object?>>.value(ticket.outcome!);
    }
  }

  /// 卡落地了。
  void land(int token, {int? noteId}) {
    final _Ticket? ticket = _tickets[token];
    if (ticket == null) return;
    final Map<String, Object?> outcome = <String, Object?>{
      'settled': 'landed',
      'noteId': noteId,
    };
    ticket
      ..state = _TicketState.landed
      ..outcome = outcome
      ..retry = null
      ..onUnseen = null;
    final Completer<Map<String, Object?>>? waiter = ticket.waiter;
    ticket.waiter = null;
    waiter?.complete(outcome);
  }

  /// 写卡失败。[failure] 是这次结果交给弹窗的回包（`toPopupReply`：`message` /
  /// `duplicate`）；[retry] 非 null = 可以用已做好的画面与句音重写。
  ///
  /// [onUnseen] 恰好在「没有一张仍在屏上的查词卡能说这句话」时被调一次（可能就在本调用
  /// 里，也可能在等待者到来 / 卡被关时），调用方在那里改走主窗 toast。
  void fail(
    int token, {
    required Map<String, Object?> failure,
    required VoidCallback onUnseen,
    VoidCallback? retry,
  }) {
    final _Ticket? ticket = _tickets[token];
    if (ticket == null) {
      onUnseen();
      return;
    }
    // 先过「制卡提示」开关：被关掉的重复提示去掉 message、标 hostReported（按钮照旧按
    // duplicate 画 ✓）。不在屏上的判定由下面按探针做，这里恒按「在屏上」裁。
    final Map<String, Object?> said = MineFailureNotice.settle(
      failure,
      originOnScreen: true,
    );
    final Object? message = said['message'];
    final Map<String, Object?> outcome = <String, Object?>{
      'settled': 'failed',
      if (message is String && message.isNotEmpty) 'message': message,
      if (said['duplicate'] == true) 'duplicate': true,
      if (said[MineFailureNotice.hostReportedKey] == true)
        MineFailureNotice.hostReportedKey: true,
      'retryable': retry != null,
    };
    ticket
      ..state = _TicketState.failed
      ..retry = retry
      ..outcome = outcome;
    final Completer<Map<String, Object?>>? waiter = ticket.waiter;
    if (waiter != null) {
      ticket.waiter = null;
      if (ticket.waiterOrigin!()) {
        waiter.complete(outcome);
      } else {
        ticket.outcome = _hostReported(outcome);
        onUnseen();
        waiter.complete(ticket.outcome!);
      }
      return;
    }
    // 还没有等待者：卡若还在（或回包还没交出去、不知道在不在），popup.js 的等待马上
    // 就到，先压着；卡已不在则现在就交给调用方。
    ticket.onUnseen = onUnseen;
    _settleHeldIfOriginGone(ticket);
  }

  /// 查词卡关了 / 换了词（route 作废）之后调：压着的失败若发起它的卡已不在屏上，
  /// 改由 `onUnseen` 说。
  void recheckHeld() {
    for (final _Ticket ticket in List<_Ticket>.of(_tickets.values)) {
      _settleHeldIfOriginGone(ticket);
    }
  }

  /// popup.js `retryQueuedMine` 桥 / 主窗 toast 的「重试」：两条入口经这里收口，
  /// 同一次失败只重写一次。返回：
  /// * `'queued'`：重写已开始（或另一条入口已经开始了）——继续 [wait] 同一个令牌；
  /// * `'landed'`：这张卡其实已经落地；
  /// * `'unavailable'`：没有这张单，或这次失败不能重写（如重复卡）。
  String retry(int token) {
    final _Ticket? ticket = _tickets[token];
    if (ticket == null) return 'unavailable';
    switch (ticket.state) {
      case _TicketState.pending:
        return 'queued';
      case _TicketState.landed:
        return 'landed';
      case _TicketState.failed:
        final VoidCallback? rerun = ticket.retry;
        if (rerun == null) return 'unavailable';
        ticket
          ..state = _TicketState.pending
          ..retry = null
          ..outcome = null
          ..onUnseen = null;
        rerun();
        return 'queued';
    }
  }

  void _settleHeldIfOriginGone(_Ticket ticket) {
    final VoidCallback? held = ticket.onUnseen;
    if (held == null) return;
    final MineOriginOnScreen? origin = ticket.origin;
    // 探针还没登记 = 回包还没交给弹窗，弹窗的等待会到，继续压着。
    if (origin == null || origin()) return;
    ticket
      ..onUnseen = null
      ..outcome = _hostReported(ticket.outcome!);
    held();
  }

  void _evict(_Ticket ticket) {
    final Completer<Map<String, Object?>>? waiter = ticket.waiter;
    ticket.waiter = null;
    waiter?.complete(_unknown);
    final VoidCallback? held = ticket.onUnseen;
    ticket.onUnseen = null;
    held?.call();
  }

  static const Map<String, Object?> _unknown = <String, Object?>{
    'settled': 'unknown',
  };

  static Map<String, Object?> _hostReported(Map<String, Object?> outcome) =>
      <String, Object?>{
        for (final MapEntry<String, Object?> e in outcome.entries)
          if (e.key != 'message') e.key: e.value,
        MineFailureNotice.hostReportedKey: true,
      };
}

enum _TicketState { pending, landed, failed }

class _Ticket {
  _TicketState state = _TicketState.pending;
  MineOriginOnScreen? origin;
  Completer<Map<String, Object?>>? waiter;
  MineOriginOnScreen? waiterOrigin;
  Map<String, Object?>? outcome;
  VoidCallback? retry;

  /// 已失败、还没决定由谁说的那句话的主窗出口（非 null = 压着）。
  VoidCallback? onUnseen;
}
