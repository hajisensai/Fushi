import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/code_integrity_log.dart';

/// BUG-5484：智能应用控制 / WDAC 拦截记录的自动取证。
///
/// native 端（`fushi/windows/runner/code_integrity_probe.cpp`）自己读 CodeIntegrity 事件日志、
/// 把指向 Fushi 文件的拦截记录写进 `crashdumps\code_integrity.log`；[CodeIntegrityLog] 下次启动
/// 折进错误日志随反馈上传——用户不用自己翻事件查看器。这里钉：路径与 native 一致、读后清、
/// 以及两端的接线（native 两个触发点、链接 wevtapi、纯函数测试闸、Dart 启动折入）都在。
void main() {
  group('CodeIntegrityLog.resolveLogFile', () {
    test('Windows + LOCALAPPDATA → crashdumps 同目录 code_integrity.log', () {
      final File? f = CodeIntegrityLog.resolveLogFile(
        isWindows: true,
        localAppData: r'C:\Users\u\AppData\Local',
      );
      expect(
        f?.path,
        r'C:\Users\u\AppData\Local\Fushi\crashdumps\code_integrity.log',
      );
    });

    test('非 Windows / LOCALAPPDATA 缺失 → null', () {
      expect(
        CodeIntegrityLog.resolveLogFile(
          isWindows: false,
          localAppData: r'C:\x',
        ),
        isNull,
      );
      expect(
        CodeIntegrityLog.resolveLogFile(isWindows: true, localAppData: null),
        isNull,
      );
      expect(
        CodeIntegrityLog.resolveLogFile(isWindows: true, localAppData: ''),
        isNull,
      );
    });
  });

  group('CodeIntegrityLog.readAndClear', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_code_integrity_test');
    });
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('有内容 → 返回内容并清空', () {
      final File f = File('${tmp.path}/code_integrity.log')
        ..writeAsStringSync(
          '[2026-11-26 18:04:12] pid=1 code-integrity (startup stall): '
          'smart app control=on (enforcing); 1 new blocked load(s)\r\n',
        );
      expect(
        CodeIntegrityLog.readAndClear(f),
        contains('smart app control=on (enforcing)'),
      );
      expect(f.readAsStringSync(), isEmpty);
    });

    test('不存在 / 只有空白 → null', () {
      expect(
        CodeIntegrityLog.readAndClear(File('${tmp.path}/missing.log')),
        isNull,
      );
      final File blank = File('${tmp.path}/blank.log')
        ..writeAsStringSync(' \n');
      expect(CodeIntegrityLog.readAndClear(blank), isNull);
    });
  });

  test('native 与 Dart 两端接线都在', () {
    final String probe = File(
      'windows/runner/code_integrity_probe.cpp',
    ).readAsStringSync();
    final String watchdog = File(
      'windows/runner/hang_watchdog.cpp',
    ).readAsStringSync();
    final String cmake = File(
      'windows/runner/CMakeLists.txt',
    ).readAsStringSync();
    final String mainDart = File('lib/main.dart').readAsStringSync();

    expect(
      probe,
      contains(r'\\code_integrity.log'),
      reason: '文件名必须与 CodeIntegrityLog._relativePath 一致',
    );
    expect(
      probe,
      contains('Microsoft-Windows-CodeIntegrity/Operational'),
      reason: '查的是代码完整性事件通道',
    );
    expect(
      watchdog,
      contains('StartCodeIntegrityProbe(true)'),
      reason: '启动期限到点、强制显窗时查一次',
    );
    expect(
      watchdog,
      contains('StartCodeIntegrityProbe(false)'),
      reason: '每次启动 60 s 后查一次',
    );
    expect(cmake, contains('"code_integrity_probe.cpp"'));
    expect(cmake, contains('PRIVATE wevtapi'));
    expect(
      cmake,
      contains(
        'add_dependencies(\${BINARY_NAME} fushi_windows_code_integrity_report_gate)',
      ),
      reason: '纯函数测试随每次 runner 构建执行',
    );
    expect(mainDart, contains('CodeIntegrityLog.foldIntoErrorLog()'));
  });
}
