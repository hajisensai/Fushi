// 互联下载保活门面的契约测试。
//
// 盯四件事：
//   1. update / stop 的方法名与参数形状（跨语言契约，原生侧按名取参）；
//   2. 与上一次发出状态相同的 update 不过通道；
//   3. 保活中的进度更新按 500ms 节流，且被挡下的最新状态会在间隔满后补发
//      （否则最后一条「100%」可能永远停在 99%）；
//   4. 启动 / 停止不受节流约束；stop 取消待补发；通道异常被吞掉。
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = FushiChannels.downloadKeepAlive;

  group('DownloadKeepAliveState.normalized', () {
    test('null / 越界一律不确定进度', () {
      for (final int? p in <int?>[null, -5, 101, 1000]) {
        expect(
          DownloadKeepAliveState.normalized(title: 't', text: 'x', percent: p)
              .percent,
          kDownloadKeepAliveIndeterminate,
        );
      }
      expect(
        DownloadKeepAliveState.normalized(title: 't', text: 'x', percent: 42)
            .percent,
        42,
      );
    });
  });

  group('DownloadKeepAliveThrottle', () {
    late DateTime now;
    late DownloadKeepAliveThrottle throttle;
    const DownloadKeepAliveState a =
        DownloadKeepAliveState(title: 'A', text: 'a', percent: 1);
    const DownloadKeepAliveState b =
        DownloadKeepAliveState(title: 'A', text: 'a', percent: 2);

    setUp(() {
      now = DateTime(2026, 9, 26);
      throttle = DownloadKeepAliveThrottle(now: () => now);
    });

    test('未保活时立即发', () {
      expect(throttle.isActive, isFalse);
      expect(throttle.onUpdate(a).action, DownloadKeepAliveAction.send);
    });

    test('同状态跳过；间隔内延后；间隔满后发', () {
      throttle.markSent(a);
      expect(throttle.onUpdate(a).action, DownloadKeepAliveAction.skip);

      now = now.add(const Duration(milliseconds: 200));
      expect(
        throttle.onUpdate(b),
        const DownloadKeepAliveDecision(
          DownloadKeepAliveAction.defer,
          Duration(milliseconds: 300),
        ),
      );

      now = now.add(const Duration(milliseconds: 300));
      expect(throttle.onUpdate(b).action, DownloadKeepAliveAction.send);
    });

    test('onStop 只在保活中返回 true，之后重新启动不受节流', () {
      expect(throttle.onStop(), isFalse);
      throttle.markSent(a);
      expect(throttle.onStop(), isTrue);
      expect(throttle.isActive, isFalse);
      expect(throttle.onUpdate(b).action, DownloadKeepAliveAction.send);
    });
  });

  group('AndroidDownloadKeepAlive 通道契约', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('update 参数形状；stop 发出；未保活时 stop 不发', () async {
      final AndroidDownloadKeepAlive keepAlive = AndroidDownloadKeepAlive();
      await keepAlive.stop();
      expect(calls, isEmpty);

      await keepAlive.update(title: '下载中', text: 'ep01.mkv', percent: 37);
      await keepAlive.stop();
      expect(calls.map((MethodCall c) => c.method), <String>['update', 'stop']);
      expect(calls.first.arguments, <String, Object?>{
        'title': '下载中',
        'text': 'ep01.mkv',
        'progress': 37,
      });
    });

    test('null 进度以 -1 发出', () async {
      final AndroidDownloadKeepAlive keepAlive = AndroidDownloadKeepAlive();
      await keepAlive.update(title: 't', text: 'x');
      expect((calls.single.arguments as Map<Object?, Object?>)['progress'], -1);
    });

    test('同状态去重、节流并补发最新状态、stop 取消补发', () {
      fakeAsync((FakeAsync async) {
        final DateTime start = DateTime(2026, 9, 26);
        final AndroidDownloadKeepAlive keepAlive = AndroidDownloadKeepAlive(
          now: () => start.add(async.elapsed),
        );

        keepAlive.update(title: 't', text: 'x', percent: 1);
        async.flushMicrotasks();
        keepAlive.update(title: 't', text: 'x', percent: 1);
        async.flushMicrotasks();
        expect(calls, hasLength(1), reason: '同状态不重发');

        // 间隔内的连续更新只在 500ms 满时补发最后一条。
        async.elapse(const Duration(milliseconds: 100));
        keepAlive.update(title: 't', text: 'x', percent: 2);
        keepAlive.update(title: 't', text: 'x', percent: 3);
        async.elapse(const Duration(milliseconds: 100));
        keepAlive.update(title: 't', text: 'x', percent: 4);
        async.flushMicrotasks();
        expect(calls, hasLength(1));

        async.elapse(const Duration(milliseconds: 300));
        expect(calls, hasLength(2));
        expect(
          (calls.last.arguments as Map<Object?, Object?>)['progress'],
          4,
        );

        // 被挡下后又回到已发状态：待补发作废。
        keepAlive.update(title: 't', text: 'x', percent: 5);
        keepAlive.update(title: 't', text: 'x', percent: 4);
        async.elapse(const Duration(seconds: 1));
        expect(calls, hasLength(2));

        // 间隔已满：立即发；紧跟的一条被挡下，stop 不受节流并取消它。
        keepAlive.update(title: 't', text: 'x', percent: 6);
        keepAlive.update(title: 't', text: 'x', percent: 7);
        keepAlive.stop();
        async.elapse(const Duration(seconds: 1));
        expect(
          calls.map((MethodCall c) => c.method),
          <String>['update', 'update', 'update', 'stop'],
        );
        expect(
          (calls[2].arguments as Map<Object?, Object?>)['progress'],
          6,
        );

        // stop 之后重新启动立即发（启动不受节流）。
        keepAlive.update(title: 't', text: 'x', percent: 7);
        async.flushMicrotasks();
        expect(calls, hasLength(5));
        expect(calls.last.method, 'update');
      });
    });

    test('通道未注册 / 原生抛错不向外传播', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final AndroidDownloadKeepAlive missing = AndroidDownloadKeepAlive();
      await missing.update(title: 't', text: 'x', percent: 1);
      await missing.stop();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        throw PlatformException(code: 'boom');
      });
      final AndroidDownloadKeepAlive failing = AndroidDownloadKeepAlive();
      await failing.update(title: 't', text: 'x', percent: 1);
      await failing.stop();
      expect(calls.map((MethodCall c) => c.method), <String>['update', 'stop']);
    });
  });

  test('NoopDownloadKeepAlive 不发任何通道调用', () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return null;
    });
    const DownloadKeepAlive noop = NoopDownloadKeepAlive();
    await noop.update(title: 't', text: 'x', percent: 1);
    await noop.stop();
    expect(calls, isEmpty);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
