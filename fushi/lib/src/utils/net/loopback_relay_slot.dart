import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 进程内 loopback 中继（应用内网络中继 `AppNativeProxy`、`YoutubeRangeRelay`、
/// `CloudVideoStreamRelay`）共同的最小面：监听端口、自报的运行状态、关闭。
abstract interface class LoopbackRelay {
  /// 监听的 loopback 端口。
  int get port;

  /// 中继自己知道的状态：`close()` 过或监听流收到 done / error 时为 false。
  ///
  /// **这不是活性判据**：iOS 挂起 app 后会回收监听 socket，Dart 的
  /// `HttpServer` 监听流既不报 done 也不报 error，此值仍为 true，而 native 客户端
  /// 每次连这个端口都是 `Connection refused`（反馈 TUA4_h7d6a）。活性以
  /// [LoopbackRelaySlot] 的真实连接探测为准。
  bool get isRunning;

  Future<void> close();
}

/// 探测本机 [port] 上还有没有在 accept 的监听 socket：真连一次 loopback 再立刻断开。
///
/// 被回收 / 已关闭的端口 loopback 上是立即 `ECONNREFUSED`；[timeout] 只是给极端情况
/// （内核卡住）兜一个上界，不是重试。
Future<bool> loopbackListenerAccepts(
  int port, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  try {
    final Socket socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: timeout,
    );
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

/// [LoopbackRelaySlot] 用来判活的探测函数（测试可替换以模拟「端口被系统回收，
/// 中继对象却仍自报运行」的状态）。
@visibleForTesting
Future<bool> Function(int port) loopbackRelayProbe = loopbackListenerAccepts;

/// 一个 loopback 中继的进程内单例槽：每次交出前**先真连探活**，死了就关掉旧的、另起一个。
///
/// 以前三个中继各自写「`await cached` 后 `isRunning` 为 true 就复用」。`isRunning` 只
/// 反映 Dart 侧有没有收到关闭事件，iOS 回收监听 socket 时收不到，于是缓存里一直是个
/// 死端口：mpv 的 `http-proxy` 每次都 `Connection refused`，媒体服务器片永远打不开，
/// 只能杀进程重启 app（TUA4_h7d6a 日志里同一进程同一端口反复被拒）。
///
/// 新的 Future 在任何 await 之前就写回槽里，并发调用排在同一条链上，因此仍只起一个
/// 中继；起中继失败的 Future 下一次调用会被替换，不缓存成终身答案（BUG-2381）。
final class LoopbackRelaySlot<T extends LoopbackRelay> {
  LoopbackRelaySlot({
    required Future<T> Function() start,
    required void Function(String message) log,
  }) : _start = start,
       _log = log;

  final Future<T> Function() _start;
  final void Function(String message) _log;
  Future<T>? _current;

  /// 交出一个监听端口确实在 accept 的中继。
  Future<T> acquire() {
    final Future<T> next = _revalidate(_current);
    _current = next;
    return next;
  }

  Future<T> _revalidate(Future<T>? cached) async {
    if (cached != null) {
      try {
        final T relay = await cached;
        if (relay.isRunning && await loopbackRelayProbe(relay.port)) {
          return relay;
        }
        _log(
          'loopback relay on port ${relay.port} stopped accepting; restarting',
        );
        // 旧对象还握着 HttpServer / 上游客户端，释放掉；关闭失败只记日志，不影响新中继。
        unawaited(
          relay.close().catchError(
            (Object error) =>
                _log('closing dead loopback relay failed: $error'),
          ),
        );
      } on Object catch (error) {
        _log('loopback relay restarting after $error');
      }
    }
    return _start();
  }
}
