import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_status_footer.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../pages/reader_fushi_page_source_corpus.dart';

/// 桌面端阅读器底部状态行（ッツ Reader 风格）：
///  ① 纯函数——启用判据 / 预留高 / 字时 / 秒表格式 / 两侧文案；
///  ② 组件行为——秒表随 tick 跳动、暂停态换图标、进度开关、点击语义；
///  ③ 源码扫描守卫——状态行的预留进 `_readerBottomReserve` 单一真相源、桌面端顶部
///     进度 pill 让位、悬浮判定不再把桌面端顶部进度算进去、BUG-1692 RepaintBoundary、
///     设置页在桌面端隐藏顶部进度的「悬浮 / 位置」两项。
void main() {
  group('pure helpers', () {
    test('enabled: desktop && !lyrics', () {
      expect(
          readerStatusFooterEnabled(desktop: true, lyricsMode: false), isTrue);
      expect(
          readerStatusFooterEnabled(desktop: true, lyricsMode: true), isFalse);
      expect(readerStatusFooterEnabled(desktop: false, lyricsMode: false),
          isFalse);
    });

    test('reserve: enabled -> footerHeight, else 0', () {
      expect(readerStatusFooterReserve(enabled: true, footerHeight: 28), 28);
      expect(readerStatusFooterReserve(enabled: false, footerHeight: 28), 0);
      expect(
          kReaderStatusFooterHeight, greaterThan(kReaderStatusFooterFontSize),
          reason: '预留高必须装得下文字行盒（视觉高度 == 预留高度铁律）');
    });

    test('chars per hour: 0 when nothing read; rounded otherwise', () {
      expect(readingCharsPerHour(chars: 0, durationMs: 0), 0);
      expect(readingCharsPerHour(chars: 100, durationMs: 0), 0);
      expect(readingCharsPerHour(chars: 0, durationMs: 60000), 0);
      expect(readingCharsPerHour(chars: 100, durationMs: 60000), 6000);
      expect(readingCharsPerHour(chars: 1, durationMs: 3600000 * 3), 0);
      expect(readingCharsPerHour(chars: 2, durationMs: 3600000 * 3), 1);
    });

    test('session clock: m:ss under an hour, h:mm:ss beyond', () {
      expect(formatReadingSessionClock(0), '0:00');
      expect(formatReadingSessionClock(-5), '0:00');
      expect(formatReadingSessionClock(999), '0:00');
      expect(formatReadingSessionClock(1000), '0:01');
      expect(formatReadingSessionClock(65000), '1:05');
      expect(formatReadingSessionClock(59 * 60000 + 59000), '59:59');
      expect(formatReadingSessionClock(3600000), '1:00:00');
      expect(formatReadingSessionClock(3600000 * 10 + 61000), '10:01:01');
    });

    test('tracker label mirrors ttu: "<cph> / h  <clock>"', () {
      expect(
        readerTrackerLabel((durationMs: 0, chars: 0, active: false)),
        '0 / h  0:00',
      );
      expect(
        readerTrackerLabel((durationMs: 120000, chars: 400, active: true)),
        '12000 / h  2:00',
      );
    });

    test('progress label: same format as the top pill; null when unknown', () {
      expect(readerProgressLabel(current: 64988, total: 123962),
          '64988 / 123962  52.43%');
      expect(readerProgressLabel(current: 5, total: 0), isNull);
      expect(readerProgressLabel(current: null, total: 10), isNull);
      expect(readerProgressLabel(current: 10, total: null), isNull);
      expect(readerProgressLabel(current: 20, total: 10), '20 / 10  100.00%',
          reason: '超出总数时百分比钳到 100');
    });
  });

  group('widget', () {
    Widget host({
      required StudySessionTotals Function() totals,
      int? current = 64988,
      int? total = 123962,
      bool showProgress = true,
      VoidCallback? onTap,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ReaderStatusFooter(
              sessionTotals: totals,
              currentChars: current,
              totalChars: total,
              showProgress: showProgress,
              textColor: Colors.white,
              backgroundColor: Colors.black,
              tick: const Duration(milliseconds: 100),
              onTap: onTap,
            ),
          ),
        ),
      );
    }

    testWidgets('renders tracker + progress and re-samples on every tick',
        (WidgetTester tester) async {
      int ms = 0;
      await tester.pumpWidget(host(
        totals: () => (durationMs: ms, chars: 0, active: true),
      ));
      expect(find.text('0 / h  0:00'), findsOneWidget);
      expect(find.text('64988 / 123962  52.43%'), findsOneWidget);
      expect(find.byIcon(Icons.timer_outlined), findsOneWidget);

      ms = 61000;
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('0 / h  1:01'), findsOneWidget,
          reason: '秒表由组件自己的 tick 驱动，不依赖父级重建');
    });

    testWidgets('paused state swaps to the timer-off icon',
        (WidgetTester tester) async {
      bool active = true;
      await tester.pumpWidget(host(
        totals: () => (durationMs: 0, chars: 0, active: active),
      ));
      expect(find.byIcon(Icons.timer_outlined), findsOneWidget);
      active = false;
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byIcon(Icons.timer_off_outlined), findsOneWidget);
      expect(find.byIcon(Icons.timer_outlined), findsNothing);
    });

    testWidgets('progress hidden by the switch or when total unknown',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(
        totals: () => (durationMs: 0, chars: 0, active: false),
        showProgress: false,
      ));
      expect(find.byKey(const ValueKey<String>('fushi_status_progress')),
          findsNothing);
      expect(find.byKey(const ValueKey<String>('fushi_status_tracker')),
          findsOneWidget);

      await tester.pumpWidget(host(
        totals: () => (durationMs: 0, chars: 0, active: false),
        total: null,
      ));
      expect(find.byKey(const ValueKey<String>('fushi_status_progress')),
          findsNothing);
    });

    testWidgets('tap anywhere on the strip fires onTap',
        (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(host(
        totals: () => (durationMs: 0, chars: 0, active: false),
        onTap: () => taps++,
      ));
      final Finder strip = find.byType(ReaderStatusFooter);
      final Rect rect = tester.getRect(strip);
      await tester.tapAt(rect.center);
      expect(taps, 1);
      expect(rect.height, kReaderStatusFooterHeight,
          reason: '视觉高度 == 预留高度（同一常量）');
    });
  });

  group('source-scan guards', () {
    final String src = readReaderPageSource();

    test('footer reserve is part of _readerBottomReserve (single source)', () {
      expect(
        src.contains('_readerBottomReserve =>\n'
            '      _bottomChromeReserve + _statusFooterReserve + _stableBottomInset'),
        isTrue,
        reason: '状态行是挤压式：预留必须与底栏 / 系统 inset 同源进 WebView / 焦点环',
      );
      expect(
        src.contains('_statusFooterReserve => readerStatusFooterReserve('),
        isTrue,
      );
      expect(
        src.contains('_statusFooterEnabled => readerStatusFooterEnabled('),
        isTrue,
      );
    });

    test('desktop: footer replaces the top progress pill', () {
      final String showTop = _slice(
        src,
        '  bool get _showTopProgress =>',
        '  bool get _statusFooterEnabled',
      );
      expect(showTop.contains('!_statusFooterEnabled &&'), isTrue,
          reason: '桌面端顶部不再有 chrome：进度数字挪到右下角');
      final String anyFloating = _slice(
        src,
        '  bool get _anyChromeFloating =>',
        '  /// BUG-1343',
      );
      expect(
        anyFloating.contains('(_topProgressFloating && !_statusFooterEnabled)'),
        isTrue,
        reason: '桌面端顶部进度没有可见面，其悬浮开关不得再驱动「点空白唤出」状态机',
      );
    });

    test(
        'footer paints after the WebView with its own RepaintBoundary (BUG-1692)',
        () {
      final String build = _slice(
        src,
        '  Widget _buildStatusFooter() {',
        '  StudySessionTotals _readingSessionTotals()',
      );
      expect(build.contains('RepaintBoundary('), isTrue);
      expect(build.contains('ReaderStatusFooter('), isTrue);
      expect(build.contains('!_hasEverLoaded'), isTrue,
          reason: '绘制门控与底栏同源用 set-once _hasEverLoaded（切章不闪烁）');
      expect(build.contains('_readerContentReady'), isFalse);
      expect(
        build.contains('bottom: _bottomChromeReserve + _stableBottomInset'),
        isTrue,
        reason: '底栏挤压时状态行坐在底栏之上；悬浮时贴底',
      );
      expect(build.contains('Focus(') || build.contains('canRequestFocus'),
          isFalse,
          reason: '纯指针面，不进焦点遍历池（TODO-700 不变式）');
      // 钉「两行相邻且顺序对」，不钉缩进宽度：Stack 外面多包一层 formatter 就会
      // 把绝对缩进从 20 改成 22，而绘制顺序这个不变式一点没变。
      expect(
        RegExp(r'_buildStatusFooter\(\),\n *buildDictionary\(\),').hasMatch(src),
        isTrue,
        reason: '状态行必须排在词典弹层 / 底栏之前，让它们盖在其上',
      );
    });

    test('session totals are read from StudyClock, no page-side copy', () {
      final String totals = _slice(
        src,
        '  StudySessionTotals _readingSessionTotals() =>',
        '  // ── Top Progress Bar',
      );
      expect(totals.contains('_studyClock?.sessionTotals()'), isTrue,
          reason: 'v92 纪律：账只在 StudyClock 一本，页面只读');
    });

    test('settings: top-progress floating / position hidden on desktop', () {
      final String schema =
          File('lib/src/settings/settings_schema_reading.dart')
              .readAsStringSync()
              .replaceAll('\r\n', '\n');
      expect(
        RegExp(r'showTopProgressBar && !isDesktopPlatform')
            .allMatches(schema)
            .length,
        2,
        reason: '「悬浮阅读进度」与「进度位置」两项在桌面端没有可见面',
      );
      expect(
        schema.contains(
            '(c.readerSource.topProgressFloating && !isDesktopPlatform) ||'),
        isTrue,
        reason: '自动收起时长的可见条件同样不再把桌面端顶部悬浮算进去',
      );
    });
  });
}

String _slice(String src, String start, String end) {
  final int s = src.indexOf(start);
  expect(s, isNonNegative, reason: 'missing start marker: $start');
  final int e = src.indexOf(end, s);
  expect(e, isNonNegative, reason: 'missing end marker: $end');
  return src.substring(s, e);
}
