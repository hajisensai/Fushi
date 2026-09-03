import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/helper_process_registry.dart';

/// BUG-1708 第二面：app 为更新主动退出后，它拉起的 ffmpeg 还活着并锁住
/// `<安装目录>\ffmpeg.exe`，Inno 复制到该文件时 `DeleteFile failed; code 5`，
/// 重试三次后**整包回滚**（用户现场日志 2026-08-18 12:12）。
///
/// 关键不只是「发了 kill」，而是**等到进程真的死掉**：Windows 要等内核回收句柄，
/// 只发信号不等待，交接给安装器时文件可能仍不可替换。
void main() {
  group('HelperProcessRegistry', () {
    late HelperProcessRegistry registry;

    setUp(() {
      registry = HelperProcessRegistry();
    });

    /// 一个会一直跑下去的子进程，模拟正在转码的 ffmpeg。
    Future<Process> startLongRunning() {
      if (Platform.isWindows) {
        return registry.start(
          'cmd.exe',
          <String>['/c', 'ping', '-n', '600', '127.0.0.1'],
        );
      }
      return registry.start('sleep', <String>['600']);
    }

    test('登记的进程会被终止并等到真正退出', () async {
      final Process first = await startLongRunning();
      final Process second = await startLongRunning();
      expect(registry.liveCount, 2);

      final int reaped = await registry.terminateAll();

      expect(reaped, 2, reason: '必须等到进程真的退出，只发 kill 不算数');
      // exitCode 已完成才可能被 reap；再 await 一次立即返回。
      await first.exitCode;
      await second.exitCode;
      expect(registry.liveCount, 0);
    });

    test('进程自然退出后自动注销，不会累积僵尸条目', () async {
      final Process process = Platform.isWindows
          ? await registry.start('cmd.exe', <String>['/c', 'exit', '0'])
          : await registry.start('true', const <String>[]);
      await process.exitCode;
      // 注销发生在 exitCode 的 then 回调里，让出一轮事件循环。
      await Future<void>.delayed(Duration.zero);

      expect(registry.liveCount, 0);
    });

    test('没有登记进程时 terminateAll 是空操作', () async {
      expect(await registry.terminateAll(), 0);
    });

    test('重复 terminateAll 不抛错', () async {
      await startLongRunning();
      await registry.terminateAll();

      expect(await registry.terminateAll(), 0);
    });
  });
}
