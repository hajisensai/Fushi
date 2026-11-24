// review-gal-overlay-mine-fail — app 外查词卡（游戏内 / 浮窗）上「后台写卡」的台账与
// 结局推送。
//
// gal 查词制卡（反馈 y90oiVojic / BUG-5386）采样完就给弹窗回 `queued`，按钮画成
// 「已加入」并解锁，编码 + 写卡在宿主后台完成。弹窗手里那个「已加入」只是 popup.js
// 闭包里的一个标记，宿主以前没有任何办法回头告诉它结局：
//
// * 写卡失败只走主窗 toast——游戏全屏时主窗在后台，用户看不见（回退 BUG-1908）；
// * 同一弹窗再点 ✓ 走 `queueOverwrite` 桥，native 不认它、即时回 null，popup.js 读成
//   「还在写入」；写卡早就失败了也照样这么说，永远撤不掉。
//
// 这里补上两半：
// * [OverlayQueuedMines.settle] 在落地时把结局推进**发起那次制卡的覆盖窗**
//   （[GlobalLookupChannel.settleQueuedMine] → native → host.js → popup.js
//   `fushiSettleQueuedMine`），弹窗撤掉「已加入」并就地说原因；
// * [OverlayQueuedMines.queueOverwriteReply] 给 deferred 的 `queueOverwrite` 桥一个
//   真回答：还在写 / 已落地 / 已失败（带原因）。

import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/lookup/global_lookup_log.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show QueuedOverwriteReply, QueuedOverwriteSettled;
import 'package:fushi/src/utils/misc/toast_severity.dart';

/// 一次后台写卡的结局（推给 popup.js 的 `outcome` 字段同名）。
enum QueuedMineOutcome {
  /// 卡进了 Anki。
  landed,

  /// 没写进去（后端没开 / 没配置 / 出错 / 引擎中止）。
  failed,

  /// Anki 里本来就有这张卡（没新增，但卡确实在）。
  duplicate,
}

/// 推给覆盖窗的一次结局。
@immutable
class QueuedMineSettlement {
  const QueuedMineSettlement({
    required this.expression,
    required this.reading,
    required this.outcome,
    this.token,
    this.noteId,
    this.message,
  });

  /// 由宿主给弹窗的那种制卡回包（`{ankiConnect, noteId, duplicate?, queued?,
  /// message?}`）推出结局。回包还是 `queued`（进了离线待发队列，卡仍在路上）时
  /// 返回 null：「已加入」依然属实，不推。
  ///
  /// 重复结果的原因要先过「制卡提示」开关（[MineNotices.shown]）：用户关了重复提示，
  /// 就地也不说（与 MineFailureNotice 同口径），按钮照旧画成 ✓。
  static QueuedMineSettlement? fromPopupReply(
    Map<String, Object?> reply, {
    required String expression,
    required String reading,
    int? token,
  }) {
    if (reply['queued'] == true) return null;
    if (reply['ankiConnect'] == true) {
      final Object? noteId = reply['noteId'];
      return QueuedMineSettlement(
        expression: expression,
        reading: reading,
        outcome: QueuedMineOutcome.landed,
        token: token,
        noteId: noteId is num ? noteId.toInt() : null,
      );
    }
    final bool duplicate = reply['duplicate'] == true;
    final Object? rawMessage = reply['message'];
    final String? message = rawMessage is String && rawMessage.isNotEmpty
        ? rawMessage
        : null;
    final bool muted =
        duplicate && !MineNotices.shown(MineToastStatus.duplicate);
    return QueuedMineSettlement(
      expression: expression,
      reading: reading,
      outcome: duplicate
          ? QueuedMineOutcome.duplicate
          : QueuedMineOutcome.failed,
      token: token,
      message: muted ? null : message,
    );
  }

  final String expression;
  final String reading;
  final QueuedMineOutcome outcome;

  /// 那次后台写卡的凭据（[QueuedMineTicket.token]，随 queued 回包的
  /// [OverlayQueuedMines.queuedTokenKey] 交给过弹窗）：popup.js 凭它对号认领，
  /// 而不是凭「同词」猜。
  final int? token;
  final int? noteId;
  final String? message;

  Map<String, Object?> toJson() => <String, Object?>{
    'expression': expression,
    'reading': reading,
    'outcome': outcome.name,
    if (token != null) 'token': token,
    if (noteId != null) 'noteId': noteId,
    if (message != null) 'message': message,
  };
}

/// 把结局送进某条查词路由的覆盖窗。生产走 [GlobalLookupChannel.settleQueuedMine]；
/// 测试经 [OverlayQueuedMines.debugPusher] 换成记录器。
typedef QueuedMinePusher =
    Future<void> Function(GlobalLookupRoute route, Map<String, Object?> json);

/// [OverlayQueuedMines.begin] 发出的一次后台写卡凭据：结局凭它推回发起它的覆盖窗
/// （[route]），并认领台账里这个词的那一格（同词又挖了一次时旧凭据不再认领）。
@immutable
class QueuedMineTicket {
  const QueuedMineTicket._({
    required this.token,
    required this.route,
    required this.expression,
    required this.reading,
  });

  final int token;
  final GlobalLookupRoute route;
  final String expression;
  final String reading;

