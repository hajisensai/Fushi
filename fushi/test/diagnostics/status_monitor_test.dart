import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/diagnostics/process_cpu_time.dart';
import 'package:fushi/src/diagnostics/status_monitor.dart';
import 'package:fushi/src/diagnostics/thread_cpu_sampler.dart';
import 'package:fushi/src/diagnostics/ui_activity_probe.dart';
import 'package:fushi/src/diagnostics/windows_memory_probe.dart';
import 'package:fushi/src/pages/implementations/status_monitor_overlay.dart';
import 'package:fushi/src/pages/implementations/status_monitor_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可控的假读数：[cpu] / [now] 由测试推进。
class _Fake {
  int? cpu = 0;
  int now = 0;
  int rss = 300 << 20;
  final ImageCache cache = ImageCache();

  List<ThreadCpuTime>? threads;

  /// 开过几个线程读数来源 / 关掉了几个（采样启停时各一次）。
  int threadSourcesOpened = 0;
  int threadSourcesClosed = 0;
  UiActivitySnapshot ui = (pages: <String>[], tickers: <String, int>{});

  StatusMonitor monitor({int cores = 4, double refreshRate = 60}) =>
      StatusMonitor(
        nowMicros: () => now,
        sources: StatusMonitorSources(
          cpuMicros: () => cpu,
          rssBytes: () => rss,
          windowsMemory: () => const WindowsMemoryReading(
            privateBytes: 200 << 20,
            availPhysBytes: 8000 << 20,
            totalPhysBytes: 16000 << 20,
            commitUsedBytes: 0,
            commitLimitBytes: 0,
          ),
          nativeHeapMb: () => null,
          imageCache: () => cache,
          cores: cores,
          refreshRate: () => refreshRate,
          threadTimes: () {
            threadSourcesOpened++;
            return _FakeThreadSource(this);
          },
          uiActivity: () => ui,
          memoryNotes: () => <String>['srs=1/1'],
        ),
      );
}

class _FakeThreadSource implements ThreadCpuSource {
  _FakeThreadSource(this._fake);

  final _Fake _fake;

  @override
  Future<List<ThreadCpuTime>> read() async =>
      _fake.threads ?? const <ThreadCpuTime>[];

  @override
  void close() => _fake.threadSourcesClosed++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('computeCpuPercent', () {
    test('按墙钟与核数归一化（100% = 全部核跑满）', () {
      // 1 s 墙钟里用了 2 s CPU，4 核 → 50%。
      expect(
        computeCpuPercent(
          previousCpuMicros: 1000000,
          currentCpuMicros: 3000000,
          wallMicros: 1000000,
          cores: 4,
        ),
        50,
      );
    });

    test('缺读数 / 墙钟未前进 / 核数非正返回 null，计数回退按 0', () {
      expect(
        computeCpuPercent(
          previousCpuMicros: null,
          currentCpuMicros: 5,
          wallMicros: 1000000,
          cores: 4,
        ),
        isNull,
      );
      expect(
        computeCpuPercent(
          previousCpuMicros: 0,
          currentCpuMicros: 5,
          wallMicros: 0,
          cores: 4,
        ),
        isNull,
      );
      expect(
        computeCpuPercent(
          previousCpuMicros: 0,
          currentCpuMicros: 5,
          wallMicros: 10,
          cores: 0,
        ),
        isNull,
      );
      expect(
        computeCpuPercent(
          previousCpuMicros: 10,
          currentCpuMicros: 5,
          wallMicros: 10,
          cores: 1,
        ),
        0,
      );
    });
  });

  test('summarizeFrames：构建或光栅任一超预算算卡顿，取各自最大值', () {
    final FrameWindowStats s = summarizeFrames(<(int, int)>[
      (4000, 5000),
      (20000, 3000), // 构建超
      (3000, 17000), // 光栅超
      (16000, 16000), // 恰好等于预算不算
    ], budgetMicros: 16000);
    expect(s.frames, 4);
    expect(s.jankFrames, 2);
    expect(s.worstBuildMs, 20);
    expect(s.worstRasterMs, 17);
    expect(
      summarizeFrames(const <(int, int)>[], budgetMicros: 16000).frames,
      0,
    );
  });

