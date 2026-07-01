import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// TODO-1083：报错日志分级契约。两类噪声——更新检查多镜像 failover 的瞬时网络失败、
/// WGC 帧捕获生命周期取证（BUG-209）——不该混进用户可见的「报错日志」，但仍要能随
/// 复制/分享/上传带走（保住 BUG-209 崩前证据，非删除式绕过）。
///
/// 分两层验证：
///  ① 行为：[ErrorLogService.logDiagnostic] 进独立诊断段，不计入 [entries]/错误计数，
///     但进 [getFullLog]；真 [log] 错误仍进 [entries]。
///  ② 源码守卫：WGC 折入 + UpdateChecker 三个预期网络失败分支必须走 logDiagnostic，
///     不再走 log()（防回归重新把噪声刷进报错日志）。
String _read(List<String> candidates, String name) {
  final File? f = candidates
      .map(File.new)
      .cast<File?>()
      .firstWhere((File? f) => f != null && f.existsSync(), orElse: () => null);
  expect(f, isNotNull, reason: '$name not found');
  return f!.readAsStringSync();
}

void main() {
  group('ErrorLogService diagnostic tier (behavior)', () {
    setUp(() async {
      final Directory tmp =
          await Directory.systemTemp.createTemp('errlog_diag_test');
      await ErrorLogService.instance.init(directoryOverride: tmp);
      await ErrorLogService.instance.clear();
    });

    test('logDiagnostic 不计入用户可见 entries / 错误计数', () {
      final ErrorLogService svc = ErrorLogService.instance;
      expect(svc.entries, isEmpty);

      svc.logDiagnostic('WGC.captureLog', 'lifecycle forensic evt=create-pool');
      svc.logDiagnostic(
          'UpdateChecker.httpGet', 'connect timed out ghfast.top');

      expect(svc.entries, isEmpty, reason: '诊断/取证不该出现在用户可见错误列表');
      expect(svc.diagnosticEntries.length, 2);
    });

    test('真 log() 错误仍进 entries；诊断与错误分列', () {
      final ErrorLogService svc = ErrorLogService.instance;
      svc.log('Reader.parse', 'FormatException: bad epub');
      svc.logDiagnostic('WGC.captureLog', 'evt=retire pool=0xABC');

      expect(svc.entries.length, 1, reason: '真错误进 entries；诊断不进');
      expect(svc.entries.single.source, 'Reader.parse');
      expect(svc.diagnosticEntries.length, 1);
    });

    test('getFullLog 仍带上诊断段（供复制/分享/上传）', () {
      final ErrorLogService svc = ErrorLogService.instance;
      svc.logDiagnostic(
          'WGC.captureLog', 'BUG-209 lifecycle: evt=create-bridge');
      final String full = svc.getFullLog();
      expect(full, contains('WGC.captureLog'),
          reason: 'BUG-209 取证必须仍能随日志上传，不做删除式绕过');
      expect(full, contains('evt=create-bridge'));
    });

    test('clear 同时清空诊断段', () async {
      final ErrorLogService svc = ErrorLogService.instance;
      svc.logDiagnostic('UpdateChecker.httpGet', 'timed out');
      svc.log('X', 'boom');
      await svc.clear();
      expect(svc.entries, isEmpty);
      expect(svc.diagnosticEntries, isEmpty);
    });
  });

  group('TODO-1083 source guards (noise routed to logDiagnostic, not log)', () {
    test('WGC 折入错误日志走 logDiagnostic', () {
      final String src = _read(<String>[
        'lib/src/utils/misc/wgc_capture_log.dart',
        'hibiki/lib/src/utils/misc/wgc_capture_log.dart',
      ], 'wgc_capture_log.dart');
      expect(
          RegExp(r"logDiagnostic\(\s*'WGC\.captureLog'").hasMatch(src), isTrue,
          reason: 'WGC 取证必须走 logDiagnostic（诊断段），不刷进用户可见报错日志');
      expect(
          RegExp(r"instance\.log\(\s*'WGC\.captureLog'").hasMatch(src), isFalse,
          reason: 'WGC 取证不得再走 log()（会计入用户可见错误）');
    });

    test('UpdateChecker 预期网络失败三分支走 logDiagnostic', () {
      final String src = _read(<String>[
        'lib/src/utils/misc/update_checker_release.dart',
        'hibiki/lib/src/utils/misc/update_checker_release.dart',
      ], 'update_checker_release.dart');
      // 折叠空白，稳健匹配「方法名(  'label',  t.update_network_failure」跨行调用。
      final String collapsed = src.replaceAll(RegExp(r'\s+'), ' ');
      for (final String label in <String>[
        'UpdateChecker.httpGet',
        'UpdateChecker.redirectTag',
        'UpdateChecker.download',
      ]) {
        expect(
          collapsed
              .contains("logDiagnostic( '$label', t.update_network_failure"),
          isTrue,
          reason: '$label 的预期网络失败分支必须走 logDiagnostic',
        );
        // 预期分支不得再用 log(...) 记 update_network_failure（那会进用户报错日志）。
        expect(
          collapsed
              .contains("instance.log( '$label', t.update_network_failure"),
          isFalse,
          reason: '$label 的预期网络失败不得再走 log()（噪声回归）',
        );
      }
      // never-break：真解析/逻辑错误（else 分支）仍走 log() 记进报错日志。
      expect(src.contains('ErrorLogService.instance.log('), isTrue,
          reason: '真错误分支仍须保留 log()（never break：真错误仍进报错日志）');
    });
  });
}
