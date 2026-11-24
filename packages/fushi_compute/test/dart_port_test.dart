import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

typedef _FireDart = void Function(Pointer<Void>);

/// 原生 → Dart 的端口出口（native/fushi_compute/src/dart_port.rs）对真原生库端到端。
///
/// 反馈 Wgbo462Sfc：`NativeCallable.listener` 的跳板随 isolate 关闭被删，进程级原生线程（音频分析 /
/// 超分 / libmpv 唤醒）再调就整进程 SIGABRT。端口出口在 isolate 没了之后投递只是失败——这里让
/// 「目标 isolate 已退出后再唤醒」真实发生：若退回函数指针回调，本测试进程会直接 abort。
void main() {
  final FushiComputePortSignal signal = FushiComputePortSignal.instance;
  final _FireDart fire = signal.fire.asFunction<_FireDart>();

  test('fire posts the target value to its port, from any caller', () async {
    final ReceivePort port = ReceivePort();
    final Pointer<Void> target = signal.create(
      port.sendPort.nativePort,
      0x7f00deadbeef,
    );
    fire(target);
    fire(target);
    final List<Object?> got = await port.take(2).toList();
    expect(got, <Object?>[0x7f00deadbeef, 0x7f00deadbeef]);
    signal.free(target);
    port.close();
  });

  test('firing after the owning isolate exited is harmless', () async {
    // 目标端口建在另一个 isolate 里，它随即退出（端口随之关闭）——等同引擎销毁后 libmpv 仍持有
    // 唤醒目标。
    final int address = await Isolate.run(() {
      final RawReceivePort owned = RawReceivePort((Object? _) {});
      return FushiComputePortSignal.instance
          .create(owned.sendPort.nativePort, 1)
          .address;
    });
    final Pointer<Void> orphan = Pointer<Void>.fromAddress(address);
    for (int i = 0; i < 100; i++) {
      fire(orphan);
    }
    signal.free(orphan);
  });

  test('music analysis keeps running when its event isolate is gone', () async {
    // 别的 isolate 启动引擎（事件端口在那边）后退出：引擎的工作线程往已关的端口投，不崩。
    expect(
      await Isolate.run(() => FushiComputeMusicAnalysis.instance.start()),
      FfcStatus.ok,
    );
    final FushiComputeMusicAnalysis engine = FushiComputeMusicAnalysis.instance;
    // 没有这个文件：工作线程出队、发 started / failed 到已关的端口。
    expect(
      engine.submit(
        token: 61,
        pcmPath: '/fushi-no-such-dir/missing.s16le',
        outPath: '/fushi-no-such-dir/missing.fma',
      ),
      FfcStatus.ok,
    );
    // 本 isolate 接手：再 start 一次换成自己的端口，后面那首的事件照常到。
    expect(engine.start(), FfcStatus.ok);
    final Completer<void> done = Completer<void>();
    final StreamSubscription<FfcManaEvent> sub = engine.events.listen((
      FfcManaEvent e,
    ) {
      if (e.token == 62 && e.kind == FfcManaEventKind.failed) {
        done.complete();
      }
    });
    expect(
      engine.submit(
        token: 62,
        pcmPath: '/fushi-no-such-dir/missing2.s16le',
        outPath: '/fushi-no-such-dir/missing2.fma',
      ),
      FfcStatus.ok,
    );
    await done.future.timeout(const Duration(seconds: 30));
    await sub.cancel();
  });
}