  group('StatusMonitor', () {
    test('采样：CPU 占用、UI 延迟、内存读数与帧预算', () async {
      final _Fake f = _Fake();
      final StatusMonitor m = f.monitor(cores: 4, refreshRate: 120);
      addTearDown(m.resetForTest);
      m.acquire();
      expect(m.running, isTrue);

      // 晚了 250 ms 才触发，期间用了 0.625 s CPU：0.625 / 1.25 / 4 = 12.5%。
      f
        ..now = 1250000
        ..cpu = 625000;
      await m.sample();
      final StatusSample s = m.latest!;
      expect(s.cpuPercent, closeTo(12.5, 1e-9));
      expect(s.cpuPercentOfOneCore, closeTo(50, 1e-9));
      expect(s.uiLagMs, 250);
      expect(s.rssBytes, 300 << 20);
      expect(s.privateBytes, 200 << 20);
      expect(s.systemAvailBytes, 8000 << 20);
      expect(s.frameBudgetMs, closeTo(8.333, 1e-3));

      // 准点触发不报延迟。
      f.now += 1000000;
      await m.sample();
      expect(m.latest!.uiLagMs, 0);
      expect(m.latest!.cpuPercent, 0);
    });

    test('CPU 读数取不到（抛异常 / null）记为不可用，不当成 0%', () async {
      final _Fake f = _Fake()..cpu = null;
      final StatusMonitor m = f.monitor();
      addTearDown(m.resetForTest);
      m.acquire();
      f.now = 1000000;
      await m.sample();
      expect(m.latest!.cpuPercent, isNull);
    });

    test('历史只保留最近 kStatusMonitorHistoryLength 个点', () async {
      final _Fake f = _Fake();
      final StatusMonitor m = f.monitor();
      addTearDown(m.resetForTest);
      m.acquire();
      for (int i = 0; i < kStatusMonitorHistoryLength + 5; i++) {
        f.now += 1000000;
        await m.sample();
      }
      expect(m.history, hasLength(kStatusMonitorHistoryLength));
      // 表头 + 每秒一行（之后是空行分隔的子系统读数段）。
      expect(
        m.describeHistory().split('\n\n').first.trim().split('\n'),
        hasLength(kStatusMonitorHistoryLength + 1),
      );
    });

    test('acquire / release 引用计数：最后一个持有者离开才停', () {
      final StatusMonitor m = _Fake().monitor();
      addTearDown(m.resetForTest);
      m
        ..acquire()
        ..acquire()
        ..release();
      expect(m.running, isTrue);
      m.release();
      expect(m.running, isFalse);
      m.release(); // 多余的 release 不变成负数
      m.acquire();
      expect(m.running, isTrue);
    });

    test('悬浮小窗偏好持久化，开着时启动即采样', () async {
      final StatusMonitor m = _Fake().monitor();
      addTearDown(m.resetForTest);
      await m.setOverlayEnabled(true);
      await m.setOverlayCorner(StatusMonitorOverlayCorner.bottomLeft);
      expect(m.running, isTrue);
      await m.setOverlayEnabled(false);
      expect(m.running, isFalse);
      await m.setOverlayEnabled(true);

      final StatusMonitor restored = _Fake().monitor();
      addTearDown(restored.resetForTest);
      await restored.init();
      expect(restored.overlayEnabled, isTrue);
      expect(restored.overlayCorner, StatusMonitorOverlayCorner.bottomLeft);
      expect(restored.running, isTrue);
    });
  });

  test('processCpuTimeMicros：桌面 / 移动平台真实读数随忙等单调增长', () {
    final int? before = processCpuTimeMicros();
    if (!(Platform.isWindows ||
        Platform.isLinux ||
        Platform.isMacOS ||
        Platform.isAndroid ||
        Platform.isIOS)) {
      expect(before, isNull);
      return;
    }
    expect(before, isNotNull);
    final Stopwatch sw = Stopwatch()..start();
    int x = 0;
    while (sw.elapsedMilliseconds < 200) {
      x = (x * 31 + 7) & 0xFFFFFF;
    }
    final int after = processCpuTimeMicros()!;
    expect(x, isNonNegative);
    // 200 ms 忙等至少记进 50 ms CPU（Windows 计时粒度 15.6 ms）。
    expect(after - before!, greaterThan(50000));
  });

