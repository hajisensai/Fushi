// 上次进程退出取证（反馈 WkL9BvD7Z9 / XDV7Mzc2gw / O2eI1Bewe_ 等「Dart 日志无栈」）：
// 各平台摘要的解析、会话标记、Android 假通道，以及最终确实进了反馈上传的日志文本。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/previous_exit_log.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart';
import 'package:fushi/src/startup/headless_launch_gate.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_launch_presence/fushi_launch_presence.dart';

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

  // 崩溃分诊 e1_jaKAeiF：realme 后台管理 `o-stop(40)` 在 app 进入后台的瞬间杀进程
  // （ApplicationExitInfo importance=400），会话标记还停在 `inactive`，旧判定只看标记 →
  // 「停在前台时没了，疑似闪退」→ 弹闪退报告。同一 pid 的平台记录必须压过标记推断。
  group('Android：同一 pid 的死时重要性压过会话标记的前后台推断', () {
    const MethodChannel channel = MethodChannel('test/process_exit_importance');

    Future<PreviousExitVerdict?> verdictFor({
      required String lifecycle,
      required List<Map<String, Object?>> reasons,
    }) async {
      File('${tmp.path}/session_marker.json').writeAsStringSync(
        jsonEncode(<String, Object?>{
          'pid': 19104,
          'startedAt': 1000,
          'version': '3.3.0-debug.23025',
          'lifecycle': lifecycle,
          'lifecycleAt': 4000,
          'clean': false,
          'initialised': true,
        }),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (MethodCall call) async => <String, Object?>{
              'sdk': 34,
              'reasons': reasons,
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final List<ExitReportEntry> entries = await PreviousExitLog.collect(
        appDir: tmp,
        version: '3.3.0-debug.23025',
        isAndroid: true,
        isWindows: false,
        isMacOS: false,
        isIOS: false,
        androidChannel: channel,
        nowMs: 9000,
      );
      return classifyPreviousExit(
        entries,
        version: '3.3.0-debug.23025',
        nowMs: 9000,
      );
    }

    Map<String, Object?> record({
      required int pid,
      required int importance,
      int timestamp = 5000,
      String reason = 'OTHER',
    }) => <String, Object?>{
      'reason': reason,
      'status': 0,
      'description': '[UNKNOWN] stop app.fushi.reader due to o-stop(40)',
      'importance': importance,
      'pssKb': 0,
      'rssKb': 1194136,
      'timestamp': timestamp,
      'processName': 'app.fushi.reader',
      'pid': pid,
    };

    test('importance=400（后台）→ 按后台回收，不弹闪退报告', () async {
      final PreviousExitVerdict? v = await verdictFor(
        lifecycle: 'inactive',
        reasons: <Map<String, Object?>>[record(pid: 19104, importance: 400)],
      );
      expect(v, isNotNull);
      expect(v!.kind, PreviousExitKind.backgroundReclaim);
      expect(v.worthReporting, isFalse);
      expect(v.summary, contains('androidImportanceAtDeath=400'));
    });

    test('importance=100（前台）→ 仍是疑似闪退', () async {
      final PreviousExitVerdict? v = await verdictFor(
        lifecycle: 'inactive',
        reasons: <Map<String, Object?>>[record(pid: 19104, importance: 100)],
      );
      expect(v!.kind, PreviousExitKind.unexpected);
      expect(v.worthReporting, isTrue);
    });

    test('别的 pid / 早于本会话启动的同号记录不算数，回落到标记推断', () async {
      final PreviousExitVerdict? v = await verdictFor(
        lifecycle: 'launching',
        reasons: <Map<String, Object?>>[
          record(pid: 777, importance: 400),
          record(pid: 19104, importance: 400, timestamp: 500),
        ],
      );
      expect(v!.kind, PreviousExitKind.unexpected);
      expect(v.worthReporting, isTrue);
    });

    test('后台时原生崩溃照样上报（平台崩溃原因优先）', () async {
      final PreviousExitVerdict? v = await verdictFor(
        lifecycle: 'inactive',
        reasons: <Map<String, Object?>>[
          record(pid: 19104, importance: 400, reason: 'CRASH_NATIVE'),
        ],
      );
      expect(v!.kind, PreviousExitKind.nativeCrash);
      expect(v.worthReporting, isTrue);
    });
  });

  // BUG-4072：无界面拉起的引擎（Android audio_service 被系统媒体续播 / 媒体键拉起、
  // iOS 后台拉起）跑完整 main()，却收不到任何前台生命周期。标记若停在 `launching`
  // （算前台），进程之后在后台被回收就成了「启动即闪退」（0B-NDKFxfS / SGge0zu1FY /
  // ajMNnjGlhY / bZbeHh8l36 / RgaeV2JF62 / d3SS3FJIOH / vHHHx7AvCY）。原生如实回答
  // 「这次有没有界面」，标记记 headless，判定不算前台。
  group('无界面启动：会话标记记 headless，不算前台闪退（BUG-4072）', () {
    const MethodChannel launch = MethodChannel('test/launch_presence');
    const MethodChannel exits = MethodChannel('test/process_exit_headless');

    void answerLaunch({required bool hasUi}) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(launch, (MethodCall call) async {
            expect(call.method, kLaunchPresenceQueryMethod);
            return <String, Object?>{
              kLaunchPresenceHasUiKey: hasUi,
              kLaunchPresenceDetailKey: hasUi
                  ? 'activity=MainActivity importance=100'
                  : 'activity=none importance=125',
            };
          });
    }

    /// Android 退出记录通道：null = 这个引擎上没注册（无界面引擎的真实情况）。
    void answerExits(List<Map<String, Object?>>? reasons) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            exits,
            reasons == null
                ? null
                : (MethodCall call) async => <String, Object?>{
                    'sdk': 34,
                    'reasons': reasons,
                  },
          );
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(launch, null)
        ..setMockMethodCallHandler(exits, null);
    });

    Future<List<ExitReportEntry>> launchProcess({
      required int nowMs,
      bool android = true,
    }) => PreviousExitLog.collect(
      appDir: tmp,
      version: '3.3.0-debug.23025',
      isAndroid: android,
      isWindows: false,
      isMacOS: false,
      isIOS: !android,
      androidChannel: exits,
      launchChannel: launch,
      nowMs: nowMs,
    );

    PreviousSession readMarker() => PreviousSession.tryParse(
      File('${tmp.path}/session_marker.json').readAsStringSync(),
    )!;

    test('标记状态机：hasUi=false 记 headless；不知道 / 有界面记 launching', () {
      final File f = File('${tmp.path}/session_marker.json');
      SessionMarker(f, pid: 1, version: 'v').start(
        nowMs: 1,
        launch: const LaunchPresence(hasUi: false, detail: 'activity=none'),
      );
      expect(readMarker().lifecycle, kSessionLifecycleHeadless);
      expect(readMarker().launchDetail, 'activity=none');
      expect(readMarker().diedInForeground, isFalse);

      SessionMarker(f, pid: 2, version: 'v').start(nowMs: 2);
      expect(readMarker().lifecycle, 'launching');
      expect(readMarker().diedInForeground, isTrue);

      SessionMarker(
        f,
        pid: 3,
        version: 'v',
      ).start(nowMs: 3, launch: const LaunchPresence(hasUi: true, detail: ''));
      expect(readMarker().lifecycle, 'launching');
      expect(readMarker().launchDetail, isNull);
    });

    test('Android 无界面会话没退出记录、后台没了 → 后台回收，不弹闪退报告', () async {
      answerLaunch(hasUi: false);
      answerExits(null);
      await launchProcess(nowMs: 1000);
      expect(readMarker().lifecycle, kSessionLifecycleHeadless);

      // 下一次进程（用户点开 app，有界面）判定上一个无界面会话。
      answerLaunch(hasUi: true);
      final PreviousExitVerdict? v = classifyPreviousExit(
        await launchProcess(nowMs: 9000),
        version: '3.3.0-debug.23025',
        nowMs: 9000,
      );
      expect(v, isNotNull);
      expect(v!.kind, PreviousExitKind.backgroundReclaim);
      expect(v.foreground, isFalse);
      expect(v.worthReporting, isFalse);
      expect(v.duringStartup, isTrue, reason: '无界面会话从没走到首页，事实照记');
      expect(v.summary, contains('lastLifecycle=headless'));
      expect(v.summary, contains('launch={activity=none importance=125}'));
      expect(v.summary, contains('无界面启动、从没上过屏时没了'));
      expect(readMarker().lifecycle, 'launching');
    });

    test('无界面启动后界面接上来（收到 resumed）→ 升级为前台，照常判疑似闪退', () async {
      answerExits(null);
      final SessionMarker marker =
          SessionMarker(
            File('${tmp.path}/session_marker.json'),
            pid: 4242,
            version: '3.3.0-debug.23025',
          )..start(
            nowMs: 1000,
            launch: const LaunchPresence(hasUi: false, detail: 'activity=none'),
          );
      expect(readMarker().lifecycle, kSessionLifecycleHeadless);
      // audio_service 的缓存引擎被 MainActivity 接管：生命周期开始到达。
      marker.recordLifecycle('resumed', nowMs: 2000);
      expect(readMarker().lifecycle, 'resumed');
      marker.recordInitialised();

      answerLaunch(hasUi: true);
      final PreviousExitVerdict? v = classifyPreviousExit(
        await launchProcess(nowMs: 9000),
        version: '3.3.0-debug.23025',
        nowMs: 9000,
      );
      expect(v!.kind, PreviousExitKind.unexpected);
      expect(v.worthReporting, isTrue);
    });

    test('UeCVNnw7Jx：无界面会话本身降级，但同机前台服务期间的真实 LMK kill 照样上报', () async {
      File('${tmp.path}/session_marker.json').writeAsStringSync(
        jsonEncode(<String, Object?>{
          'pid': 31262,
          'startedAt': 1000,
          'version': '3.3.0-debug.23025',
          'lifecycle': kSessionLifecycleHeadless,
          'lifecycleAt': 1000,
          'clean': false,
          'initialised': false,
        }),
      );
      answerLaunch(hasUi: true);
      answerExits(<Map<String, Object?>>[
        <String, Object?>{
          'reason': 'LOW_MEMORY',
          'status': 0,
          'importance': 400,
          'timestamp': 5000,
          'processName': 'app.fushi.reader',
          'pid': 31262,
        },
        <String, Object?>{
          'reason': 'LOW_MEMORY',
          'status': 0,
          'importance': 125,
          'timestamp': 6000,
          'processName': 'app.fushi.reader',
          'pid': 26422,
        },
      ]);
      final PreviousExitVerdict? v = classifyPreviousExit(
        await launchProcess(nowMs: 9000),
        version: '3.3.0-debug.23025',
        nowMs: 9000,
      );
      expect(v!.kind, PreviousExitKind.memoryKill);
      expect(v.foreground, isTrue, reason: 'pid 26422 importance=125 是前台服务');
      expect(v.worthReporting, isTrue);
    });

    test('iOS 后台拉起同样记 headless，后台没了不算闪退', () async {
      answerLaunch(hasUi: false);
      await launchProcess(nowMs: 1000, android: false);
      expect(readMarker().lifecycle, kSessionLifecycleHeadless);

      answerLaunch(hasUi: true);
      final PreviousExitVerdict? v = classifyPreviousExit(
        await launchProcess(nowMs: 9000, android: false),
        version: '3.3.0-debug.23025',
        nowMs: 9000,
      );
      expect(v!.kind, PreviousExitKind.backgroundReclaim);
      expect(v.worthReporting, isFalse);
    });

    test('桌面不问原生（没有无界面启动），通道不存在时按旧逻辑记 launching', () async {
      int asked = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(launch, (MethodCall call) async {
            asked++;
            return <String, Object?>{kLaunchPresenceHasUiKey: false};
          });
      await PreviousExitLog.collect(
        appDir: tmp,
        version: 'v',
        isAndroid: false,
        isWindows: false,
        isMacOS: false,
        isIOS: false,
        launchChannel: launch,
        nowMs: 1,
      );
      expect(asked, 0);
      expect(readMarker().lifecycle, 'launching');

      // 移动端但这个引擎上没注册通道（MissingPluginException）→ 不知道 → launching。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(launch, null);
      answerExits(null);
      await launchProcess(nowMs: 2);
      expect(readMarker().lifecycle, 'launching');
    });

    // 方案 C：无界面引擎停在精简入口（lib/src/startup/headless_launch_gate.dart），会话标记
    // 要等界面接上来才 start。上一个有界面会话的标记在这期间原样保留，交给真正有界面的那次
    // 启动判定——不会被无界面引擎消费掉、也不会被它的 `headless` 初值覆写。
    test('方案 C：精简入口等界面期间不读不写上一个会话的标记，界面接上后照常判定', () async {
      final String previousMarker = jsonEncode(<String, Object?>{
        'pid': 777,
        'startedAt': 1000,
        'version': '3.3.0-debug.23025',
        'lifecycle': 'resumed',
        'lifecycleAt': 1500,
        'clean': false,
        'initialised': true,
      });
      final File f = File('${tmp.path}/session_marker.json')
        ..writeAsStringSync(previousMarker);
      final TestWidgetsFlutterBinding binding =
          TestWidgetsFlutterBinding.instance;
      addTearDown(
        () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
      );
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      answerLaunch(hasUi: false);
      answerExits(null);

      bool fullStartupBegan = false;
      final Future<List<ExitReportEntry>> startup =
          holdHeadlessLaunchUntilUi(
            binding: binding,
            mobile: true,
            channel: launch,
          ).then((HeadlessLaunchOutcome o) {
            expect(o.deferred, isTrue);
            fullStartupBegan = true;
            return launchProcess(nowMs: 9000);
          });
      await pumpEventQueue();
      expect(fullStartupBegan, isFalse);
      expect(
        f.readAsStringSync(),
        previousMarker,
        reason: '无界面引擎不许消费 / 覆写上一个会话的标记',
      );

      // 用户点开 app：Activity 接管这个缓存引擎，resumed 到达，完整初始化开始。
      answerLaunch(hasUi: true);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final PreviousExitVerdict? v = classifyPreviousExit(
        await startup,
        version: '3.3.0-debug.23025',
        nowMs: 9000,
      );
      expect(fullStartupBegan, isTrue);
      expect(v, isNotNull);
      expect(v!.kind, PreviousExitKind.unexpected, reason: '上一个有界面会话照常判定');
      expect(v.summary, contains('pid=777'));
      expect(v.summary, contains('lastLifecycle=resumed'));
      expect(readMarker().pid, isNot(777));
      expect(readMarker().lifecycle, 'launching', reason: '标记初值按有界面记');
    });
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
