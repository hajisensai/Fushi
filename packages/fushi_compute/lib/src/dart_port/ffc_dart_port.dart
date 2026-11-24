import 'dart:ffi';
import 'dart:isolate';

import '../fushi_compute_library.dart';

/// 原生 → Dart 的事件出口（native/fushi_compute/src/dart_port.rs）：原生线程用 `Dart_PostCObject`
/// 往本 isolate 的一个原生端口投消息，**不经 `NativeCallable`**。
///
/// `NativeCallable.listener` 的跳板属于建它的 isolate：isolate 一关（Android 上 audio_service 在
/// Activity 退出后 `FlutterEngine.destroy()`、热重启、macOS `NSApp terminate`）VM 就删掉跳板，进程级
/// 原生工作线程再调一次就是 `Callback invoked after it has been deleted` → 整进程 SIGABRT（反馈
/// Wgbo462Sfc）。端口随 isolate 关掉后投递只是返回 false，进程无事；Dart 侧也就不需要一个并不存在的
/// 「isolate 将死」同步钩子去先摘回调。
final class FfcEventPort {
  /// 收到的每条消息是原生投来的一组整数，交给 [onEvent]。
  FfcEventPort(void Function(List<int> values) onEvent)
    : _port = RawReceivePort((Object? message) {
        if (message is List) onEvent(message.cast<int>());
      }, 'fushi_compute events');

  final RawReceivePort _port;

  /// 交给原生的端口号。
  int get nativePort => _port.sendPort.nativePort;

  /// `Dart_PostCObject` 的地址（VM 导出，进程内一直有效），与 [nativePort] 成对交给原生。
  static Pointer<Void> get postCObject => NativeApi.postCObject.cast<Void>();
}

typedef _SignalNewC = Pointer<Void> Function(Pointer<Void>, Int64, Int64);
typedef _SignalNewDart = Pointer<Void> Function(Pointer<Void>, int, int);
typedef _SignalFreeC = Void Function(Pointer<Void>);
typedef _SignalFreeDart = void Function(Pointer<Void>);

/// 给只接受 `void (*)(void *data)` 唤醒回调的 C 库（libmpv 的 `mpv_set_wakeup_callback`）用的端口唤醒：
/// 回调填 [fire]，`data` 填 [create] 的返回值；每次唤醒把建目标时给的整数投到那个端口。
///
/// [fire] 是 fushi_compute 里的原生函数（库不卸载），目标是原生堆上的小结构：外部库活得比 isolate 久时
/// 照样可调，端口关了只是投递失败。目标只能在外部库保证不再唤醒之后 [free]（libmpv：
/// `mpv_set_wakeup_callback(ctx, NULL, NULL)` 返回后）。
final class FushiComputePortSignal {
  FushiComputePortSignal._(FushiCompute lib)
    : fire = lib.library.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
        'ffc_port_signal_fire',
      ),
      _new = lib.library.lookupFunction<_SignalNewC, _SignalNewDart>(
        'ffc_port_signal_new',
      ),
      _free = lib.library.lookupFunction<_SignalFreeC, _SignalFreeDart>(
        'ffc_port_signal_free',
      );

  static FushiComputePortSignal? _instance;

  /// 默认库上的绑定。库不可用或缺符号抛 [FushiComputeUnavailableError]。
  static FushiComputePortSignal get instance =>
      _instance ??= _bind(FushiCompute.require());

  static FushiComputePortSignal _bind(FushiCompute lib) {
    try {
      return FushiComputePortSignal._(lib);
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('dart_port', e.message ?? e);
    }
  }

  /// 唤醒函数 `void ffc_port_signal_fire(void *target)`，任意线程可调。
  final Pointer<NativeFunction<Void Function(Pointer<Void>)>> fire;
  final _SignalNewDart _new;
  final _SignalFreeDart _free;

  /// 建一个唤醒目标：之后每次 [fire] 它都把 [value] 投到 [nativePort]。
  Pointer<Void> create(int nativePort, int value) {
    final Pointer<Void> target = _new(
      FfcEventPort.postCObject,
      nativePort,
      value,
    );
    if (target == nullptr) {
      throw StateError('ffc_port_signal_new returned null');
    }
    return target;
  }

  /// 释放 [create] 建的目标（外部库已保证不再唤醒它之后）。
  void free(Pointer<Void> target) => _free(target);
}
