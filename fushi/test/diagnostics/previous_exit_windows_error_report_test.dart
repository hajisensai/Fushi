import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/previous_exit_log.dart';

/// BUG-4076：Windows 上 `__fastfail` / 堆损坏 / 栈溢出 / 卡死被结束都不经
/// `SetUnhandledExceptionFilter`，`crash_summary.log` 为空，报告只剩「停在前台时没了」。
/// 下次启动按 pid 从事件日志读 Windows 错误报告补上原生证据。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 形状取自真机 `wevtutil qe Application /f:xml` 输出（路径已换成占位）。
  String crashEvent({required String pidHex, String code = 'c0000409'}) =>
      "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'>"
      "<System><Provider Name='Application Error' "
      "Guid='{a0e9b465-b939-57d7-b27d-95d8e925ff57}'/><EventID>1000</EventID>"
      "<Level>2</Level><TimeCreated SystemTime='2026-11-06T04:17:25.3765898Z'/>"
      '<Channel>Application</Channel></System><EventData>'
      "<Data Name='AppName'>fushi.exe</Data>"
      "<Data Name='AppVersion'>3.3.0.23880</Data>"
      "<Data Name='ModuleName'>flutter_windows.dll</Data>"
      "<Data Name='ModuleVersion'>0.0.0.0</Data>"
      "<Data Name='ModuleTimeStamp'>6abc6734</Data>"
      "<Data Name='ExceptionCode'>$code</Data>"
      "<Data Name='FaultingOffset'>0000000000fbb981</Data>"
      "<Data Name='ProcessId'>$pidHex</Data>"
      r"<Data Name='AppPath'>C:\Users\alice\AppData\Local\Fushi\fushi.exe</Data>"
      "<Data Name='PackageFullName'></Data>"
      '</EventData></Event>';

  String hangEvent({required String pidHex}) =>
      "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'>"
      "<System><Provider Name='Application Hang'/><EventID>1002</EventID>"
      "<TimeCreated SystemTime='2026-11-06T04:20:00.0000000Z'/></System>"
      "<EventData><Data Name='AppName'>fushi.exe</Data>"
      "<Data Name='AppVersion'>3.3.0.23880</Data>"
      "<Data Name='ProcessId'>$pidHex</Data>"
      "<Data Name='HangType'>Cross-process</Data></EventData></Event>";

  test('解析 wevtutil XML：EventID、时间、具名 Data、十六进制 pid、空 Data', () {
    final List<WindowsErrorEvent> events = parseWindowsErrorEvents(
      '${crashEvent(pidHex: '0x1092')}\r\n${hangEvent(pidHex: '0x1A2B')}',
    );
    expect(events, hasLength(2));
    expect(events[0].eventId, 1000);
    expect(events[0].timeCreated, '2026-11-06T04:17:25.3765898Z');
    expect(events[0].data['ExceptionCode'], 'c0000409');
    expect(events[0].data['PackageFullName'], '');
    expect(events[0].processId, 0x1092);
    expect(events[1].eventId, 1002);
    expect(events[1].processId, 0x1a2b);
  });

  test('XPath 限定 1000 / 1002、本 exe、上次启动以来的时间窗', () {
    final String q = windowsErrorReportXPath(
      exeName: 'fushi.exe',
      sinceMs: 1000,
      nowMs: 1000 + 3600 * 1000,
    );
    expect(q, contains('EventID=1000 or EventID=1002'));
    expect(q, contains("Data='fushi.exe'"));
    expect(q, contains('timediff(@SystemTime) <= ${3600 * 1000 + 60 * 1000}'));
  });

  group('collect（Windows）', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('prev_exit_wer_'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 上偶发占用。
      }
    });

    const int deadPid = 4242;

    void seedUncleanSession({bool clean = false}) {
      final SessionMarker m = SessionMarker(
        File('${tmp.path}${Platform.pathSeparator}session_marker.json'),
        pid: deadPid,
        version: 'v',
      )..start(nowMs: 1);
      m.recordLifecycle('resumed', nowMs: 2);
      if (clean) m.markCleanExit(nowMs: 3);
    }

    Future<List<ExitReportEntry>> collectWith(
      String? xml,
      List<String> asked,
    ) => PreviousExitLog.collect(
      appDir: tmp,
      version: 'v',
      isAndroid: false,
      isWindows: true,
      isMacOS: false,
      isIOS: false,
      localAppData: tmp.path,
      windowsExeName: 'fushi.exe',
      windowsEventQuery: (String xpath) async {
        asked.add(xpath);
        return xml;
      },
      nowMs: 10,
    );

    test(
      '同 pid 的 Application Error 1000 → nativeCrash，带异常码 / 模块+偏移，路径脱敏',
      () async {
        seedUncleanSession();
        final List<String> asked = <String>[];
        final List<ExitReportEntry> entries = await collectWith(
          crashEvent(pidHex: '0x${deadPid.toRadixString(16)}'),
          asked,
        );
        expect(asked, hasLength(1));
        final ExitReportEntry wer = entries.firstWhere(
          (ExitReportEntry e) => e.source == kWindowsErrorReportSource,
        );
        expect(wer.kind, PreviousExitKind.nativeCrash);
        expect(wer.severe, isTrue);
        expect(wer.text, contains('exception=0xc0000409'));
        expect(wer.text, contains('__fastfail'));
        expect(wer.text, contains('flutter_windows.dll+0x0000000000fbb981'));
        expect(wer.text, isNot(contains('alice')));

        final PreviousExitVerdict verdict = classifyPreviousExit(
          entries,
          version: 'v',
          nowMs: 10,
        )!;
        expect(verdict.kind, PreviousExitKind.nativeCrash, reason: '压过「疑似闪退」');
        expect(verdict.worthReporting, isTrue);
      },
    );

    test('Application Hang 1002 → anr（卡死后被结束）', () async {
      seedUncleanSession();
      final List<ExitReportEntry> entries = await collectWith(
        hangEvent(pidHex: '0x${deadPid.toRadixString(16)}'),
        <String>[],
      );
      final PreviousExitVerdict verdict = classifyPreviousExit(
        entries,
        version: 'v',
        nowMs: 10,
      )!;
      expect(verdict.kind, PreviousExitKind.anr);
      expect(
        entries
            .firstWhere(
              (ExitReportEntry e) => e.source == kWindowsErrorReportSource,
            )
            .text,
        contains('hangType=Cross-process'),
      );
    });

    test('pid 对不上（别的 fushi 进程）不算证据，仍判「疑似闪退」', () async {
      seedUncleanSession();
      final List<ExitReportEntry> entries = await collectWith(
        crashEvent(pidHex: '0x1'),
        <String>[],
      );
      expect(
        entries.where(
          (ExitReportEntry e) => e.source == kWindowsErrorReportSource,
        ),
        isEmpty,
      );
      expect(
        classifyPreviousExit(entries, version: 'v', nowMs: 10)!.kind,
        PreviousExitKind.unexpected,
      );
    });

    test('上次正常退出不查事件日志', () async {
      seedUncleanSession(clean: true);
      final List<String> asked = <String>[];
      await collectWith(crashEvent(pidHex: '0x1092'), asked);
      expect(asked, isEmpty);
    });
  });
}
