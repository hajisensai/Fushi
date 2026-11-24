import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

/// `dart_port.rs` 的 `PortWakeup`（media_kit 补丁里的 `PortWakeupData`）：`{ post, port, value }`。
final class _PortWakeup extends Struct {
  external Pointer<NativeFunction<PostCObjectNative>> post;

  @Int64()
  external int port;

  @Int64()
  external int value;
}

typedef _WakeupDart = void Function(Pointer<Void>);

/// `ffc_port_wakeup`（libmpv 唤醒回调的跳板，BUG-5413 / 反馈 Wgbo462Sfc）对真原生库端到端。
///
/// `NativeCallable.listener` 的跳板随 isolate 关闭被删，活得比 isolate 久的 libmpv 核心线程再调就整进程
/// SIGABRT。端口跳板在接收的 isolate 没了之后投递只是失败——这里让「目标 isolate 已退出后再唤醒」真实
/// 发生：若退回函数指针回调，本测试进程会直接 abort。
void main() {
  final _WakeupDart wakeup = fushiComputePortWakeup().asFunction<_WakeupDart>();

  Pointer<_PortWakeup> target(int nativePort, int value) {
    final Pointer<_PortWakeup> data = calloc<_PortWakeup>();
    data.ref
      ..post = NativeApi.postCObject
      ..port = nativePort
      ..value = value;
    return data;
  }

  test('wakeup posts the target value to its port', () async {
    final ReceivePort port = ReceivePort();
    final Pointer<_PortWakeup> data = target(
      port.sendPort.nativePort,
      0x7f00deadbeef,
    );
    wakeup(data.cast());
    wakeup(data.cast());
    wakeup(nullptr);
    final List<Object?> got = await port.take(2).toList();
    expect(got, <Object?>[0x7f00deadbeef, 0x7f00deadbeef]);
    calloc.free(data);
  });

  test('waking up after the owning isolate exited is harmless', () async {
    // 目标端口建在另一个 isolate 里，它随即退出（端口随之关闭）——等同引擎销毁后 libmpv 仍持有
    // 唤醒目标。
    final int nativePort = await Isolate.run(
      () => RawReceivePort((Object? _) {}).sendPort.nativePort,
    );
    final Pointer<_PortWakeup> orphan = target(nativePort, 1);
    for (int i = 0; i < 100; i++) {
      wakeup(orphan.cast());
    }
    calloc.free(orphan);
  });
}