  group('线程 CPU 归因', () {
    test('summarizeThreadCpu：按名归组、单核口径、降序、去零', () {
      const List<ThreadCpuTime> before = <ThreadCpuTime>[
        ThreadCpuTime(id: 1, name: '1.ui', cpuMicros: 1000000),
        ThreadCpuTime(id: 2, name: 'DartWorker', cpuMicros: 0),
        ThreadCpuTime(id: 3, name: 'DartWorker', cpuMicros: 0),
        ThreadCpuTime(id: 4, name: 'idle', cpuMicros: 5),
      ];
      const List<ThreadCpuTime> after = <ThreadCpuTime>[
        ThreadCpuTime(id: 1, name: '1.ui', cpuMicros: 1900000),
        ThreadCpuTime(id: 2, name: 'DartWorker', cpuMicros: 100000),
        ThreadCpuTime(id: 3, name: 'DartWorker', cpuMicros: 200000),
        ThreadCpuTime(id: 4, name: 'idle', cpuMicros: 5),
        // 新线程：累计 5 s，但窗口只有 1 s，最多算 1 s（100%）。
        ThreadCpuTime(id: 9, name: 'fushi-rwkv-3', cpuMicros: 5000000),
      ];
      final List<ThreadGroupUsage> out = summarizeThreadCpu(
        before,
        after,
        wallMicros: 1000000,
      );
      expect(
        <String>[for (final ThreadGroupUsage g in out) g.group],
        <String>['fushi-rwkv-#', '#.ui', 'DartWorker'],
      );
      expect(out[0].percentOfOneCore, 100);
      expect(out[1].percentOfOneCore, closeTo(90, 1e-9));
      expect(out[2].threads, 2);
      expect(out[2].percentOfOneCore, closeTo(30, 1e-9));
      expect(describeThreadGroups(out, max: 2), 'fushi-rwkv-# 100%; #.ui 90%');
    });

    test('classifyThread：各平台的引擎线程名与常见原生线程', () {
      expect(classifyThread('1.ui'), ThreadKind.flutterUi);
      expect(classifyThread('io.flutter.#.ui'), ThreadKind.flutterUi);
      expect(classifyThread('#.raster'), ThreadKind.flutterRaster);
      expect(classifyThread('io.flutter.#.io'), ThreadKind.flutterIo);
      expect(classifyThread('DartWorker'), ThreadKind.dartWorker);
      expect(classifyThread('mpv/vo'), ThreadKind.video);
      expect(classifyThread('rayon-#'), ThreadKind.rust);
      expect(classifyThread(''), ThreadKind.unnamed);
      expect(classifyThread('Binder:#_#'), ThreadKind.other);
      expect(classifyThread(kMainIsolateThreadName), ThreadKind.flutterUi);
      expect(classifyThread('[flutter_windows.dll]'), ThreadKind.flutterEngine);
      expect(classifyThread('[libmpv-#.dll]'), ThreadKind.video);
      expect(classifyThread('[fushi_fsrs.dll]'), ThreadKind.rust);
      expect(classifyThread('[ntdll.dll]'), ThreadKind.system);
      expect(classifyThread('[fushi.exe]'), ThreadKind.other);
    });

    test('采样带上线程占用；卡顿那一秒记下页面、动画与线程', () async {
      final _Fake f = _Fake()
        ..threads = const <ThreadCpuTime>[
          ThreadCpuTime(id: 1, name: '1.ui', cpuMicros: 0),
        ]
        ..ui = (
          pages: <String>['HomePage', 'ReaderPage'],
          tickers: <String, int>{'FushiWavyProgress': 2},
        );
      final StatusMonitor m = f.monitor();
      addTearDown(m.resetForTest);
      m.acquire();
      await Future<void>.delayed(Duration.zero); // 启动时那次线程读数

      f
        ..now = 1000000
        ..threads = const <ThreadCpuTime>[
          ThreadCpuTime(id: 1, name: '1.ui', cpuMicros: 800000),
        ];
      await m.sample();
      expect(m.latest!.threads.single.group, '#.ui');
      expect(m.latest!.threads.single.percentOfOneCore, closeTo(80, 1e-9));
      expect(m.latest!.memoryNotes, <String>['srs=1/1']);
      expect(m.stutters, isEmpty, reason: '准点、无卡顿帧不算卡顿');

      // 下一次晚了 400 ms：判为卡顿，记下当时的页面与动画。
      f.now += 1400000;
      await m.sample();
      expect(m.stutters, hasLength(1));
      final StutterEvent e = m.stutters.single;
      expect(e.sample.uiLagMs, 400);
      expect(e.pages, <String>['HomePage', 'ReaderPage']);
      expect(e.tickers, <String, int>{'FushiWavyProgress': 2});
      expect(m.describeHistory(), contains('page=[HomePage>ReaderPage]'));

      m.clearStutters();
      expect(m.stutters, isEmpty);
    });

    test('线程读数来源只在采样期间存在：开始时开一个，停止时关掉', () async {
      final _Fake f = _Fake();
      final StatusMonitor m = f.monitor();
      addTearDown(m.resetForTest);
      expect(f.threadSourcesOpened, 0, reason: '没人看时不起后台 isolate');
      m
        ..acquire()
        ..acquire();
      expect(f.threadSourcesOpened, 1, reason: '多个持有者共用一个来源');
      m.release();
      expect(f.threadSourcesClosed, 0);
      m.release();
      expect(f.threadSourcesClosed, 1);
      m.acquire();
      expect(f.threadSourcesOpened, 2);
      m.release();
      expect(f.threadSourcesClosed, 2);
    });

    test('ThreadCpuWorker：常驻 isolate 反复读数，close 后读取以错误结束', () async {
      final ThreadCpuWorker w = ThreadCpuWorker(uiThreadId: currentThreadId());
      final List<ThreadCpuTime> first = await w.read();
      final List<ThreadCpuTime> second = await w.read();
      if (Platform.isWindows ||
          Platform.isLinux ||
          Platform.isMacOS ||
          Platform.isAndroid ||
          Platform.isIOS) {
        expect(first, isNotEmpty);
        expect(second, isNotEmpty);
        // 后台 isolate 读到的同一进程：测试主 isolate 的线程被标成 UI 线程。
        expect(
          second.where((ThreadCpuTime t) => t.name == kMainIsolateThreadName),
          hasLength(1),
        );
      } else {
        expect(first, isEmpty);
      }
      w.close();
      await expectLater(w.read(), throwsStateError);
    });

    test('ThreadCpuWorker：还在等的读取在 close 时以错误结束，不会挂住', () async {
      final ThreadCpuWorker w = ThreadCpuWorker();
      final Future<List<ThreadCpuTime>> pending = w.read();
      w.close();
      await expectLater(pending, throwsStateError);
    });

    test('isStutterSample 判据', () {
      StatusSample s({int lag = 0, int jank = 0, double worst = 0}) =>
          StatusSample(
            time: DateTime(2026),
            cpuPercent: 0,
            cores: 1,
            rssBytes: 0,
            privateBytes: null,
            nativeHeapMb: null,
            systemAvailBytes: null,
            systemTotalBytes: null,
            imageCacheBytes: 0,
            imageCacheLive: 0,
            frames: FrameWindowStats(
              frames: 60,
              jankFrames: jank,
              worstBuildMs: worst,
              worstRasterMs: 0,
            ),
            frameBudgetMs: 16.7,
            uiLagMs: lag,
          );
      expect(isStutterSample(s()), isFalse);
      expect(isStutterSample(s(lag: 99, jank: 4, worst: 49)), isFalse);
      expect(isStutterSample(s(lag: 100)), isTrue);
      expect(isStutterSample(s(worst: 50)), isTrue);
      expect(isStutterSample(s(jank: 5)), isTrue);
    });

    test('readThreadCpuTimes：真实平台能读到本进程线程，CPU 随忙等增长', () {
      final int? ui = currentThreadId();
      final List<ThreadCpuTime> before = readThreadCpuTimes(uiThreadId: ui);
      if (!(Platform.isWindows ||
          Platform.isLinux ||
          Platform.isMacOS ||
          Platform.isAndroid ||
          Platform.isIOS)) {
        expect(before, isEmpty);
        return;
      }
      expect(before, isNotEmpty);
      final Stopwatch sw = Stopwatch()..start();
      int x = 0;
      while (sw.elapsedMilliseconds < 300) {
        x = (x * 31 + 7) & 0xFFFFFF;
      }
      expect(x, isNonNegative);
      final List<ThreadCpuTime> after = readThreadCpuTimes(uiThreadId: ui);
      final List<ThreadGroupUsage> usage = summarizeThreadCpu(
        before,
        after,
        wallMicros: 300000,
      );
      // 打印出来，核对各平台引擎线程的真实命名。
      // ignore: avoid_print
      print(
        'threads(${after.length}): '
        '${after.map((ThreadCpuTime t) => t.name).toSet().join(' | ')}',
      );
      // ignore: avoid_print
      print('usage: ${describeThreadGroups(usage)}');
      expect(usage, isNotEmpty);
      expect(usage.first.percentOfOneCore, greaterThan(30));
      // 忙等发生在测试主 isolate 的线程上：它必须被认成 UI 线程且排第一。
      expect(ui, isNotNull);
      expect(usage.first.group, kMainIsolateThreadName);
      // Windows：没有线程名的线程按入口模块命名，不应再有大片未命名。
      if (Platform.isWindows) {
        expect(
          after.where((ThreadCpuTime t) => t.name.isEmpty).length,
          lessThan(after.length ~/ 2),
        );
      }
    });
  });

