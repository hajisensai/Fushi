import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/startup/media_handle_registry.dart';

/// TODO-1212：[MediaHandleRegistry] 是数据根迁移前触达页面级媒体播放器（视频主播放器
/// / 离屏缩略图取帧 Player）释放其 libmpv 文件句柄的唯一通道。这些播放器没有进程级
/// 持有者，迁移路径靠本注册表逐个 `await` 释放，确保 rename 数据根前句柄真放掉，避免
/// Windows 同盘 rename 撞「文件被占用」。
///
/// 本测试锁死注册表契约：register/unregister 幂等、releaseAll **await 到全部释放完成**
/// 再返回（迁移依赖此）、单来源卡住/抛异常不拖垮其余、releaseAll 后清空登记。
void main() {
  setUp(() => MediaHandleRegistry.instance.clear());
  tearDown(() => MediaHandleRegistry.instance.clear());

  test('register/unregister are idempotent and tracked by identity', () {
    final MediaHandleRegistry reg = MediaHandleRegistry.instance;
    expect(reg.callbackCount, 0);

    Future<void> cb() async {}
    reg.register(cb);
    reg.register(cb); // 同一实例重复登记不叠加。
    expect(reg.callbackCount, 1);

    reg.unregister(cb);
    expect(reg.callbackCount, 0);
    reg.unregister(cb); // 幂等：注销不存在的回调不抛。
    expect(reg.callbackCount, 0);
  });

  test('releaseAll awaits every callback to completion before returning',
      () async {
    final MediaHandleRegistry reg = MediaHandleRegistry.instance;
    final List<String> completed = <String>[];

    // 两个异步释放，各自在 await 后才记「完成」——releaseAll 必须 await 到两者都完成。
    reg.register(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      completed.add('a');
    });
    reg.register(() async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      completed.add('b');
    });

    await reg.releaseAll();

    // releaseAll 返回时两个释放都已完成（这是迁移「rename 前句柄真放掉」的契约）。
    expect(completed, containsAll(<String>['a', 'b']));
    // 消费后清空登记（快照 + clear），避免迁移路径重复触发已释放来源。
    expect(reg.callbackCount, 0);
  });

  test('a hung callback is bounded by perCallbackTimeout, others still run',
      () {
    // 用 FakeAsync 快进虚拟时间过 perCallbackTimeout，避免真实等待 5s。
    fakeAsync((FakeAsync async) {
      final MediaHandleRegistry reg = MediaHandleRegistry.instance;
      bool healthyRan = false;
      bool releaseAllDone = false;

      // 卡死的来源：永不完成。releaseAll 不得被它无限拖住（perCallbackTimeout 放行）。
      reg.register(() => Completer<void>().future);
      reg.register(() async {
        healthyRan = true;
      });

      unawaited(reg.releaseAll().then((_) => releaseAllDone = true));

      // 健康来源同步跑完；卡死来源在超时窗口后被放行 → releaseAll 完成。
      async.elapse(
        MediaHandleRegistry.perCallbackTimeout + const Duration(seconds: 1),
      );
      expect(healthyRan, isTrue);
      expect(releaseAllDone, isTrue,
          reason: 'releaseAll 不得被卡死来源无限阻塞（perCallbackTimeout 上限放行）');
    });
  });

  test('a throwing callback does not abort releasing the others', () async {
    final MediaHandleRegistry reg = MediaHandleRegistry.instance;
    bool healthyRan = false;

    reg.register(() async => throw StateError('boom'));
    reg.register(() async {
      healthyRan = true;
    });

    // 不应 rethrow：best-effort，抛异常来源被吞（记日志），其余照常释放。
    await reg.releaseAll();
    expect(healthyRan, isTrue);
    expect(reg.callbackCount, 0);
  });
}
