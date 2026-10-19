import 'dart:async';

/// 后台借用原生词典句柄的账本与原语（HBK-AUDIT-009）。
///
/// 原生侧（`native/fushidicts/fushidicts_ffi.cpp`）的句柄带引用计数：
/// `fushidicts_retain` 借一个引用、`fushidicts_release` 还一个，`fushidicts_destroy`
/// 只是退役——最后一个引用归还时才真正销毁、解除文件映射。于是 Dart 侧可以在主
/// isolate 上 retain、把句柄地址交给后台 isolate 去算，词典重载照常 dispose 旧实例，
/// 不会把在飞的后台调用变成释放后使用。
///
/// 这里只管 Dart 侧的两条不变式：
/// 1. **retain 与 release 一一对应**：借到了就一定还，工作体抛异常 / 后台 isolate
///    起不来也一样还；没借到（句柄已退役）就不跑工作体、也不还。retain 与 release
///    都在调用方（主）isolate 上做：工作体是否真的在后台跑完，主 isolate 看得见，
///    后台 isolate 起不来时由谁还引用也就不会有歧义。
/// 2. **「释放映射」要等在飞借用全部归还**：Windows 上句柄销毁才解除 `MapViewOfFile`，
///    删词典目录（BUG-1756）必须等最后一个后台借用还掉之后。[BackgroundBorrowLedger.settled]
///    给出这个时刻。
///
/// 原生调用本身被注入（[borrowNativeHandle] 的 retain / release / work），所以这套
/// 次序能在没有原生库的单测里用屏障直接验证。
class BackgroundBorrowLedger {
  final Set<Future<void>> _inFlight = <Future<void>>{};

  /// 当前未归还的借用数。
  int get inFlight => _inFlight.length;

  /// 登记一个进行中的借用；[done] 完成（无论成功失败）即视为已归还。
  void _track(Future<void> done) {
    _inFlight.add(done);
    done.whenComplete(() => _inFlight.remove(done));
  }

  /// 此刻已登记的借用全部归还后完成（之后新登记的不等）。没有在飞借用时立即完成。
  Future<void> settled() async {
    if (_inFlight.isEmpty) return;
    await Future.wait<void>(_inFlight.toList());
  }
}

/// 借一个原生句柄引用，跑 [work]，跑完（无论成败）还掉。
///
/// [retain] 返回 false（句柄已退役）时不跑 [work]，返回 null。[work] 抛出的异常原样
/// 传给调用方，引用照样归还。借用期间登记在 [ledger] 里，供「释放映射」等待。
Future<T?> borrowNativeHandle<T>({
  required BackgroundBorrowLedger ledger,
  required bool Function() retain,
  required void Function() release,
  required Future<T> Function() work,
}) {
  if (!retain()) return Future<T?>.value();
  final Completer<void> returned = Completer<void>();
  ledger._track(returned.future);
  Future<T> running;
  try {
    running = work();
  } catch (error, stack) {
    running = Future<T>.error(error, stack);
  }
  return running.whenComplete(() {
    try {
      release();
    } finally {
      // release 自己抛了也要结算，否则 settled() 永远等不到。
      returned.complete();
    }
  });
}