  /// 给弹窗的 queued 回包带上本次凭据（[OverlayQueuedMines.queuedTokenKey]）。结局推送
  /// 与这份回包是两条各自异步的出口，写卡失败得够快时结局可能先到；popup.js 凭 token
  /// 把先到的结局暂存、回包一到当场兑现，不靠两条出口的先后。
  Map<String, Object?> queuedPopupReply(Map<String, Object?> queuedReply) =>
      <String, Object?>{
        ...queuedReply,
        OverlayQueuedMines.queuedTokenKey: token,
      };
}

/// 台账里一个词的最近一次后台写卡：[settlement] 为 null = 还在写。
class _QueuedMineEntry {
  _QueuedMineEntry(this.token);

  final int token;
  QueuedMineSettlement? settlement;
}

/// app 外查词卡后台写卡的台账（按词 = expression + reading 记最近一次）。
abstract final class OverlayQueuedMines {
  /// queued 回包里携带 [QueuedMineTicket.token] 的键（popup.js `parseMineResult`
  /// 读同名字段）。
  static const String queuedTokenKey = 'queuedToken';

  /// 同时记着的词数上限：每次 [begin] 只新增一条，结局记下后还要留着给晚到的
  /// `queueOverwrite` 回问用，超过就丢最早的一条（那个弹窗早就不在了）。
  static const int _capacity = 64;

  static final LinkedHashMap<String, _QueuedMineEntry> _entries =
      LinkedHashMap<String, _QueuedMineEntry>();
  static int _nextToken = 0;

  static QueuedMinePusher _pusher = _pushToOverlay;

  static Future<void> _pushToOverlay(
    GlobalLookupRoute route,
    Map<String, Object?> json,
  ) => GlobalLookupChannel.runWithRoute(
    route,
    () => GlobalLookupChannel.settleQueuedMine(json),
  );

  /// 测试注入点；传 null 复原生产出口。
  @visibleForTesting
  static set debugPusher(QueuedMinePusher? pusher) =>
      _pusher = pusher ?? _pushToOverlay;

  @visibleForTesting
  static void debugReset() {
    _entries.clear();
    _nextToken = 0;
    _pusher = _pushToOverlay;
  }

  static String _key(String expression, String reading) =>
      '${expression.trim()}\u0000${reading.trim()}';

  /// 弹窗刚拿到 `queued`、写卡转后台时调。[route] 是发起这次制卡的查词路由（结局
  /// 要推回那个覆盖窗）。
  static QueuedMineTicket begin({
    required String expression,
    required String reading,
    required GlobalLookupRoute route,
  }) {
    final String key = _key(expression, reading);
    final int token = ++_nextToken;
    _entries.remove(key);
    _entries[key] = _QueuedMineEntry(token);
    while (_entries.length > _capacity) {
      _entries.remove(_entries.keys.first);
    }
    return QueuedMineTicket._(
      token: token,
      route: route,
      expression: expression,
      reading: reading,
    );
  }

  /// 后台写卡有了结局（[reply] 是宿主给弹窗的那种回包）：记进台账，并推进发起它的
  /// 覆盖窗。回包仍是 `queued`（进了离线待发队列）时什么都不做——「已加入」依然属实。
  /// [ticket] 已被同词的新一次 [begin] 顶掉时只推不记：旧按钮若还在也该撤「已加入」，
  /// 台账留给新那次。推送失败只记日志：结局主窗 toast 已经说过了。
  static Future<void> settle(
    QueuedMineTicket ticket,
    Map<String, Object?> reply,
  ) async {
    final QueuedMineSettlement? settlement =
        QueuedMineSettlement.fromPopupReply(
          reply,
          expression: ticket.expression,
          reading: ticket.reading,
          token: ticket.token,
        );
    if (settlement == null) return;
    final _QueuedMineEntry? entry =
        _entries[_key(ticket.expression, ticket.reading)];
    if (entry != null && entry.token == ticket.token) {
      entry.settlement = settlement;
    }
    try {
      await _pusher(ticket.route, settlement.toJson());
    } catch (error) {
      glog('queuedMine: settle push FAILED (non-fatal): $error');
    }
  }

  /// deferred `queueOverwrite` 桥的回答（app 外查词卡上再点「已加入」的 ✓）。
  ///
  /// * 还在写 → 不收（gal 的覆写要重抓当前画面与句音，不能排到写入之后再做），
  ///   不带 message：popup.js 说「还在写入 Anki，稍后再试」，落地时宿主那一推会把
  ///   按钮翻成 ✓ / +；
  /// * 已落地（或 Anki 里本来就有）→ `settled: landed`，popup.js 走已制卡的正常覆写路径；
  /// * 已失败 → `settled: failed` + 原因，popup.js 撤掉「已加入」并就地说；
  /// * 台账里没有（不是后台写卡排的队，如离线待发队列）→ 不收，同第一条。
  static QueuedOverwriteReply queueOverwriteReply({
    required String expression,
    required String reading,
  }) {
    final QueuedMineSettlement? settlement =
        _entries[_key(expression, reading)]?.settlement;
    if (settlement == null) return const QueuedOverwriteReply();
    return switch (settlement.outcome) {
      QueuedMineOutcome.landed || QueuedMineOutcome.duplicate =>
        const QueuedOverwriteReply(settled: QueuedOverwriteSettled.landed),
      QueuedMineOutcome.failed => QueuedOverwriteReply(
        settled: QueuedOverwriteSettled.failed,
        message: settlement.message,
      ),
    };
  }
}
