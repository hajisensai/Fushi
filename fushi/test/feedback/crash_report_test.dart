// 闪退报告：退出类型判定（崩溃 / 用户强停 / 内存回收 / 后台回收要分开）、待报去重与
// 合并窗口、「以后自动发送」开关（默认关、落盘）、提交载荷带日志且重试复用幂等键、
// 启动即闪退的提前提交并入反馈中心、启动前提示的放行。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/previous_exit_log.dart';
import 'package:fushi/src/feedback/crash_report.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/pages/implementations/feedback/crash_report_prompt.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Uint8List _fakeGzip(String log) =>
    Uint8List.fromList(<int>[0x1f, 0x8b, ...utf8.encode(log)]);

/// 上次会话标记（停在 [lifecycle]、没标 clean）→ 本次启动读到的那条证据。
ExitReportEntry _markerEntry(
  Directory dir, {
  String lifecycle = 'resumed',
  bool initialised = true,
}) {
  final File f = File('${dir.path}/session_marker.json');
  final SessionMarker previous = SessionMarker(f, pid: 7, version: '1.2.3')
    ..start(nowMs: 1000);
  if (initialised) previous.recordInitialised();
  previous.recordLifecycle(lifecycle, nowMs: 2000);
  final PreviousSession? read = SessionMarker(
    f,
    pid: 8,
    version: '1.2.4',
  ).start(nowMs: 3000);
  return describeUncleanPreviousSession(read)!;
}