  group('悬浮小窗', () {
    Widget host(StatusMonitor m) => MaterialApp(
      home: Stack(
        children: <Widget>[
          const SizedBox.expand(),
          StatusMonitorOverlayHost(monitor: m),
        ],
      ),
    );

    testWidgets('关着时不画，开了画读数且整层不吃点击', (WidgetTester tester) async {
      final _Fake f = _Fake();
      final StatusMonitor m = f.monitor();
      addTearDown(m.resetForTest);
      await tester.pumpWidget(host(m));
      expect(find.byType(StatusMonitorReadout), findsNothing);

      await m.setOverlayEnabled(true);
      f.now = 1000000;
      await m.sample();
      await tester.pump();
      expect(find.byType(StatusMonitorReadout), findsOneWidget);
      expect(find.textContaining('RAM 300 MB', findRichText: true), findsOne);
      expect(
        find.ancestor(
          of: find.byType(StatusMonitorReadout),
          matching: find.byType(IgnorePointer),
        ),
        findsWidgets,
      );
      await m.setOverlayEnabled(false);
      await tester.pump();
    });
  });

  testWidgets('状态页：显示读数，打开时采样、关页后停止', (WidgetTester tester) async {
    final _Fake f = _Fake();
    final StatusMonitor m = f.monitor();
    addTearDown(m.resetForTest);
    // 窗口调高，让三节（实时 / 明细 / 悬浮小窗）都在首屏内构建出来。
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: StatusMonitorPage(monitor: m)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    expect(m.running, isTrue);
    expect(find.text(t.status_monitor_waiting), findsOneWidget);

    f
      ..now = 1000000
      ..cpu = 400000;
    await m.sample();
    await tester.pump();
    expect(find.text('10.0%'), findsOneWidget); // 0.4 s / 1 s / 4 核
    expect(find.text('300 MB'), findsWidgets);
    expect(find.text(t.status_monitor_overlay_toggle), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(m.running, isFalse);
  });

  testWidgets('状态页：悬浮小窗分区排第一，默认窗口首屏就能看到开关（BUG-5258）', (
    WidgetTester tester,
  ) async {
    final _Fake f = _Fake();
    final StatusMonitor m = f.monitor();
    addTearDown(m.resetForTest);
    // 默认 800×600 测试窗口：悬浮小窗排在读数后面时整节懒构建不出来。
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: StatusMonitorPage(monitor: m)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    final Finder toggle = find.text(t.status_monitor_overlay_toggle);
    expect(toggle, findsOneWidget);
    expect(
      tester.getTopLeft(toggle).dy,
      lessThan(tester.getTopLeft(find.text(t.status_monitor_cpu)).dy),
      reason: '悬浮小窗开关在实时读数之上',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
