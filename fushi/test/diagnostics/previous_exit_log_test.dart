// 上次进程退出取证（反馈 WkL9BvD7Z9 / XDV7Mzc2gw / O2eI1Bewe_ 等「Dart 日志无栈」）：
// 各平台摘要的解析、会话标记、Android 假通道，以及最终确实进了反馈上传的日志文本。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/previous_exit_log.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('prev_exit_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发占用，留给系统清理。
    }
  });

  test('路径脱敏：三种用户目录的用户名都换成 <user>', () {
    expect(
      redactExitReportPaths(
        r'C:\Users\alice\AppData\x.dll /Users/bob/a /home/c/d',
      ),
      r'C:\Users\<user>\AppData\x.dll /Users/<user>/a /home/<user>/d',
    );
  });

  group('会话标记', () {
    File markerFile() => File('${tmp.path}/session_marker.json');

    test('首次启动没有上次会话；停在前台没了 → 严重的未正常退出', () {
      final SessionMarker first = SessionMarker(
        markerFile(),
        pid: 11,
        version: '3.0.1',
      );
      expect(first.start(nowMs: 1000), isNull);
      first.recordLifecycle('resumed', nowMs: 2000);
      first.recordMemoryPressure(nowMs: 2500);

      final PreviousSession? prev = SessionMarker(
        markerFile(),
        pid: 12,
        version: '3.0.1',
      ).start(nowMs: 3000);
      final ExitReportEntry? entry = describeUncleanPreviousSession(prev);
      expect(entry, isNotNull);
      expect(entry!.severe, isTrue);
      expect(entry.source, kPreviousExitUncleanSource);
      expect(entry.text, contains('pid=11'));
      expect(entry.text, contains('lastLifecycle=resumed'));
      expect(entry.text, contains('memoryPressure=1x'));
    });

    test('停在后台没了只算诊断；正常退出 / detached 不报', () {
      final SessionMarker a = SessionMarker(markerFile(), pid: 1, version: 'v')
        ..start(nowMs: 1);
      a.recordLifecycle('paused', nowMs: 2);
      final ExitReportEntry? bg = describeUncleanPreviousSession(
        SessionMarker(markerFile(), pid: 2, version: 'v').start(nowMs: 3),
      );
      expect(bg!.severe, isFalse);

      final SessionMarker b = SessionMarker(markerFile(), pid: 3, version: 'v')
        ..start(nowMs: 4);
      b.markCleanExit(nowMs: 5);
      expect(
        describeUncleanPreviousSession(
          SessionMarker(markerFile(), pid: 4, version: 'v').start(nowMs: 6),
        ),
        isNull,
      );

      final SessionMarker c = SessionMarker(markerFile(), pid: 5, version: 'v')
        ..start(nowMs: 7);
      c.recordLifecycle('detached', nowMs: 8);
      expect(
        describeUncleanPreviousSession(
          SessionMarker(markerFile(), pid: 6, version: 'v').start(nowMs: 9),
        ),
        isNull,
      );
    });
  });

  test('Android：退出原因分级、trace 摘要脱敏、trim 级别命名', () {
    final List<ExitReportEntry> entries = formatAndroidExitReports(
      <Object?, Object?>{
        'sdk': 34,
        'reasons': <Object?>[
          <Object?, Object?>{
            'reason': 'CRASH_NATIVE',
            'status': 6,
            'description': 'crash',
            'importance': 100,
            'pssKb': 812000,
            'rssKb': 900000,
            'timestamp': 1761550000000,
            'processName': 'app.fushi.reader',
            'pid': 4242,
            'trace': 'signal 11 (SIGSEGV)\nlibflutter.so\n/home/alice/x',
          },
          <Object?, Object?>{
            'reason': 'USER_REQUESTED',
            'status': 0,
            'timestamp': 1761540000000,
            'processName': 'app.fushi.reader:popup',
            'pid': 4100,
          },
        ],
        'trims': <Object?>[
          <Object?, Object?>{
            'level': 15,
            'timestamp': 1761549990000,
            'pid': 4242,
          },
        ],
      },
    );
    expect(entries, hasLength(3));
    expect(entries[0].severe, isTrue);
    expect(entries[0].text, contains('reason=CRASH_NATIVE'));
    expect(entries[0].text, contains('pss=812000KB'));
    expect(entries[0].text, contains('SIGSEGV'));
    expect(entries[0].text, contains('/home/<user>/x'));
    expect(entries[1].severe, isFalse);
    expect(entries[2].source, kAndroidTrimMemorySource);
    expect(entries[2].text, contains('RUNNING_CRITICAL'));
    expect(entries[2].severe, isTrue);
  });

  test('Android：经真实 MethodChannel 取上次退出原因', () async {
    const MethodChannel channel = MethodChannel('test/process_exit');
    Object? sentArgs;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'consumeExitReports');
          sentArgs = call.arguments;
          return <String, Object?>{
            'sdk': 28,
            'trims': <Object?>[
              <String, Object?>{'level': 80, 'timestamp': 1, 'pid': 9},
            ],
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final List<ExitReportEntry> entries = await PreviousExitLog.collect(
      appDir: tmp,
      version: 'v',
      isAndroid: true,
      isWindows: false,
      isMacOS: false,
      isIOS: false,
      androidChannel: channel,
      nowMs: 100,
    );
    expect((sentArgs! as Map<Object?, Object?>)['lookbackMs'], isA<int>());
    expect(
      entries.map((ExitReportEntry e) => e.source),
      contains(kAndroidTrimMemorySource),
    );
    expect(
      entries
          .firstWhere(
            (ExitReportEntry e) => e.source == kAndroidTrimMemorySource,
          )
          .text,
      contains('COMPLETE'),
    );
  });

  test('Windows：读出崩溃摘要行并清空文件', () async {
    final Directory dumps = Directory('${tmp.path}\\Fushi\\crashdumps')
      ..createSync(recursive: true);
    final File summary = File('${dumps.path}\\crash_summary.log')
      ..writeAsStringSync(
        'time=2026-10-27 10:00:00 code=0xc0000005 at=flutter_windows.dll+0x1a2b '
        r'av=read@0x0 thread=42 frames=flutter_windows.dll+0x1a2b,C:\Users\bob\x.dll+0x10 '
        'dump=hibiki-1-2.dmp\r\n',
      );
    final List<ExitReportEntry> entries = await PreviousExitLog.collect(
      appDir: tmp,
      version: 'v',
      isAndroid: false,
      isWindows: true,
      isMacOS: false,
      isIOS: false,
      localAppData: tmp.path,
    );
    final ExitReportEntry crash = entries.firstWhere(
      (ExitReportEntry e) => e.source == kWindowsCrashSummarySource,
    );
    expect(crash.severe, isTrue);
    expect(crash.text, contains('code=0xc0000005'));
    expect(crash.text, contains('flutter_windows.dll+0x1a2b'));
    expect(crash.text, contains(r'C:\Users\<user>\x.dll'));
    expect(summary.readAsStringSync(), isEmpty);
  });

  group('Windows 关机 / 注销（BUG-3929）', () {
    void writeUncleanMarker({required int pid}) {
      File(
        '${tmp.path}${Platform.pathSeparator}session_marker.json',
      ).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'pid': pid,
          'startedAt': 1000,
          'version': 'v',
          'lifecycle': 'resumed',
          'lifecycleAt': 2000,
          'clean': false,
          'initialised': true,
        }),
      );
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

    File sessionEndLog(String content) {
      final Directory dumps = Directory('${tmp.path}\\Fushi\\crashdumps')
        ..createSync(recursive: true);
      return File('${dumps.path}\\session_end.log')..writeAsStringSync(content);
    }

    test('停在前台时被关机结束：判成关机、不上报，并清空记录', () async {
      writeUncleanMarker(pid: 4242);
      final File log = sessionEndLog(
        '999 1500 shutdown\r\n4242 2600 logoff\r\n',
      );
      final List<ExitReportEntry> entries = await collectWindows();
      final PreviousExitVerdict v = classifyPreviousExit(
        entries,
        version: 'v',
        nowMs: 9000,
      )!;
      expect(v.kind, PreviousExitKind.systemShutdown);
      expect(v.worthReporting, isFalse);
      expect(
        entries
            .firstWhere(
              (ExitReportEntry e) => e.source == kWindowsSessionEndSource,
            )
            .text,
        contains('reason=logoff'),
      );
      expect(log.readAsStringSync(), isEmpty);
    });

    test('记录的 pid 对不上上次会话：照旧判疑似闪退', () async {
      writeUncleanMarker(pid: 4242);
      sessionEndLog('999 1500 shutdown\n');
      final PreviousExitVerdict v = classifyPreviousExit(
        await collectWindows(),
        version: 'v',
        nowMs: 9000,
      )!;
      expect(v.kind, PreviousExitKind.unexpected);
    });

    test('同一次还有原生崩溃摘要：崩溃优先', () async {
      writeUncleanMarker(pid: 4242);
      sessionEndLog('4242 2600 shutdown\n');
      File(
        '${tmp.path}\\Fushi\\crashdumps\\crash_summary.log',
      ).writeAsStringSync('time=x code=0xc0000005\n');
      final PreviousExitVerdict v = classifyPreviousExit(
        await collectWindows(),
        version: 'v',
        nowMs: 9000,
      )!;
      expect(v.kind, PreviousExitKind.nativeCrash);
    });

    test('runner 在 WM_ENDSESSION 时同步记录、不消费消息', () {
      final String window = File(
        'windows/runner/flutter_window.cpp',
      ).readAsStringSync();
      expect(
        RegExp(
          r'message == WM_ENDSESSION && wparam\)\s*\{\s*::fushi::RecordSessionEnd\(lparam\);\s*\}',
        ).hasMatch(window),
        isTrue,
      );
      final String dump = File(
        'windows/runner/crash_dump.cpp',
      ).readAsStringSync();
      expect(dump, contains(r'L"\\session_end.log"'));
      expect(dump, contains('FlushFileBuffers(file);'));
    });
  });

  test('macOS：.ips 摘要（异常、崩溃线程帧）+ 只取本进程、只取新的', () async {
    final Directory reports = Directory('${tmp.path}/DiagnosticReports')
      ..createSync();
    final String header = jsonEncode(<String, Object?>{
      'app_name': 'fushi',
      'app_version': '3.0.1',
      'bug_type': '309',
      'timestamp': '2026-10-27 10:00:00.00 +0800',
    });
    final String body = jsonEncode(<String, Object?>{
      'exception': <String, Object?>{
        'type': 'EXC_BAD_ACCESS',
        'signal': 'SIGSEGV',
        'codes': '0x1, 0x0',
      },
      'termination': <String, Object?>{'namespace': 'SIGNAL', 'code': 11},
      'faultingThread': 0,
      'usedImages': <Object?>[
        <String, Object?>{'name': 'FlutterMacOS'},
        <String, Object?>{'name': 'AppKit'},
      ],
      'threads': <Object?>[
        <String, Object?>{
          'queue': 'com.apple.main-thread',
          'frames': <Object?>[
            <String, Object?>{'imageIndex': 0, 'imageOffset': 4096},
            <String, Object?>{
              'imageIndex': 1,
              'imageOffset': 255,
              'symbol': '-[NSSavePanel runModal]',
            },
          ],
        },
      ],
    });
    File(
      '${reports.path}/fushi-2026-10-27-100000.ips',
    ).writeAsStringSync('$header\n$body');
    File(
      '${reports.path}/Safari-2026-10-27-100000.ips',
    ).writeAsStringSync('$header\n$body');

    Future<List<ExitReportEntry>> run() => PreviousExitLog.collect(
      appDir: tmp,
      version: 'v',
      isAndroid: false,
      isWindows: false,
      isMacOS: true,
      isIOS: false,
      macReportsDir: reports,
      macProcessName: 'fushi',
    );
    final List<ExitReportEntry> first = (await run())
        .where((ExitReportEntry e) => e.source == kMacCrashReportSource)
        .toList();
    expect(first, hasLength(1));
    expect(first.single.text, contains('EXC_BAD_ACCESS'));
    expect(first.single.text, contains('FlutterMacOS+0x1000'));
    expect(first.single.text, contains('AppKit+0xff -[NSSavePanel runModal]'));
    // 第二次启动：同一份报告不再重复折入。
    expect(
      (await run()).where(
        (ExitReportEntry e) => e.source == kMacCrashReportSource,
      ),
      isEmpty,
    );
  });

  test('iOS：MetricKit 崩溃诊断摘要并删除已读文件', () async {
    final Directory mk = Directory('${tmp.path}/metrickit')..createSync();
    final File payload = File('${mk.path}/crash-1-ab.json')
      ..writeAsStringSync(
        jsonEncode(<String, Object?>{
          'diagnosticMetaData': <String, Object?>{
            'appVersion': '3.0.1',
            'appBuildVersion': '1360',
            'osVersion': 'iPhone OS 18.1',
            'exceptionType': 1,
            'exceptionCode': 0,
            'signal': 11,
            'terminationReason': 'Namespace SIGNAL, Code 11',
          },
          'callStackTree': <String, Object?>{
            'callStacks': <Object?>[
              <String, Object?>{
                'threadAttributed': true,
                'callStackRootFrames': <Object?>[
                  <String, Object?>{
                    'binaryName': 'Flutter',
                    'offsetIntoBinaryTextSegment': 1234,
                    'subFrames': <Object?>[
                      <String, Object?>{
                        'binaryName': 'Runner',
                        'offsetIntoBinaryTextSegment': 99,
                      },
                    ],
                  },
                ],
              },
            ],
          },
        }),
      );
    final List<ExitReportEntry> entries = await PreviousExitLog.collect(
      appDir: tmp,
      version: 'v',
      isAndroid: false,
      isWindows: false,
      isMacOS: false,
      isIOS: true,
    );
    final ExitReportEntry crash = entries.firstWhere(
      (ExitReportEntry e) => e.source == kIosCrashDiagnosticSource,
    );
    expect(crash.text, contains('signal=11'));
    expect(crash.text, contains('Flutter+1234'));
    expect(crash.text, contains('Runner+99'));
    expect(payload.existsSync(), isFalse);
  });

  test('折入后的摘要出现在反馈上传的日志文本里', () async {
    await ErrorLogService.instance.init(directoryOverride: tmp);
    await PreviousExitLog.foldIntoErrorLog(
      collector: (Directory appDir) async => <ExitReportEntry>[
        const ExitReportEntry(
          kAndroidExitInfoSource,
          'reason=LOW_MEMORY pss=1KB',
          severe: true,
        ),
        const ExitReportEntry(
          kAndroidTrimMemorySource,
          'onTrimMemory: UI_HIDDEN',
          severe: false,
        ),
      ],
    );
    final String log = collectFeedbackLogText(includeDebugLog: true);
    expect(log, contains(kAndroidExitInfoSource));
    expect(log, contains('reason=LOW_MEMORY'));
    expect(log, contains('onTrimMemory: UI_HIDDEN'));
    await ErrorLogService.instance.flush();
  });
}
