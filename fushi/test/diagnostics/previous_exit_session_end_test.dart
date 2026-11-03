import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/previous_exit_log.dart';

/// 系统 / 有意发起的终止不再被判成「停在前台时没了，疑似闪退」：
/// - Windows 关机 / 注销 / Restart Manager：runner 在 WM_ENDSESSION 写 session_end.log；
/// - 退出意图已落盘时遗留的活动面包屑不是崩溃证据。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('prev_exit_se_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发占用。
    }
  });

  File markerFile() =>
      File('${tmp.path}${Platform.pathSeparator}session_marker.json');

  /// 写一份「上次停在 inactive、没标 clean」的会话标记，返回其 pid。
  int seedUncleanSession({String? exitReason}) {
    final SessionMarker m = SessionMarker(markerFile(), pid: 4242, version: 'v')
      ..start(nowMs: 1);
    m.recordLifecycle('inactive', nowMs: 2);
    if (exitReason != null) m.recordExitRequested(exitReason);
    return 4242;
  }

  File sessionEndFile() {
    final Directory dumps = Directory('${tmp.path}\\Fushi\\crashdumps')
      ..createSync(recursive: true);
    return File('${dumps.path}\\session_end.log');
  }

  Future<List<ExitReportEntry>> collectWindows() => PreviousExitLog.collect(
    appDir: tmp,
    version: 'v',
    isAndroid: false,
    isWindows: true,
    isMacOS: false,
    isIOS: false,
    localAppData: tmp.path,
  );

  test('同 pid 的 session_end.log → systemSessionEnd 压过「疑似闪退」，不上报', () async {
    final int pid = seedUncleanSession();
    final File f = sessionEndFile()
      ..writeAsStringSync('pid=$pid lparam=0x80000000');

    final List<ExitReportEntry> entries = await collectWindows();
    final PreviousExitVerdict verdict = classifyPreviousExit(
      entries,
      version: 'v',
      nowMs: 10,
    )!;
    expect(verdict.kind, PreviousExitKind.systemSessionEnd);
    expect(verdict.worthReporting, isFalse);
    expect(
      entries
          .firstWhere(
            (ExitReportEntry e) => e.source == kWindowsSessionEndSource,
          )
          .text,
      contains('用户注销'),
    );
    expect(f.readAsStringSync(), isEmpty, reason: '读过即清空');
  });

  test('pid 对不上（更早进程的残留）不压制会话标记判定', () async {
    seedUncleanSession();
    sessionEndFile().writeAsStringSync('pid=1 lparam=0x0');

    final PreviousExitVerdict verdict = classifyPreviousExit(
      await collectWindows(),
      version: 'v',
      nowMs: 10,
    )!;
    expect(verdict.kind, PreviousExitKind.unexpected);
    expect(verdict.worthReporting, isTrue);
  });

  test('真原生崩溃摘要仍压过 session end / 退出被打断，照常上报', () async {
    final int pid = seedUncleanSession(exitReason: 'windowClose');
    sessionEndFile().writeAsStringSync('pid=$pid lparam=0x1');
    File(
      '${tmp.path}\\Fushi\\crashdumps\\crash_summary.log',
    ).writeAsStringSync('time=x code=0xc0000005 at=foo.dll+0x1\r\n');

    final PreviousExitVerdict verdict = classifyPreviousExit(
      await collectWindows(),
      version: 'v',
      nowMs: 10,
    )!;
    expect(verdict.kind, PreviousExitKind.nativeCrash);
    expect(verdict.worthReporting, isTrue);
  });

  test('已发起退出时遗留的 srs_sync 面包屑降为诊断、不再说是崩溃', () async {
    seedUncleanSession(exitReason: 'windowClose');
    File(
      '${tmp.path}${Platform.pathSeparator}activity_srs_sync.breadcrumb',
    ).writeAsStringSync('migrate:copy 450/869');

    final List<ExitReportEntry> entries = await collectWindows();
    final ExitReportEntry crumb = entries.firstWhere(
      (ExitReportEntry e) => e.source == kActivityCrashRecoveredSource,
    );
    expect(crumb.severe, isFalse);
    expect(crumb.text, contains('不是崩溃'));
    final PreviousExitVerdict verdict = classifyPreviousExit(
      entries,
      version: 'v',
      nowMs: 10,
    )!;
    expect(verdict.kind, PreviousExitKind.exitInterrupted);
    expect(verdict.worthReporting, isFalse);
  });

  test('没发起过退出时面包屑仍是严重证据', () async {
    seedUncleanSession();
    File(
      '${tmp.path}${Platform.pathSeparator}activity_srs_sync.breadcrumb',
    ).writeAsStringSync('round');

    final ExitReportEntry crumb = (await collectWindows()).firstWhere(
      (ExitReportEntry e) => e.source == kActivityCrashRecoveredSource,
    );
    expect(crumb.severe, isTrue);
  });
}
