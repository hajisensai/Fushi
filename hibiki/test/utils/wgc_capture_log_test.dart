import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/wgc_capture_log.dart';

/// BUG-209 / TODO-398：WgcCaptureLog 的纯文件逻辑行为测试（host 可跑——不碰 native
/// WGC，只验「定位 %LOCALAPPDATA%\Hibiki\wgc_capture.log + 读后清滚动语义」）。
void main() {
  group('WgcCaptureLog.resolveLogFile', () {
    test('非 Windows 返回 null（WGC 仅 Windows）', () {
      expect(
        WgcCaptureLog.resolveLogFile(
            isWindows: false, localAppData: r'C:\Users\x\AppData\Local'),
        isNull,
      );
    });

    test('LOCALAPPDATA 缺失返回 null', () {
      expect(WgcCaptureLog.resolveLogFile(isWindows: true, localAppData: null),
          isNull);
      expect(WgcCaptureLog.resolveLogFile(isWindows: true, localAppData: ''),
          isNull);
    });

    test('Windows 下拼出 Hibiki/wgc_capture.log（与 native 同一确定路径）', () {
      final File? f = WgcCaptureLog.resolveLogFile(
          isWindows: true, localAppData: r'C:\Users\x\AppData\Local');
      expect(f, isNotNull);
      expect(f!.path, r'C:\Users\x\AppData\Local\Hibiki\wgc_capture.log');
    });
  });

  group('WgcCaptureLog.readAndClear', () {
    late Directory tempDir;
    late File logFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('wgc_log_test');
      logFile = File('${tempDir.path}/wgc_capture.log');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('不存在返回 null', () {
      expect(WgcCaptureLog.readAndClear(logFile), isNull);
    });

    test('空文件返回 null', () {
      logFile.writeAsStringSync('   \n  ');
      expect(WgcCaptureLog.readAndClear(logFile), isNull);
    });

    test('非空：返回内容并清空文件（读后清滚动语义）', () {
      const String body =
          '2026-06-15T10:00:00.000Z tid=1 evt=create-pool pool=0x123\n'
          '2026-06-15T10:00:01.000Z tid=1 evt=retire pool=0x123';
      logFile.writeAsStringSync(body);

      final String? read = WgcCaptureLog.readAndClear(logFile);
      expect(read, body);
      // 读后清：文件仍存在但内容为空，下次启动不重复折入。
      expect(logFile.existsSync(), isTrue);
      expect(logFile.readAsStringSync().trim(), isEmpty);
      // 再读一次应为 null（已清）。
      expect(WgcCaptureLog.readAndClear(logFile), isNull);
    });
  });
}