PreviousExitVerdict _verdict({
  PreviousExitKind kind = PreviousExitKind.nativeCrash,
  int atMs = 5000,
  bool duringStartup = false,
  int count = 1,
}) => PreviousExitVerdict(
  kind: kind,
  count: count,
  foreground: true,
  duringStartup: duringStartup,
  atMs: atMs,
  version: '1.2.3',
  summary: 'exception=0xC0000005 module=fushidicts.dll+0x1234',
);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('fushi_crash_report_'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('退出类型判定', () {
    test('Windows 崩溃摘要压过会话标记：原生崩溃，值得报', () {
      final PreviousExitVerdict v = classifyPreviousExit(
        <ExitReportEntry>[
          _markerEntry(dir),
          ...formatWindowsCrashSummary(
            '2026-10-30 code=0xC0000005 module=fushidicts.dll+0x1234\n'
            '2026-10-30 code=0xC0000005 module=fushidicts.dll+0x1234',
          ),
        ],
        version: '1.2.3',
        nowMs: 9000,
      )!;
      expect(v.kind, PreviousExitKind.nativeCrash);
      expect(v.count, 2);
      expect(v.worthReporting, isTrue);
      expect(v.duringStartup, isFalse);
      expect(v.summary, contains('fushidicts.dll+0x1234'));
      expect(v.summary, contains(kPreviousExitUncleanSource));
    });

    test('Android 用户强停：即使停在前台也不算闪退', () {
      final PreviousExitVerdict v = classifyPreviousExit(
        <ExitReportEntry>[
          _markerEntry(dir),
          ...formatAndroidExitReports(<Object?, Object?>{
            'reasons': <Object?>[
              <Object?, Object?>{
                'reason': 'USER_REQUESTED',
                'importance': 100,
                'timestamp': 2500,
              },
            ],
          }),
        ],
        version: '1.2.3',
        nowMs: 9000,
      )!;
      expect(v.kind, PreviousExitKind.userStopped);
      expect(v.worthReporting, isFalse);
    });

    test('Android 内存回收：前台算闪退，后台不算', () {
      PreviousExitVerdict lowMemory(int importance) => classifyPreviousExit(
        formatAndroidExitReports(<Object?, Object?>{
          'reasons': <Object?>[
            <Object?, Object?>{
              'reason': 'LOW_MEMORY',
              'importance': importance,
              'timestamp': 2500,
            },
          ],
        }),
        version: '1.2.3',
        nowMs: 9000,
      )!;
      expect(lowMemory(100).kind, PreviousExitKind.memoryKill);
      expect(lowMemory(100).worthReporting, isTrue);
      expect(lowMemory(400).worthReporting, isFalse);
      expect(lowMemory(100).atMs, 2500);
    });

    test('Android 崩溃（Java / native / ANR）都值得报；SIGNALED 交给会话标记', () {
      PreviousExitKind? kindOf(String reason) => classifyPreviousExit(
        formatAndroidExitReports(<Object?, Object?>{
          'reasons': <Object?>[
            <Object?, Object?>{'reason': reason, 'importance': 400},
          ],
        }),
        version: '1.2.3',
        nowMs: 9000,
      )?.kind;
      expect(kindOf('CRASH'), PreviousExitKind.crash);
      expect(kindOf('CRASH_NATIVE'), PreviousExitKind.nativeCrash);
      expect(kindOf('ANR'), PreviousExitKind.anr);
      expect(kindOf('SIGNALED'), isNull);
    });

    test('只有会话标记：前台没了 = 意外退出（报），后台没了 = 系统回收（不报）', () {
      final PreviousExitVerdict fg = classifyPreviousExit(
        <ExitReportEntry>[_markerEntry(dir)],
        version: '1.2.3',
        nowMs: 9000,
      )!;
      expect(fg.kind, PreviousExitKind.unexpected);
      expect(fg.worthReporting, isTrue);
      expect(fg.atMs, 2000);

      final PreviousExitVerdict bg = classifyPreviousExit(
        <ExitReportEntry>[_markerEntry(dir, lifecycle: 'paused')],
        version: '1.2.3',
        nowMs: 9000,
      )!;
      expect(bg.kind, PreviousExitKind.backgroundReclaim);
      expect(bg.worthReporting, isFalse);
    });

    test('初始化没走完就没了 = 启动即闪退；旧版本标记没有该字段按已初始化', () {
      final PreviousExitVerdict v = classifyPreviousExit(
        <ExitReportEntry>[
          _markerEntry(dir, lifecycle: 'launching', initialised: false),
        ],
        version: '1.2.3',
        nowMs: 9000,
      )!;
      expect(v.duringStartup, isTrue);
      expect(v.kind, PreviousExitKind.unexpected);

      final PreviousSession legacy = PreviousSession.tryParse(
        '{"pid":1,"startedAt":1,"version":"1.0.0","lifecycle":"resumed",'
        '"lifecycleAt":2,"clean":false}',
      )!;
      expect(legacy.initialised, isTrue);
    });

    test('正常退出、没有平台证据：不判定', () {
      expect(
        classifyPreviousExit(
          const <ExitReportEntry>[
            ExitReportEntry('Process.androidTrimMemory', 'trim', severe: false),
          ],
          version: '1.2.3',
          nowMs: 9000,
        ),
        isNull,
      );
    });
  });

  group('待报去重 / 合并 / 自动发送开关', () {
    test('关着时不记；同一份证据只记一次；不值得报的不记', () {
      final CrashReporter off = CrashReporter()..attach(dir, enabled: false);
      off.recordVerdict(_verdict());
      expect(off.pendingCount, 0);

      final CrashReporter r = CrashReporter()..attach(dir, enabled: true);
      r
        ..recordVerdict(_verdict())
        ..recordVerdict(_verdict())
        ..recordVerdict(_verdict(kind: PreviousExitKind.userStopped, atMs: 6));
      expect(r.pendingCount, 1);
      // 落盘：新实例（下次启动）读得到。
      expect((CrashReporter()..attach(dir, enabled: true)).pendingCount, 1);
    });

    test('自动发送默认关，改了落盘', () {
      final CrashReporter r = CrashReporter()..attach(dir, enabled: true);
      expect(r.autoSend, isFalse);
      r.setAutoSend(true);
      expect((CrashReporter()..attach(dir, enabled: true)).autoSend, isTrue);
    });

    test('「不用了」清掉这批待报', () {
      final CrashReporter r = CrashReporter()..attach(dir, enabled: true);
      r.recordVerdict(_verdict());
      expect(r.currentOffer(), isNotNull);
      r.decline();
      expect(r.currentOffer(), isNull);
      expect((CrashReporter()..attach(dir, enabled: true)).pendingCount, 0);
    });

    test('提交后合并窗口内再闪退：攒着不问；窗口过后合成一份（标题带次数）', () async {
      int now = 1000000;
      final List<http.Request> requests = <http.Request>[];
      final FeedbackService service = _service(dir, requests, (_) async {
        return null;
      });
      final CrashReporter r = CrashReporter(nowMs: () => now)
        ..attach(dir, enabled: true)
        ..recordVerdict(_verdict(atMs: 1));
      await r.submit(service, _draft);
      expect(r.pendingCount, 0);
      expect(r.lastTicketId, 'abcdefghij');

      now += 60 * 1000;
      r
        ..recordVerdict(_verdict(atMs: 2))
        ..recordVerdict(_verdict(atMs: 3, count: 2));
      expect(r.currentOffer(), isNull, reason: '合并窗口内不再问 / 不再自动发');
      expect(r.pendingCount, 3);

      now += kCrashReportMergeWindow.inMilliseconds;
      final CrashReportOffer offer = r.currentOffer()!;
      expect(offer.totalCount, 3);
      expect(offer.occurrences, hasLength(2));
      expect(crashReportDraftFor(offer, 'k' * 32).title, contains('x3'));
    });

    test('待报超过上限：更早的只计数', () {
      final CrashReporter r = CrashReporter()..attach(dir, enabled: true);
      for (int i = 0; i < kCrashReportMaxOccurrences + 3; i++) {
        r.recordVerdict(_verdict(atMs: 100 + i));
      }
      final CrashReportOffer offer = r.currentOffer()!;
      expect(offer.occurrences, hasLength(kCrashReportMaxOccurrences));
      expect(offer.totalCount, kCrashReportMaxOccurrences + 3);
    });
  });

  group('提交', () {
    test('载荷：bug 分类、标题带退出类型与版本、正文是退出摘要、附日志', () async {
      final List<http.Request> requests = <http.Request>[];
      final FeedbackService service = _service(
        dir,
        requests,
        (_) async => null,
      );
      final CrashReporter r = CrashReporter()
        ..attach(dir, enabled: true)
        ..recordVerdict(_verdict());
      await r.submit(service, _draft);

      expect(requests.map((http.Request q) => q.url.path), <String>[
        '/v1/feedback',
        '/v1/feedback/abcdefghij/attachments/log',
      ]);
      final Map<String, dynamic> body =
          jsonDecode(requests.first.body) as Map<String, dynamic>;
      expect(body['category'], 'bug');
      expect(body['title'], contains('native crash'));
      expect(body['title'], contains('1.2.3'));
      expect(body['body'], contains('fushidicts.dll+0x1234'));
      expect(body['body'], contains('nativeCrash'));
      expect((body['meta'] as Map<String, dynamic>)['logs_attached'], isTrue);
      expect(body['submissionKey'], isA<String>());
      expect(
        requests.last.bodyBytes,
        _fakeGzip('[Process.windowsCrashSummary] crash'),
      );
      // 进了反馈中心的本机清单。
      expect(service.byId('abcdefghij'), isNotNull);
    });

    test('闪退报告只附错误日志：取日志时不带调试日志', () async {
      final List<http.Request> requests = <http.Request>[];
      final List<bool> flags = <bool>[];
      final FeedbackService service = _service(
        dir,
        requests,
        (_) async => null,
        debugLogFlags: flags,
      );
      final CrashReporter r = CrashReporter()
        ..attach(dir, enabled: true)
        ..recordVerdict(_verdict());
      await r.submit(service, _draft);

      expect(flags, <bool>[false]);
      expect(
        requests.map((http.Request q) => q.url.path),
        contains('/v1/feedback/abcdefghij/attachments/log'),
      );
    });

    test('闪退报告草稿：不带调试日志、退出摘要脱敏', () {
      const CrashReportOffer offer = CrashReportOffer(<CrashOccurrence>[
        CrashOccurrence(
          kind: PreviousExitKind.nativeCrash,
          count: 1,
          atMs: 5000,
          version: '1.2.3',
          foreground: true,
          duringStartup: false,
          summary: r'module=C:\Users\alice\AppData\fushi.dll+0x10',
        ),
      ]);
      final FeedbackDraft draft = buildCrashReportDraft(
        offer,
        title: 't',
        header: 'h',
        submissionKey: 'k',
      );
      expect(draft.includeLogs, isTrue);
      expect(draft.includeDebugLog, isFalse);
      expect(draft.body, contains(r'module=~\AppData\fushi.dll+0x10'));
      expect(draft.body, isNot(contains('alice')));
    });

    test('正文没交上去：待报留着，重试带同一个幂等键', () async {
      final List<http.Request> requests = <http.Request>[];
      bool fail = true;
      final FeedbackService service = _service(dir, requests, (
        http.Request q,
      ) async {
        if (fail && q.url.path == '/v1/feedback') {
          return _json(<String, dynamic>{'error': 'internal'}, 500);
        }
        return null;
      });
      final CrashReporter r = CrashReporter()
        ..attach(dir, enabled: true)
        ..recordVerdict(_verdict());
      await expectLater(r.submit(service, _draft), throwsA(anything));
      expect(r.pendingCount, 1);

      // 「下次启动」：新实例从落盘状态继续。
      fail = false;
      final CrashReporter again = CrashReporter()..attach(dir, enabled: true);
      await again.submit(service, _draft);
      final List<Object?> keys = <Object?>[
        for (final http.Request q in requests)
          if (q.url.path == '/v1/feedback')
            (jsonDecode(q.body) as Map<String, dynamic>)['submissionKey'],
      ];
      expect(keys, hasLength(2));
      expect(keys.first, keys.last);
      expect(again.pendingCount, 0);
    });

    test('两次尝试之间新来的闪退：不顶着旧键重发、不被清掉，进下一份报告（新键）', () async {
      int now = 1000000;
      final List<http.Request> requests = <http.Request>[];
      bool fail = true;
      final FeedbackService service = _service(dir, requests, (
        http.Request q,
      ) async {
        if (fail && q.url.path == '/v1/feedback') {
          return _json(<String, dynamic>{'error': 'internal'}, 500);
        }
        return null;
      });
      const int crashA = 5000;
      const int crashB = 7200000;
      String at(int ms) =>
          DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();
      final CrashReporter r = CrashReporter(nowMs: () => now)
        ..attach(dir, enabled: true)
        ..recordVerdict(_verdict(atMs: crashA));
      await expectLater(r.submit(service, _draft), throwsA(anything));

      // 「下次启动」：又闪退了一次 B，然后重试上一份。
      fail = false;
      final CrashReporter again = CrashReporter(nowMs: () => now)
        ..attach(dir, enabled: true)
        ..recordVerdict(_verdict(atMs: crashB));
      expect(again.pendingCount, 2);
      expect(
        again.currentOffer()!.occurrences.single.atMs,
        crashA,
        reason: '先重发没交上去的那批（只含 A）',
      );
      await again.submit(service, _draft);

      List<Map<String, dynamic>> bodies() => <Map<String, dynamic>>[
        for (final http.Request q in requests)
          if (q.url.path == '/v1/feedback')
            jsonDecode(q.body) as Map<String, dynamic>,
      ];
      expect(bodies(), hasLength(2));
      expect(bodies()[1]['submissionKey'], bodies()[0]['submissionKey']);
      expect(bodies()[1]['body'], contains(at(crashA)));
      expect(bodies()[1]['body'], isNot(contains(at(crashB))));
      // B 没跟着 A 的回执被清掉，落盘也还在。
      expect(again.pendingCount, 1);
      expect((CrashReporter()..attach(dir, enabled: true)).pendingCount, 1);

      // 合并窗口过后：B 单独成一份，新幂等键。
      now += kCrashReportMergeWindow.inMilliseconds;
      expect(again.currentOffer()!.occurrences.single.atMs, crashB);
      await again.submit(service, _draft);
      expect(bodies(), hasLength(3));
      expect(bodies()[2]['submissionKey'], isNot(bodies()[0]['submissionKey']));
      expect(bodies()[2]['body'], contains(at(crashB)));
      expect(bodies()[2]['body'], isNot(contains(at(crashA))));
      expect(again.pendingCount, 0);
    });

    test('旧格式状态（顶层幂等键）：当时的待报整批按那个键重发', () {
      final File f = File('${dir.path}/$kCrashReportStateFileName');
      f.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'autoSend': false,
          'pending': <Object?>[
            CrashOccurrence.fromVerdict(_verdict(atMs: 11)).toJson(),
          ],
          'droppedCount': 2,
          'submissionKey': 'legacy-key',
          'lastSubmittedAt': 0,
        }),
      );
      final CrashReportState state = CrashReportStore(f).read();
      expect(state.inFlight?.submissionKey, 'legacy-key');
      expect(state.inFlight?.offer.totalCount, 3);
      expect(state.pending, isEmpty);
    });
  });

  group('启动即闪退', () {
    test('自动发送：不等网络就放行初始化；后台提交到 spool，首页出来后并入反馈中心'
        '（含没传上去的日志）', () async {
      final List<http.Request> requests = <http.Request>[];
      final CrashReporter r = CrashReporter()
        ..attach(dir, enabled: true)
        ..setAutoSend(true)
        ..recordVerdict(_verdict(duringStartup: true));
      // 弱网：正文请求一直不回，直到测试放行。
      final Completer<void> network = Completer<void>();
      final FeedbackService spool = _service(r.spoolDir!, requests, (
        http.Request q,
      ) async {
        if (q.url.path == '/v1/feedback') await network.future;
        if (q.url.path.endsWith('/log')) {
          return _json(<String, dynamic>{'error': 'internal'}, 503);
        }
        return null;
      });
      await runCrashReportStartupGate(
        r,
        spoolService: spool,
        markAwaitingDecision: (_) => fail('自动发送不进入等用户选择'),
      );
      // 闸门已返回（初始化放行），而正文请求还卡在网络上。
      expect(network.isCompleted, isFalse);
      expect(crashReportStartupPrompt.value, isNull, reason: '自动发送不弹提示');
      expect(r.handledThisSession, isTrue);
      expect(r.pendingCount, 1, reason: '还没交上去：这批留在状态文件里');
      expect(
        (CrashReporter()..attach(dir, enabled: true)).pendingCount,
        1,
        reason: '本机落盘先于网络：此刻进程没了下次启动照样重发',
      );

      final Directory dataRoot = Directory('${dir.path}/data')..createSync();
      final FeedbackService main = _service(dataRoot, requests, (_) async {
        return null;
      });
      // 首页出来后并入 spool：先等后台提交跑完，不会把还在写的 spool 并走。
      final Future<void> adopted = r.adoptSpool(main);
      await Future<void>.delayed(Duration.zero);
      expect(main.byId('abcdefghij'), isNull);
      network.complete();
      await adopted;
      expect(r.pendingCount, 0);
      expect(main.byId('abcdefghij'), isNotNull);
      expect(main.pendingSlots('abcdefghij'), <String>{'log'});
      expect(r.spoolDir!.existsSync(), isFalse);
      expect(
        (await FeedbackTicketStore(dataRoot).read()).single.id,
        'abcdefghij',
      );
    });

    test('手动：加载页上提示，用户选完才放行初始化', () async {
      final CrashReporter r = CrashReporter()
        ..attach(dir, enabled: true)
        ..recordVerdict(_verdict(duringStartup: true));
      bool released = false;
      final Future<void> gate = runCrashReportStartupGate(
        r,
        spoolService: _service(r.spoolDir!, <http.Request>[], (_) async {
          return null;
        }),
      ).then((_) => released = true);
      await Future<void>.delayed(Duration.zero);
      final CrashReportStartupRequest? request = crashReportStartupPrompt.value;
      expect(request, isNotNull);
      expect(released, isFalse);

      await request!.send(false);
      await gate;
      expect(released, isTrue);
      expect(crashReportStartupPrompt.value, isNull);
      expect(r.pendingCount, 0);
    });

    test('停在启动前提示上被关掉 / 杀掉：下次启动按用户结束，不算又一次启动即闪退', () async {
      // 本次会话标记接到 PreviousExitLog（真实装配：闸门默认就写它）。
      await PreviousExitLog.collect(
        appDir: dir,
        version: '1.2.4',
        isAndroid: false,
        isWindows: false,
        isMacOS: false,
        isIOS: false,
        nowMs: 1000,
      );
      final File markerFile = File(
        '${dir.path}${Platform.pathSeparator}session_marker.json',
      );
      bool awaitingOnDisk() =>
          (jsonDecode(markerFile.readAsStringSync())
              as Map<String, dynamic>)['awaitingCrashReportDecision'] ==
          true;

      final CrashReporter r = CrashReporter()
        ..attach(dir, enabled: true)
        ..recordVerdict(_verdict(duringStartup: true));
      final Future<void> gate = runCrashReportStartupGate(
        r,
        spoolService: _service(r.spoolDir!, <http.Request>[], (_) async {
          return null;
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(crashReportStartupPrompt.value, isNotNull);
      expect(awaitingOnDisk(), isTrue, reason: '提示出现时已落盘');

      // 此刻进程被杀：下次启动读到的就是这份标记。
      final PreviousSession killed = PreviousSession.tryParse(
        markerFile.readAsStringSync(),
      )!;
      expect(killed.clean, isFalse);
      expect(killed.initialised, isFalse);
      final ExitReportEntry entry = describeUncleanPreviousSession(killed)!;
      final PreviousExitVerdict v = classifyPreviousExit(
        <ExitReportEntry>[entry],
        version: '1.2.4',
        nowMs: 9000,
      )!;
      expect(v.kind, PreviousExitKind.userStopped);
      expect(v.worthReporting, isFalse);
      expect(entry.severe, isFalse);
      // 平台另有崩溃证据时照常按崩溃算。
      expect(
        classifyPreviousExit(
          <ExitReportEntry>[
            entry,
            const ExitReportEntry(
              kWindowsCrashSummarySource,
              'exception=0xC0000005',
              severe: true,
              kind: PreviousExitKind.nativeCrash,
            ),
          ],
          version: '1.2.4',
          nowMs: 9000,
        )!.worthReporting,
        isTrue,
      );

      // 用户选完：标记清掉，之后初始化里再没了照常算启动即闪退。
      crashReportStartupPrompt.value!.finish();
      await gate;
      expect(awaitingOnDisk(), isFalse);
      final ExitReportEntry later = describeUncleanPreviousSession(
        PreviousSession.tryParse(markerFile.readAsStringSync()),
      )!;
      expect(later.kind, PreviousExitKind.unexpected);
      expect(later.duringStartup, isTrue);
    });

    test('不是启动即闪退：不拦初始化（交给首页出来后的提示）', () async {
      final CrashReporter r = CrashReporter()
        ..attach(dir, enabled: true)
        ..recordVerdict(_verdict());
      await runCrashReportStartupGate(r);
      expect(crashReportStartupPrompt.value, isNull);
      expect(r.handledThisSession, isFalse);
      expect(r.pendingCount, 1);
    });
  });

  testWidgets('提示卡片：发送失败显示重试 / 跳过，重试沿用上次的选择', (WidgetTester tester) async {
    final List<bool> sends = <bool>[];
    int skips = 0;
    final CrashReportOffer offer = CrashReportOffer(<CrashOccurrence>[
      CrashOccurrence.fromVerdict(_verdict()),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CrashReportPromptCard(
            offer: offer,
            onSend: (bool always) async {
              sends.add(always);
              if (sends.length == 1) throw StateError('offline');
            },
            onDecline: () {},
            onSkip: () => skips++,
          ),
        ),
      ),
    );
    expect(find.textContaining('native crash'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('crash-report-always')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('crash-report-retry')), findsOne);
    await tester.tap(find.byKey(const ValueKey<String>('crash-report-retry')));
    // 发送成功后卡片停在「正在发送」（转圈不停），由外层收起：不能 pumpAndSettle。
    await tester.pump(); // 切到「正在发送」，切换动画从这一帧开始
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(); // 切换动画走完后移除旧子树的那一帧
    expect(sends, <bool>[true, true]);
    expect(
      find.byKey(const ValueKey<String>('crash-report-sending')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey<String>('crash-report-skip')),
      findsNothing,
      reason: '重试成功后不再显示失败态',
    );
    expect(skips, 0);
  });
}

FeedbackDraft _draft(CrashReportOffer offer, String key) =>
    crashReportDraftFor(offer, key);

/// 一个连假服务端的反馈服务：[override] 返回 null 时按成功回应（提交回执 / 附件 201）。
/// 每次取日志时把 `includeDebugLog` 记进 [debugLogFlags]（给了的话）。
FeedbackService _service(
  Directory root,
  List<http.Request> requests,
  Future<http.Response?> Function(http.Request r) override, {
  List<bool>? debugLogFlags,
}) => FeedbackService(
  supportRoot: () async => root,
  client: () => LeaderboardClient(
    baseUrl: Uri.parse('https://rank.example'),
    httpClientFactory: () async => MockClient((http.Request r) async {
      requests.add(r);
      final http.Response? custom = await override(r);
      if (custom != null) return custom;
      if (r.url.path == '/v1/feedback') {
        return _json(<String, dynamic>{
          'id': 'abcdefghij',
          'ticket': 'T' * 32,
          'status': 'open',
          'createdAt': 1000,
          'updatedAt': 1000,
        }, 201);
      }
      return _json(<String, dynamic>{'slot': 'x'}, 201);
    }),
  ),
  meta: () async => <String, Object?>{'platform': 'test'},
  logText: ({required bool includeDebugLog}) {
    debugLogFlags?.add(includeDebugLog);
    return '[Process.windowsCrashSummary] crash';
  },
  logEncoder: _fakeGzip,
);
