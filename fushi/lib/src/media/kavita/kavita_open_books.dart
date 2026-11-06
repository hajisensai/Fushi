/// 阅读器里正打开的 Kavita 绑定书（进程内登记）。
///
/// 两个消费方：
/// - 后台进度对账（`KavitaProgressRefresher`）：阅读器开着的那本书由阅读器自己的
///   同步会话负责，后台对账一律跳过，绝不改写正在读的书的位置；
/// - Kavita 书系列页：关书后要等阅读器把最后一页推给服务器再重取章节进度。关书时
///   的推送在阅读器 dispose 里发起（dispose 是同步的，拿不到 future），所以由这里
///   把「关书 flush」的 future 交出去（[settled]），页面 await 它，而不是靠固定延时
///   轮询猜推送何时落地。
///
/// 同一本书可能同时开着多个阅读器（多窗口 / 分屏），按持有数计数；最后一个持有者
/// 关闭且它们的 flush 全部结束后，[settled] 才完成。
library;

import 'dart:async';

class KavitaOpenBooks {
  KavitaOpenBooks._();

  static final Map<String, _OpenBook> _books = <String, _OpenBook>{};

  /// 阅读器开始持有 [bookKey]。
  static void opened(String bookKey) {
    final _OpenBook book = _books.putIfAbsent(bookKey, _OpenBook.new);
    book.holders++;
  }

  /// 阅读器释放 [bookKey]；[flush] 是关书时推送最后进度的 future（没有就不传）。
  /// 与 [opened] 成对调用；多调用一次是无害的空操作。
  static void closed(String bookKey, {Future<void>? flush}) {
    final _OpenBook? book = _books[bookKey];
    if (book == null || book.holders == 0) return;
    // 推送失败（超时 / 离线）也算「结束」：吞掉错误再存，免得在等其它持有者期间
    // 成为未处理的异步错误。
    if (flush != null) {
      book.flushes.add(flush.then<void>((_) {}, onError: (Object _) {}));
    }
    book.holders--;
    if (book.holders > 0) return;
    final List<Future<void>> pending = List<Future<void>>.of(book.flushes);
    book.flushes.clear();
    unawaited(
      Future.wait<void>(pending).whenComplete(() {
        // 等待期间又被重新打开：那一轮的 settled 由新的持有者负责完成。
        if (book.holders > 0) return;
        if (identical(_books[bookKey], book)) _books.remove(bookKey);
        if (!book.done.isCompleted) book.done.complete();
      }),
    );
  }

  /// [bookKey] 此刻是否有阅读器开着。
  static bool isOpen(String bookKey) => (_books[bookKey]?.holders ?? 0) > 0;

  /// 阅读器全部关闭、关书推送全部结束时完成；没开着也没在推的书立即完成。
  static Future<void> settled(String bookKey) =>
      _books[bookKey]?.done.future ?? Future<void>.value();
}

class _OpenBook {
  int holders = 0;
  final List<Future<void>> flushes = <Future<void>>[];
  final Completer<void> done = Completer<void>();
}
