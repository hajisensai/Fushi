import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/present_watchdog.dart';

/// BUG-772 Task 4：present-watchdog 覆盖看门狗盲区（raster/present 楔死时 UI-isolate
/// Timer 的逃生 UI 也送不上屏）。纯逻辑单测其「stall 判定只触发一次 + 首帧已出不误触发」
/// 与取证/marker 的读写。
void main() {
  group('PresentWatchdog 触发逻辑', () {
    test('超时后首帧仍未 rasterize → onStall 恰好一次', () {
      void Function()? fired;
      int stalls = 0;
      final PresentWatchdog w = PresentWatchdog(
        timeout: const Duration(seconds: 30),
        isFirstFrameRasterized: () => false,
        onStall: () => stalls++,
        scheduleTimer: (Duration d, void Function() cb) {
          fired = cb;
          return () {};
        },
      );
      w.arm();
      expect(stalls, 0);
      fired!(); // 模拟超时到点
      expect(stalls, 1);
      fired!(); // 再触发不重复（_stallReported 守卫）
      expect(stalls, 1);
    });

    test('超时时首帧已 rasterize → onStall 不触发（不误重启）', () {
      void Function()? fired;
      int stalls = 0;
      final PresentWatchdog w = PresentWatchdog(
        timeout: const Duration(seconds: 30),
        isFirstFrameRasterized: () => true,
        onStall: () => stalls++,
        scheduleTimer: (Duration d, void Function() cb) {
          fired = cb;
          return () {};
        },
      );
      w.arm();
      fired!();
      expect(stalls, 0);
    });

    test('disarm 后超时回调不触发', () {
      void Function()? fired;
      int stalls = 0;
      bool canceled = false;
      final PresentWatchdog w = PresentWatchdog(
        timeout: const Duration(seconds: 30),
        isFirstFrameRasterized: () => false,
        onStall: () => stalls++,
        scheduleTimer: (Duration d, void Function() cb) {
          fired = cb;
          return () => canceled = true;
        },
      );
      w.arm();
      w.disarm();
      expect(canceled, isTrue, reason: 'disarm 应取消已挂定时器');
      fired!(); // 即便回调仍被调，disarm 后也不触发
      expect(stalls, 0);
    });

    test('arm 幂等：已挂不重复 schedule', () {
      int scheduleCount = 0;
      final PresentWatchdog w = PresentWatchdog(
        timeout: const Duration(seconds: 30),
        isFirstFrameRasterized: () => false,
        onStall: () {},
        scheduleTimer: (Duration d, void Function() cb) {
          scheduleCount++;
          return () {};
        },
      );
      w.arm();
      w.arm();
      expect(scheduleCount, 1);
    });
  });

  group('PresentStallLog 取证与 marker', () {
    late Directory tmp;
    setUp(
        () => tmp = Directory.systemTemp.createTempSync('present_stall_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('resolveFile 仅 Windows + 有 LOCALAPPDATA 才返回', () {
      expect(
          PresentStallLog.resolveFile('Hibiki\\x.log',
              isWindows: false, localAppData: 'C:\\x'),
          isNull);
      expect(
          PresentStallLog.resolveFile('Hibiki\\x.log',
              isWindows: true, localAppData: null),
          isNull);
      expect(
          PresentStallLog.resolveFile('Hibiki\\x.log',
              isWindows: true, localAppData: ''),
          isNull);
      final File? f = PresentStallLog.resolveFile('Hibiki\\x.log',
          isWindows: true, localAppData: 'C:\\ad');
      expect(f, isNotNull);
      expect(f!.path, 'C:\\ad\\Hibiki\\x.log');
    });

    test('appendStall 写入一行含时间戳/秒数/BUG 号', () {
      final File f = File('${tmp.path}/present_stall.log');
      PresentStallLog.appendStall(f, DateTime.utc(2026, 7, 13, 1, 2, 3),
          afterTimeout: const Duration(seconds: 30));
      final String content = f.readAsStringSync();
      expect(content, contains('2026-07-13T01:02:03'));
      expect(content, contains('after 30s'));
      expect(content, contains('BUG-772'));
    });

    test('appendStall 追加不覆盖', () {
      final File f = File('${tmp.path}/present_stall.log');
      PresentStallLog.appendStall(f, DateTime.utc(2026, 1, 1),
          afterTimeout: const Duration(seconds: 30));
      PresentStallLog.appendStall(f, DateTime.utc(2026, 1, 2),
          afterTimeout: const Duration(seconds: 30));
      expect(
          f.readAsLinesSync().where((String l) => l.trim().isNotEmpty).length,
          2);
    });

    test('readAndClear 读出并清空', () {
      final File f = File('${tmp.path}/present_stall.log')
        ..writeAsStringSync('line1\n');
      expect(PresentStallLog.readAndClear(f), 'line1');
      expect(PresentStallLog.readAndClear(f), isNull);
    });

    test('claimRestart 首次 true 写 marker，二次 false 防循环', () {
      final File m = File('${tmp.path}/present_stall.marker');
      expect(PresentStallLog.claimRestart(m), isTrue);
      expect(m.existsSync(), isTrue);
      expect(PresentStallLog.claimRestart(m), isFalse);
    });

    test('clearRestartMarker 删除后可再 claim', () {
      final File m = File('${tmp.path}/present_stall.marker');
      PresentStallLog.claimRestart(m);
      PresentStallLog.clearRestartMarker(m);
      expect(m.existsSync(), isFalse);
      expect(PresentStallLog.claimRestart(m), isTrue);
    });
  });
}
