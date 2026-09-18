import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/hang_watchdog_log.dart';

/// BUG-2588：主线程停泵看门狗记录的 Dart 侧折入。
///
/// native 端（`fushi/windows/runner/hang_watchdog.cpp`）在主线程连续停泵超过阈值时
/// 抓 `crashdumps\hang-<pid>-<tick>.dmp` 并往同目录 `hang_watchdog.log` 追加一行；
/// [HangWatchdogLog] 下次启动读出折成 `MainThread.hangRecovered`。这里钉三件事：
/// 路径与 native 硬钉一致、读后清的滚动语义、native 源码里看门狗真的接在消息循环
/// 前后（不然 Dart 侧永远读不到东西）。
void main() {
  group('HangWatchdogLog.resolveLogFile', () {
    test('Windows + LOCALAPPDATA → crashdumps 同目录 hang_watchdog.log', () {
      final File? f = HangWatchdogLog.resolveLogFile(
        isWindows: true,
        localAppData: r'C:\Users\u\AppData\Local',
      );
      expect(f, isNotNull);
      expect(
        f!.path,
        r'C:\Users\u\AppData\Local\Fushi\crashdumps\hang_watchdog.log',
        reason: '必须与 crash dump 同目录（诊断区「崩溃转储」页一处打包）、'
            '文件名与 hang_watchdog.cpp 硬钉一致',
      );
    });

    test('非 Windows / LOCALAPPDATA 缺失 → null', () {
      expect(
        HangWatchdogLog.resolveLogFile(
          isWindows: false,
          localAppData: r'C:\x',
        ),
        isNull,
      );
      expect(
        HangWatchdogLog.resolveLogFile(isWindows: true, localAppData: null),
        isNull,
      );
      expect(
        HangWatchdogLog.resolveLogFile(isWindows: true, localAppData: ''),
        isNull,
      );
    });
  });

  group('HangWatchdogLog.readAndClear', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_hang_watchdog_test');
    });
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {
        // Windows 句柄释放时机不可控，留给 OS 回收。
      }
    });

    test('有内容 → 返回内容并清空（滚动语义，下次启动不重复报）', () {
      final File f = File('${tmp.path}/hang_watchdog.log');
      const String line =
          '[2026-09-18 22:43:50] pid=123 main thread unresponsive >=10000 ms; '
          r'hang dump=C:\x\crashdumps\hang-123-1.dmp';
      f.writeAsStringSync('$line\r\n');
      expect(HangWatchdogLog.readAndClear(f), line);
      expect(f.readAsStringSync(), isEmpty);
      expect(HangWatchdogLog.readAndClear(f), isNull);
    });

    test('文件不存在 / 空 → null', () {
      final File missing = File('${tmp.path}/missing.log');
      expect(HangWatchdogLog.readAndClear(missing), isNull);
      final File empty = File('${tmp.path}/empty.log')..writeAsStringSync('  ');
      expect(HangWatchdogLog.readAndClear(empty), isNull);
    });
  });

  group('native 看门狗接线（源码守卫）', () {
    final File main = File('windows/runner/main.cpp');
    final File watchdog = File('windows/runner/hang_watchdog.cpp');
    final File cmake = File('windows/runner/CMakeLists.txt');

    test('main.cpp 在消息循环前启动、循环后停止看门狗', () {
      final String src = main.readAsStringSync();
      final int start = src.indexOf('::fushi::StartHangWatchdog(');
      final int loop = src.indexOf('while (::GetMessage(&msg');
      final int stop = src.indexOf('::fushi::StopHangWatchdog();');
      expect(start, greaterThan(0), reason: '看门狗必须在 main.cpp 启动');
      expect(loop, greaterThan(start), reason: '启动要在消息循环之前');
      expect(stop, greaterThan(loop), reason: '消息循环退出后必须先停看门狗，退出期不泵消息不算卡死');
    });

    test('hang_watchdog.cpp 写 hang-*.dmp 与 hang_watchdog.log 到 crashdumps', () {
      final String src = watchdog.readAsStringSync();
      expect(src, contains('WriteProcessMinidump(L"hang"'),
          reason: 'dump 前缀 hang 与崩溃 dump（hibiki）在同目录区分');
      expect(src, contains(r'L"\\hang_watchdog.log"'),
          reason: '日志文件名必须与 HangWatchdogLog._relativePath 硬钉一致');
      expect(src, contains('IsHungAppWindow('),
          reason: '停泵判据用系统 IsHungAppWindow，不自造跨线程 SendMessage');
      expect(src, contains('IsDebuggerPresent()'), reason: '调试器断点不是卡死，必须跳过');
    });

    test('CMake 已把 hang_watchdog.cpp 编进 runner', () {
      expect(cmake.readAsStringSync(), contains('"hang_watchdog.cpp"'));
    });
  });
}
