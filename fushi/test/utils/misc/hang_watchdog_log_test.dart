import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_gal_lookup_log.dart';
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
        reason:
            '必须与 crash dump 同目录（诊断区「崩溃转储」页一处打包）、'
            '文件名与 hang_watchdog.cpp 硬钉一致',
      );
    });

    test('非 Windows / LOCALAPPDATA 缺失 → null', () {
      expect(
        HangWatchdogLog.resolveLogFile(isWindows: false, localAppData: r'C:\x'),
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
      expect(
        src,
        contains('WriteProcessMinidump(L"hang"'),
        reason: 'dump 前缀 hang 与崩溃 dump（hibiki）在同目录区分',
      );
      expect(
        src,
        contains(r'L"\\hang_watchdog.log"'),
        reason: '日志文件名必须与 HangWatchdogLog._relativePath 硬钉一致',
      );
      // 反馈 JjjCk58rPZ：IsHungAppWindow 自带 5 s 门槛，13.7 s 的卡顿落在旧的
      // 「5 s + 10 s」门槛下没留下 dump；改为 Post 心跳 + 主窗应答计时。
      expect(
        src,
        isNot(contains('IsHungAppWindow(')),
        reason: 'IsHungAppWindow 量不到 5 s 以内的卡顿，不能再当判据',
      );
      expect(
        src,
        contains('PostMessageW(g_main_window, heartbeat'),
        reason: '心跳用 Post（同一时刻只有一条在途），不用会堆积的 SendMessage',
      );
      expect(
        src,
        contains('QueryUnbiasedInterruptTime('),
        reason: '计时不含系统睡眠，合盖唤醒不误报',
      );
      expect(
        src,
        contains('NativeGlog("main-thread stall: ms='),
        reason: '恢复时把卡顿时长写进 hibiki_glookup.log',
      );
      expect(
        src,
        contains('PruneOldHangDumps()'),
        reason: 'hang dump 数量有上限，不能把磁盘塞满',
      );
      expect(src, contains('IsDebuggerPresent()'), reason: '调试器断点不是卡死，必须跳过');
    });

    test('主窗窗口过程最先应答心跳', () {
      final String src = File(
        'windows/runner/flutter_window.cpp',
      ).readAsStringSync();
      final int handler = src.indexOf('FlutterWindow::MessageHandler(HWND');
      final int ack = src.indexOf(
        '::fushi::HandleHangWatchdogHeartbeat(message, wparam)',
        handler,
      );
      final int firstOther = src.indexOf('if (message == WM_TIMER', handler);
      expect(handler, greaterThan(0));
      expect(ack, greaterThan(handler), reason: '心跳没人应答会被当成卡死');
      expect(ack, lessThan(firstOther), reason: '要在其它分支之前处理');
    });

    test('卡顿行在反馈日志白名单里', () {
      expect(kFeedbackGalLookupLogPrefixes, contains('main-thread stall:'));
      const String raw =
          '2026-11-07T16:16:01  [native] main-thread stall: ms=13687 dumped=1';
      expect(galLookupDiagnosticLines(raw), hasLength(1));
    });

    test('CMake 已把 hang_watchdog.cpp 编进 runner', () {
      expect(cmake.readAsStringSync(), contains('"hang_watchdog.cpp"'));
    });
  });
}
