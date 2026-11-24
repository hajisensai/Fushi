// libmpv 唤醒改走 Dart 原生端口（反馈 Wgbo462Sfc）。
//
// 发布构建的 media_kit 原本给每个播放器注册一个 `NativeCallable.listener` 当 libmpv 唤醒回调。
// 那个跳板属于主 isolate，isolate 一关 VM 就删掉它；libmpv 核心线程再唤醒一次就是
// `Callback invoked after it has been deleted` → 整进程 SIGABRT。Android 上这是常态路径：
// `MainActivity` 继承 `AudioServiceActivity`，引擎由 audio_service 缓存，Activity 退出
// （根页返回）后服务解绑、`AudioService.onDestroy` 里 `FlutterEngine.destroy()` 关掉 isolate，
// 进程和没 dispose 的播放器都还在。销毁是 Java 侧同步做的，Dart 没有机会先摘回调。
//
// 所以不再给 libmpv Dart 函数指针：唤醒函数是 fushi_compute 里的原生函数（进程内常驻），
// 它把句柄地址投到主 isolate 的原生端口；isolate 没了投递只是失败。桌面退出时
// [AppExitCoordinator.begin] 的摘回调（BUG-4730）照旧，对端口方式同样有效。

import 'dart:ffi';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:media_kit/native_wakeup.dart';

/// [MpvPortWakeup] 的 fushi_compute 实现（`ffc_port_signal_*`）。
class FushiComputeMpvPortWakeup implements MpvPortWakeup {
  FushiComputeMpvPortWakeup([FushiComputePortSignal? signal])
    : _signal = signal ?? FushiComputePortSignal.instance;

  final FushiComputePortSignal _signal;

  @override
  Pointer<NativeFunction<Void Function(Pointer<Void>)>> get fire =>
      _signal.fire;

  @override
  Pointer<Void> create(int nativePort, int value) =>
      _signal.create(nativePort, value);

  @override
  void free(Pointer<Void> target) => _signal.free(target);
}

/// 启动时、建第一个播放器之前调一次（`main.dart` 紧跟 `MediaKit.ensureInitialized()`）。
void installFushiMpvPortWakeup() =>
    installMpvPortWakeup(FushiComputeMpvPortWakeup());
