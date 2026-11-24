import 'dart:ffi';
import 'dart:isolate';

import '../fushi_compute_library.dart';

/// `Dart_PostCObject`（`NativeApi.postCObject` 的类型）。
typedef PostCObjectNative = Int8 Function(Int64, Pointer<Dart_CObject>);

/// `void (*)(void*)` 形态的 C 回调（libmpv 的唤醒回调等）。
typedef PortWakeupNative = Void Function(Pointer<Void>);

/// 原生线程把事件发回本 isolate 的通道：一个 [ReceivePort]，原生侧拿它的
/// [SendPort.nativePort] 与 `NativeApi.postCObject` 发消息（`native/fushi_compute/src/dart_port.rs`）。
///
/// 取代 `NativeCallable.listener`（BUG-5413，反馈 Wgbo462Sfc）：listener 归属创建它的 isolate，
/// isolate 一销毁 VM 就删掉它，进程级的原生工作线程之后再调，VM 直接 abort 整个进程（Android 上
/// audio_service 在 Activity 走后销毁 FlutterEngine、进程留在后台，就是这样闪退的）。端口则随 isolate
/// 关闭，原生侧发往已关端口只是丢消息；下一个 isolate 登记自己的端口即可。
final class NativeEventPort {
  /// 每条消息（原生侧发的 `int` 列表）交给 [onMessage]。端口与本 isolate 同生命周期、不关闭：
  /// 进程级引擎随时可能发事件（与之前「建一次、永不关闭」的 callable 一样）。
  NativeEventPort(void Function(List<int> message) onMessage)
    : _port = ReceivePort('fushi_compute native events') {
    _port.listen((Object? message) {
      if (message is List) onMessage(message.cast<int>());
    });
  }

  final ReceivePort _port;

  /// 交给原生侧的端口号。
  int get nativePort => _port.sendPort.nativePort;

  /// 交给原生侧的发送入口（VM 的进程级函数，不随 isolate 失效）。
  Pointer<NativeFunction<PostCObjectNative>> get post => NativeApi.postCObject;
}

/// 本库的 `ffc_port_wakeup`：交给只认 `void (*)(void*)` 的 C 库当回调，`d` 指向
/// `{ Pointer postCObject; Int64 port; Int64 value; }`（C 布局，`dart_port.rs` 的 `PortWakeup`；
/// media_kit 补丁里的 `PortWakeupData`），每次被调就把 `value` 作为一个 `int` 发到 `port`。
/// 接收的 isolate 没了也安全。
///
/// 库缺这个符号（比绑定旧）抛 [FushiComputeUnavailableError]。
Pointer<NativeFunction<PortWakeupNative>> fushiComputePortWakeup([
  FushiCompute? lib,
]) {
  final FushiCompute library = lib ?? FushiCompute.require();
  try {
    return library.library.lookup<NativeFunction<PortWakeupNative>>(
      'ffc_port_wakeup',
    );
  } on ArgumentError catch (e) {
    throw library.missingSymbols('dart_port', e.message ?? e);
  }
}
