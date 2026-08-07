/// 漫画阅读器「窗口文档加载」的所有权闸门。
///
/// 一次 `loadData` 对应一个 generation 和一把 ready 锁。难点全在**跨 await 的迟到
/// 回调**：WebView 的 `onLoadStop` / Windows 的 `onReceivedError-as-success` 会在
/// 旧窗口被放弃、新窗口已启动之后才到达，而回调内部还要再跑几次
/// `evaluateJavascript`。只在入口比一次 generation 是不够的——迟到的旧回调会
/// complete 掉**新**窗口的锁，导航锁被错误解除，WebView 还在加载旧内容就被判定
/// 就绪（BUG-1170）。
///
/// 因此本类不暴露裸字段：所有收尾都必须带上开始时拿到的
/// [MangaWindowLoadTicket]，凭据不再是当前那次加载时一律拒绝。
library;

import 'dart:async';

/// 一次窗口文档加载的收尾状态。
///
/// [ready]：新文档自证持有本次 generation，滚动/translate 已应用，导航锁可解除。
/// [abandoned]：页面在加载途中被销毁——既不是就绪也不是失败，必须让等待方立刻
/// 返回，而不是等满超时再抛出一个没人接的异步异常（BUG-1171）。
enum MangaWindowLoadOutcome { ready, abandoned }

/// 一次加载的凭据：generation + 该次加载专属的 ready 锁。
class MangaWindowLoadTicket {
  MangaWindowLoadTicket._(this.generation, this._completer);

  final int generation;
  final Completer<MangaWindowLoadOutcome> _completer;

  /// 等待本次加载收尾（就绪或被放弃）。
  Future<MangaWindowLoadOutcome> get outcome => _completer.future;
}

/// 见库级注释。
class MangaWindowLoadGate {
  int _generation = 0;
  MangaWindowLoadTicket? _pending;

  /// 当前 generation（写进窗口文档，供文档自证归属）。
  int get generation => _generation;

  /// 是否有加载在飞。
  bool get hasPendingLoad => _pending != null;

  /// 开一次新加载：递增 generation 并换上新锁。旧锁**不**在这里收尾——旧加载
  /// 自己的 timeout/catch 负责，[finish] 只清当前锁。
  MangaWindowLoadTicket begin() {
    _generation += 1;
    final MangaWindowLoadTicket ticket = MangaWindowLoadTicket._(
      _generation,
      Completer<MangaWindowLoadOutcome>(),
    );
    _pending = ticket;
    return ticket;
  }

  /// 文档自报 [documentGeneration] 时取凭据。不是当前在飞的那次加载（含
  /// generation 缺失/解析失败）时返回 null。
  MangaWindowLoadTicket? ticketFor(int? documentGeneration) {
    final MangaWindowLoadTicket? pending = _pending;
    if (pending == null || documentGeneration != _generation) {
      return null;
    }
    return pending;
  }

  /// [ticket] 是否仍是当前在飞的那次加载（每个 await 之后都要问一次）。
  bool owns(MangaWindowLoadTicket ticket) => identical(_pending, ticket);

  /// 用 [outcome] 收尾 [ticket]。返回是否真的生效：迟到的旧回调拿 false，
  /// 调用方据此停手，绝不能接着按「已就绪」处理。
  bool complete(MangaWindowLoadTicket ticket, MangaWindowLoadOutcome outcome) {
    if (!owns(ticket) || ticket._completer.isCompleted) {
      return false;
    }
    ticket._completer.complete(outcome);
    return true;
  }

  /// 本次加载彻底结束（成功/失败/放弃）后清锁；只清自己那把。
  void finish(MangaWindowLoadTicket ticket) {
    if (owns(ticket)) {
      _pending = null;
    }
  }

  /// 页面销毁：把在飞的锁以 [MangaWindowLoadOutcome.abandoned] 收尾，等待方立刻
  /// 返回，不再挂满超时后从 `unawaited` 调用点抛未捕获异步异常（BUG-1171）。
  void abandon() {
    final MangaWindowLoadTicket? pending = _pending;
    _pending = null;
    if (pending != null && !pending._completer.isCompleted) {
      pending._completer.complete(MangaWindowLoadOutcome.abandoned);
    }
  }
}
