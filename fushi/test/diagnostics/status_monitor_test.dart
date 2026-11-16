import 'dart:io';

import 'package:flutter/painting.dart' show ImageCache;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/diagnostics/process_cpu_time.dart';
import 'package:fushi/src/diagnostics/status_monitor.dart';
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
        ),
      );
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
    test('采样：CPU 占用、UI 延迟、内存读数与帧预算', () {
      final _Fake f = _Fake();
      final StatusMonitor m = f.monitor(cores: 4, refreshRate: 120);
      addTearDown(m.resetForTest);
      m.acquire();
      expect(m.running, isTrue);

      // 晚了 250 ms 才触发，期间用了 0.625 s CPU：0.625 / 1.25 / 4 = 12.5%。
      f
        ..now = 1250000
        ..cpu = 625000;
      m.sample();
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
      m.sample();
      expect(m.latest!.uiLagMs, 0);
      expect(m.latest!.cpuPercent, 0);
    });

    test('CPU 读数取不到（抛异常 / null）记为不可用，不当成 0%', () {
      final _Fake f = _Fake()..cpu = null;
      final StatusMonitor m = f.monitor();
      addTearDown(m.resetForTest);
      m.acquire();
      f.now = 1000000;
      m.sample();
      expect(m.latest!.cpuPercent, isNull);
    });

    test('历史只保留最近 kStatusMonitorHistoryLength 个点', () {
      final _Fake f = _Fake();
      final StatusMonitor m = f.monitor();
      addTearDown(m.resetForTest);
      m.acquire();
      for (int i = 0; i < kStatusMonitorHistoryLength + 5; i++) {
        f.now += 1000000;
        m.sample();
      }
      expect(m.history, hasLength(kStatusMonitorHistoryLength));
      expect(
        m.describeHistory().trim().split('\n'),
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
      m.sample();
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
    m.sample();
    await tester.pump();
    expect(find.text('10.0%'), findsOneWidget); // 0.4 s / 1 s / 4 核
    expect(find.text('300 MB'), findsWidgets);
    expect(find.text(t.status_monitor_overlay_toggle), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(m.running, isFalse);
  });
}
