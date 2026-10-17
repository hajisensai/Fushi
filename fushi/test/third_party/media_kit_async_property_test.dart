import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

/// BUG-3507：media_kit 补丁 `getPropertyAsync` / 异步 `setProperty` /
/// `commandWithResult` 的真 libmpv 行为。
///
/// 同步 `getProperty`（`mpv_get_property_string`）在 Flutter UI 线程上排 mpv 内核锁；
/// 内核忙时一轮诊断采样把事件循环堵 0.4–0.6 s，视频纹理新帧排不上合成、画面冻住。
/// 补丁改走 `mpv_*_async`，值随 `MPV_EVENT_*_REPLY` 经事件循环回来。
///
/// 「不在调用线程上读」的判据：返回的 Future 在微任务队列排空后仍未完成——同步实现
/// 在第一个 await 之前就把值算好了，排空微任务必然已完成；异步实现要等下一条事件。
///
/// 需要真实 libmpv：`FUSHI_TEST_LIBMPV` 指向 libmpv-2.dll，或先构建 Windows Debug。
String? _libmpvPath() {
  final String? override = Platform.environment['FUSHI_TEST_LIBMPV'];
  final String path = override ?? 'build/windows/x64/runner/Debug/libmpv-2.dll';
  return File(path).existsSync() ? File(path).absolute.path : null;
}

/// 排空微任务队列（不让出给事件循环的宏任务）。
Future<void> _drainMicrotasks() async {
  for (int i = 0; i < 50; i++) {
    await Future<void>.microtask(() {});
  }
}

void main() {
  final String? libmpv = _libmpvPath();
  final String? skip = libmpv == null
      ? 'Build Windows Debug or set FUSHI_TEST_LIBMPV to libmpv-2.dll'
      : null;

  setUpAll(() {
    if (libmpv != null) MediaKit.ensureInitialized(libmpv: libmpv);
  });

  Future<dynamic> openPlayer() async {
    final Player player = Player();
    final dynamic native = player.platform;
    addTearDown(() async {
      if (native.disposed == false) {
        await player.dispose();
      }
    });
    await native.setProperty('vo', 'null');
    await native.setProperty('ao', 'null');
    return native;
  }

  test(
    'getPropertyAsync answers via the event loop, never synchronously',
    () async {
      final dynamic native = await openPlayer();
      final String sync = await native.getProperty('mpv-version') as String;
      expect(sync, startsWith('mpv'));

      bool done = false;
      final Future<String> pending =
          (native.getPropertyAsync('mpv-version') as Future<String>)
            ..then((_) => done = true);
      await _drainMicrotasks();
      expect(
        done,
        isFalse,
        reason: '同步读会在微任务排空前完成；异步读必须等 GET_PROPERTY_REPLY 事件',
      );
      expect(await pending, sync);
      expect(
        await native.getPropertyAsync('no-such-property-bug-3507'),
        '',
        reason: '与 getProperty 同一约定：读不到返回空串',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'async setProperty keeps order against later reads',
    () async {
      final dynamic native = await openPlayer();
      bool done = false;
      final Future<void> write =
          (native.setProperty('volume', '37') as Future<void>)
            ..then((_) => done = true);
      await _drainMicrotasks();
      expect(done, isFalse, reason: '写也必须走 SET_PROPERTY_REPLY，不同步拿内核锁');
      await write;
      expect(
        double.parse(await native.getPropertyAsync('volume') as String),
        37,
      );
      // 不 await 写、紧接着读：当前 mpv 对同一 client 的异步请求按 FIFO 派发
      // （实现细节，libmpv 契约不保证；生产代码需要顺序时一律先 await）。
      unawaited(native.setProperty('volume', '58') as Future<void>);
      expect(
        double.parse(await native.getPropertyAsync('volume') as String),
        58,
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'commandWithResult returns the libmpv result code',
    () async {
      final dynamic native = await openPlayer();
      expect(
        await native.commandWithResult(<String>['set', 'volume', '21']),
        greaterThanOrEqualTo(0),
      );
      expect(
        double.parse(await native.getPropertyAsync('volume') as String),
        21,
      );
      expect(
        await native.commandWithResult(<String>['no-such-command-bug-3507']),
        lessThan(0),
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'dispose settles requests that are still in flight',
    () async {
      final Player player = Player();
      final dynamic native = player.platform;
      await native.setProperty('vo', 'null');
      final Future<String> read =
          native.getPropertyAsync('mpv-version') as Future<String>;
      final Future<int> command =
          native.commandWithResult(<String>['set', 'volume', '10'])
              as Future<int>;
      await player.dispose();
      // 关键是不挂死：回包已到就是真值，被 dispose 截下就是约定的空值 / 错误码。
      await expectLater(read.timeout(const Duration(seconds: 5)), completes);
      await expectLater(command.timeout(const Duration(seconds: 5)), completes);
      expect(
        await native.commandWithResult(<String>['set', 'volume', '10']),
        lessThan(0),
        reason: '已销毁的播放器不再碰原生句柄',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
