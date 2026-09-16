import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_status_footer.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../pages/reader_fushi_page_source_corpus.dart';

/// 各平台共用的阅读器底部状态行：
///  ① 纯函数——启用判据 / 预留高 / 字时 / 秒表格式 / 两侧文案；
///  ② 组件行为——秒表随 tick 跳动、暂停态换图标、进度开关、点击语义；
///  ③ 源码扫描守卫——状态行预留、顶部进度 pill 让位、BUG-1692 RepaintBoundary、
///     设置页删除顶部进度的「悬浮 / 位置」两项。
void main() {
  group('pure helpers', () {
    test('enabled on every platform outside lyrics mode', () {
      bool enabled({required bool desktop, required bool lyricsMode}) =>
          readerStatusFooterEnabled(
            desktop: desktop,
            lyricsMode: lyricsMode,
            showTimer: true,
            showProgress: true,
          );
      expect(enabled(desktop: true, lyricsMode: false), isTrue);
      expect(enabled(desktop: true, lyricsMode: true), isFalse);
      expect(enabled(desktop: false, lyricsMode: false), isTrue);
      expect(enabled(desktop: false, lyricsMode: true), isFalse);
    });

    // 两段读数各有开关：任一开着行就在（还有内容要画），都关掉整条行连同 28px
    // 预留一起消失——空行照占正文高度是白吃。
    test('disabled only when both readouts are switched off', () {
      bool enabled({required bool showTimer, required bool showProgress}) =>
          readerStatusFooterEnabled(
            desktop: true,
            lyricsMode: false,
            showTimer: showTimer,
            showProgress: showProgress,
          );
      expect(enabled(showTimer: true, showProgress: true), isTrue);
      expect(enabled(showTimer: true, showProgress: false), isTrue);
      expect(enabled(showTimer: false, showProgress: true), isTrue);
      expect(enabled(showTimer: false, showProgress: false), isFalse,
          reason: '两段都不画时不留空行、回收预留高');
      expect(
        readerStatusFooterEnabled(
          desktop: true,
          lyricsMode: true,
          showTimer: true,
          showProgress: true,
        ),
        isFalse,
        reason: '歌词模式仍然一票否决',
      );
    });

    test('reserve: enabled -> footerHeight, else 0', () {
      expect(readerStatusFooterReserve(enabled: true, footerHeight: 28), 28);
      expect(readerStatusFooterReserve(enabled: false, footerHeight: 28), 0);
      expect(
        readerStatusFooterReserve(
            enabled: true, footerHeight: 28, absorbedByBar: true),
        0,
        reason: 'BUG-2467：读数已并进挤压态底栏，状态行不再另占一条预留',
      );
      expect(
        readerStatusFooterReserve(
            enabled: true, footerHeight: 28, floating: true),
        0,
        reason: '悬浮态状态行随控制栏显隐、不占预留（隐藏满屏、唤出覆盖）',
      );
      expect(
          kReaderStatusFooterHeight, greaterThan(kReaderStatusFooterFontSize),
          reason: '预留高必须装得下文字行盒（视觉高度 == 预留高度铁律）');
    });

    test('band: footer sits inside the system bottom inset (BUG-2470)', () {
      // iPhone：home indicator 34pt 装得下 28px 的状态行 → 带高 34，不是 62。
      expect(
        readerStatusFooterBandHeight(footerReserve: 28, bottomInset: 34),
        34,
      );
      // 桌面 / Android 沉浸模式：inset 0 → 带高就是状态行高。
      expect(
        readerStatusFooterBandHeight(footerReserve: 28, bottomInset: 0),
        28,
      );
      // 小手势条（Android 16dp）装不下状态行 → 带高取状态行高。
      expect(
        readerStatusFooterBandHeight(footerReserve: 28, bottomInset: 16),
        28,
      );
      // 状态行不在场（歌词 / 被底栏吸收）：只剩系统 inset。
      expect(
        readerStatusFooterBandHeight(footerReserve: 0, bottomInset: 34),
        34,
      );
    });

    test(
        'absorbed by bar: only squeeze bar occupying + inline status (BUG-2467)',
        () {
      // 挤压态底栏占位（预留 > 0）且宽屏读数并进底栏右端 → 吸收。
      expect(
        readerStatusFooterAbsorbedByBar(
            inlineStatus: true, bottomChromeReserve: 56),
        isTrue,
      );
      // 悬浮态 / 底栏收起 / 无有声书：底栏不占位 → 状态行照常在场。
      expect(
        readerStatusFooterAbsorbedByBar(
            inlineStatus: true, bottomChromeReserve: 0),
        isFalse,
      );
      // 窄屏读数独立成行：状态行坐在底栏之上，不吸收。
      expect(
        readerStatusFooterAbsorbedByBar(
            inlineStatus: false, bottomChromeReserve: 56),
        isFalse,
      );
      // 悬浮态有声书播放条画着且读数并进其右端 → 同样吸收（底部只留一条）。
      expect(
        readerStatusFooterAbsorbedByBar(
          inlineStatus: true,
          bottomChromeReserve: 0,
          floatingBarPainted: true,
        ),
        isTrue,
      );
      expect(
        readerStatusFooterAbsorbedByBar(
          inlineStatus: false,
          bottomChromeReserve: 0,
          floatingBarPainted: true,
        ),
        isFalse,
      );
    });

    test('visible: squeeze always; floating follows the chrome reveal', () {
      bool vis({
        bool floating = false,
        bool transient = false,
        bool absorbed = false,
        bool loaded = true,
      }) =>
          readerStatusFooterVisible(
            enabled: true,
            hasEverLoaded: loaded,
            absorbedByBar: absorbed,
            floating: floating,
            transientVisible: transient,
          );
      expect(vis(), isTrue);
      expect(vis(loaded: false), isFalse);
      expect(vis(absorbed: true), isFalse);
      expect(vis(floating: true), isFalse, reason: '悬浮收起 → 不画');
      expect(vis(floating: true, transient: true), isTrue);
      expect(vis(floating: true, transient: true, absorbed: true), isFalse);
    });

    test('inline: 横屏且够宽才并进底栏那一行；竖屏一律分层', () {
      bool inline({
        bool enabled = true,
        bool landscape = true,
        double width = 698,
      }) =>
          readerPlaybackStatusInline(
            enabled: enabled,
            landscape: landscape,
            width: width,
          );
      // 用户 2026-09-14「横屏应该同层进度显示」：横屏手机 ~700 逻辑 px 放得下
      // 五颗传输键加一串读数，此前借用顶栏的 760 阈值把它判成窄屏、读数被踢到
      // 底栏之下单独占一行。
      expect(inline(), isTrue);
      expect(inline(landscape: false), isFalse, reason: '竖屏一律分层');
      expect(
        inline(width: kReaderStatusInlineMinWidth - 1),
        isFalse,
        reason: '横屏但窄到传输键都挤，读数不进同一行',
      );
      expect(inline(width: kReaderStatusInlineMinWidth), isTrue);
      expect(inline(enabled: false), isFalse, reason: '两个读数开关都关 → 无读数可并');
    });

    test('edge line: only while the floating footer is hidden', () {
      expect(
        readerProgressEdgeLineVisible(
          floating: true,
          footerVisible: false,
          showProgress: true,
          hasTotal: true,
        ),
        isTrue,
      );
      expect(
        readerProgressEdgeLineVisible(
          floating: true,
          footerVisible: true,
          showProgress: true,
          hasTotal: true,
        ),
        isFalse,
        reason: '状态行唤出时它让位',
      );
      expect(
        readerProgressEdgeLineVisible(
          floating: false,
          footerVisible: false,
          showProgress: true,
          hasTotal: true,
        ),
        isFalse,
        reason: '挤压态状态行常驻，不需要细线',
      );
      expect(
        readerProgressEdgeLineVisible(
          floating: true,
          footerVisible: false,
          showProgress: false,
          hasTotal: true,
        ),
        isFalse,
      );
      expect(
        readerProgressEdgeLineVisible(
          floating: true,
          footerVisible: false,
          showProgress: true,
          hasTotal: false,
        ),
        isFalse,
      );
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

    test('tracker label is just the session clock (chars/h moved to the sheet)',
        () {
      expect(
        readerTrackerLabel((durationMs: 0, chars: 0, active: false)),
        '0:00',
      );
      expect(
        readerTrackerLabel((durationMs: 120000, chars: 400, active: true)),
        '2:00',
      );
    });

    test('progress label: percent only, one decimal; null when unknown', () {
      expect(readerProgressLabel(current: 64988, total: 123962), '52.4%');
      expect(readerProgressLabel(current: 5, total: 0), isNull);
      expect(readerProgressLabel(current: null, total: 10), isNull);
      expect(readerProgressLabel(current: 10, total: null), isNull);
      expect(readerProgressLabel(current: 20, total: 10), '100.0%',
          reason: '超出总数时百分比钳到 100');
      expect(readerProgressRatio(current: 25, total: 100), 0.25);
      expect(readerProgressRatio(current: 1, total: 0), isNull);
    });
  });

  group('widget', () {
    Widget host({
      required StudySessionTotals Function() totals,
      int? current = 64988,
      int? total = 123962,
      bool showTimer = true,
      bool showProgress = true,
      bool centered = false,
      VoidCallback? onTap,
      VoidCallback? onTapTracker,
      VoidCallback? onTapProgress,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ReaderStatusFooter(
              sessionTotals: totals,
              currentChars: current,
              totalChars: total,
              showTimer: showTimer,
              showProgress: showProgress,
              centered: centered,
              textColor: Colors.white,
              backgroundColor: Colors.black,
              tick: const Duration(milliseconds: 100),
              onTap: onTap,
              onTapTracker: onTapTracker,
              onTapProgress: onTapProgress,
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
      expect(find.text('0:00'), findsOneWidget);
      expect(find.text('52.4%'), findsOneWidget);
      expect(find.byType(ReaderStatusProgressTrack), findsOneWidget,
          reason: '百分比前带一段短进度条');
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget,
          reason: '计时中画 ⏸（点了会停），与统计侧栏那颗暂停键同一套符号');

      ms = 61000;
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('1:01'), findsOneWidget,
          reason: '秒表由组件自己的 tick 驱动，不依赖父级重建');
    });

    testWidgets('paused state swaps the toggle to play',
        (WidgetTester tester) async {
      bool active = true;
      await tester.pumpWidget(host(
        totals: () => (durationMs: 0, chars: 0, active: active),
        onTapTracker: () {},
      ));
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      active = false;
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget,
          reason: '已停画 ▶：点它是「继续计时」');
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
    });

    // 此前这里是一枚纯装饰的秒表字形：图标报状态、点它没有任何反馈，能停表的只有
    // 包在外面那层看不见的 GestureDetector。现在它是一颗真的 MD3 IconButton。
    testWidgets('the clock icon itself is a button that toggles the timer',
        (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(host(
        totals: () => (durationMs: 0, chars: 0, active: true),
        onTapTracker: () => taps++,
      ));
      final Finder button = find.byType(ReaderStudyClockButton);
      expect(button, findsOneWidget);
      expect(find.descendant(of: button, matching: find.byType(IconButton)),
          findsOneWidget,
          reason: '是 MD3 IconButton（state layer + ripple + tooltip），不是裸 Icon');
      await tester.tap(button);
      await tester.pump();
      expect(taps, 1);

      // 视觉高度 == 预留高度是 chrome 铁律：IconButton 默认会把自己裹进 48dp 触摸
      // 靶，那会把 28px 的状态行撑成 48px，正文跟着被挤。
      expect(tester.getRect(button).height, kReaderStatusFooterHeight);
      expect(tester.getRect(find.byType(ReaderStatusFooter)).height,
          kReaderStatusFooterHeight);
    });

    testWidgets('the toggle stays out of the focus ring',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(
        totals: () => (durationMs: 0, chars: 0, active: true),
        onTapTracker: () {},
      ));
      // TODO-700：状态行是纯指针面。裸 IconButton 默认可聚焦，不排除就会往 Tab 环
      // 里塞一个不受 FushiFocusController 管的节点。
      final Focus focus = tester.widget<Focus>(find
          .descendant(
            of: find.byType(ReaderStudyClockButton),
            matching: find.byType(Focus),
          )
          .first);
      expect(focus.canRequestFocus, isFalse);
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

    testWidgets('tracker hidden by its own switch, progress keeps its place',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(
        totals: () => (durationMs: 61000, chars: 100, active: true),
        showTimer: false,
      ));
      expect(find.byKey(const ValueKey<String>('fushi_status_tracker')),
          findsNothing);
      expect(find.byType(ReaderStudyClockButton), findsNothing,
          reason: '计时开关键与读数一起隐藏');
      final Finder progress =
          find.byKey(const ValueKey<String>('fushi_status_progress'));
      expect(progress, findsOneWidget);
      final Rect strip = tester.getRect(find.byType(ReaderStatusFooter));
      expect(strip.height, kReaderStatusFooterHeight,
          reason: '行还在（进度还开着），高度不变');
      expect(strip.right - tester.getRect(progress).right, closeTo(16, 0.5),
          reason: '进度仍贴右缘 16');

      // 秒表 tick 不再重建这一层：读数隐藏后没有随秒变化的内容。
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.takeException(), isNull);
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

    testWidgets('320px footer keeps long counts inside and actions accessible',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      int trackerTaps = 0;
      int progressTaps = 0;
      await tester.pumpWidget(host(
        totals: () => (durationMs: 360000000, chars: 999999999, active: true),
        current: 123456789,
        total: 999999999,
        onTapTracker: () => trackerTaps++,
        onTapProgress: () => progressTaps++,
      ));

      expect(tester.takeException(), isNull);
      final Rect footer = tester.getRect(find.byType(ReaderStatusFooter));
      final Finder tracker =
          find.byKey(const ValueKey<String>('fushi_status_tracker'));
      final Finder progress =
          find.byKey(const ValueKey<String>('fushi_status_progress'));
      expect(tester.getRect(tracker).left, greaterThanOrEqualTo(footer.left));
      expect(tester.getRect(progress).right, lessThanOrEqualTo(footer.right));
      expect(tester.getRect(tracker).right,
          lessThan(tester.getRect(progress).left));
      expect(footer.height, kReaderStatusFooterHeight);
      await tester.tap(tracker);
      await tester.tap(progress);
      expect(trackerTaps, 1);
      expect(progressTaps, 1);
    });

    // 追踪块此前钉在左下角、进度在右下角，底部读数被劈成两个角；播放条一唤出
    // （ReaderStatusInline）同一串数字又整体飞到右端。两段现在并排贴右，与 inline
    // 同序：计时块在左、进度在右。
    testWidgets('tracker and progress sit together at the right end',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        host(totals: () => (durationMs: 0, chars: 0, active: true)),
      );
      final Rect strip = tester.getRect(find.byType(ReaderStatusFooter));
      final Rect tracker = tester
          .getRect(find.byKey(const ValueKey<String>('fushi_status_tracker')));
      final Rect progress = tester
          .getRect(find.byKey(const ValueKey<String>('fushi_status_progress')));
      // 进度段 = 短进度条 + 百分比；与计时块的间距量到进度条左缘。
      final Rect track = tester.getRect(
          find.byKey(const ValueKey<String>('fushi_status_progress_track')));

      expect(tracker.right, lessThanOrEqualTo(track.left),
          reason: '与 inline 形态同序：计时块在进度左边');
      // 判据是「两段挨在一起」而不是「都在右半边」——两段文字合起来本就可能超过半屏。
      expect(track.left - tracker.right, lessThanOrEqualTo(24),
          reason: '两段之间只隔一个间距，不再被撑成左右两角');
      expect(strip.right - progress.right, closeTo(16, 0.5),
          reason: '右端内边距仍是 16，进度贴着右缘');
      expect(tracker.left - strip.left, greaterThan(32),
          reason: '左端留白（点它唤出 / 收起 chrome），计时块不再钉在左下角');
    });

    testWidgets('centered: 读数并进底栏那块遮罩时居中，不再贴右角', (WidgetTester tester) async {
      // 竖屏读数独立成行时它是底栏 Column 的最后一行，上面一排传输键是居中的；
      // 读数贴在右角会和它们错开成两个重心（用户 2026-09-14「竖屏做到最底部
      // 并且居中」）。
      await tester.pumpWidget(host(
        totals: () => (durationMs: 0, chars: 0, active: true),
        centered: true,
      ));
      final Rect strip = tester.getRect(find.byType(ReaderStatusFooter));
      final Rect tracker = tester
          .getRect(find.byKey(const ValueKey<String>('fushi_status_tracker')));
      final Rect progress = tester
          .getRect(find.byKey(const ValueKey<String>('fushi_status_progress')));

      // 两段读数合起来的中点落在整条的中点上（内边距左右对称）。左边界要量到
      // 计时器**按钮**（BUG-2533 起它是 [ReaderStudyClockButton]，不再是那枚纯装饰
      // 的秒表字形）：计时文字左边还有按钮 + 间距，拿文字左缘算会偏出去。
      final Rect clock = tester.getRect(find.byType(ReaderStudyClockButton));
      expect((clock.left + progress.right) / 2, closeTo(strip.center.dx, 1));
      expect(clock.left, lessThan(tracker.left));
      expect(strip.right - progress.right, greaterThan(16),
          reason: '不再贴右缘 16 的基线——那是它独自在屏底时的形态');
      // 顺序不变：计时块仍在进度左边（与 inline 形态同序）。
      final Rect track = tester.getRect(
          find.byKey(const ValueKey<String>('fushi_status_progress_track')));
      expect(tracker.right, lessThanOrEqualTo(track.left));
    });

    testWidgets('tracker hit box spans the full strip height',
        (WidgetTester tester) async {
      int trackerTaps = 0;
      await tester.pumpWidget(
        host(
          totals: () => (durationMs: 0, chars: 0, active: true),
          onTapTracker: () => trackerTaps++,
        ),
      );
      final Rect strip = tester.getRect(find.byType(ReaderStatusFooter));
      final Rect tracker = tester
          .getRect(find.byKey(const ValueKey<String>('fushi_status_tracker')));

      // 裸文字行盒只有十几 px 高；命中区撑满整条 28px 后，贴着行顶 / 行底也点得中。
      await tester.tapAt(Offset(tracker.center.dx, strip.top + 2));
      await tester.tapAt(Offset(tracker.center.dx, strip.bottom - 2));
      expect(trackerTaps, 2, reason: '计时块命中区要撑满整条行高，不是只有那一行文字');
    });
  });

  // 播放条唤出后状态行整条让位（BUG-2467），底部那份读数就只剩内联形态——此前它
  // **整块不接指针**：屏幕上写着「计时中」的那颗图标点一百下也不会停表。
  group('inline', () {
    Widget host({
      required StudySessionTotals Function() totals,
      bool showTimer = true,
      bool showProgress = true,
      VoidCallback? onToggleTimer,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              height: 56,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  ReaderStatusInline(
                    sessionTotals: totals,
                    currentChars: 64988,
                    totalChars: 123962,
                    showTimer: showTimer,
                    showProgress: showProgress,
                    textColor: Colors.white,
                    onToggleTimer: onToggleTimer,
                    tick: const Duration(milliseconds: 100),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('the clock icon toggles the timer from the playback bar',
        (WidgetTester tester) async {
      int taps = 0;
      bool active = true;
      await tester.pumpWidget(host(
        totals: () => (durationMs: 0, chars: 0, active: active),
        onToggleTimer: () => taps++,
      ));
      expect(find.text('0:00'), findsOneWidget);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

      await tester.tap(find.byType(ReaderStudyClockButton));
      await tester.pump();
      expect(taps, 1, reason: '播放条里的那颗计时图标必须真的可点');

      active = false;
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('the toggle hides with the timer switch',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(
        totals: () => (durationMs: 0, chars: 0, active: true),
        showTimer: false,
        onToggleTimer: () {},
      ));
      expect(find.byType(ReaderStudyClockButton), findsNothing);
      expect(find.byKey(const ValueKey<String>('fushi_bar_status_tracker')),
          findsNothing);
      expect(find.byType(ReaderStatusProgressTrack), findsOneWidget,
          reason: '进度段与计时段互不连带');
    });
  });

  group('source-scan guards', () {
    final String src = readReaderPageSource();

    test('footer reserve is part of _readerBottomReserve (single source)', () {
      expect(
        src.contains(
          '_readerBottomReserve => _bottomChromeReserve + _statusFooterBand;',
        ),
        isTrue,
        reason: '状态行是挤压式：预留必须与底栏 / 系统 inset 同源进 WebView / 焦点环',
      );
      // BUG-2470：状态行与系统底 inset 取大而不是相加——单一真相源在纯函数里。
      expect(
        src.contains('_statusFooterBand => readerStatusFooterBandHeight('),
        isTrue,
        reason: '状态行坐进系统底部安全区：带高 = max(预留, inset)，不再叠加',
      );
      expect(
        src.contains('_stableBottomInset + (_separatePlaybackStatus'),
        isFalse,
        reason: '状态行不再画在系统 inset 之上（旧 _statusFooterBottomOffset）',
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

    test(
        'footer yields to the squeeze bar that already carries its numbers '
        '(BUG-2467)', () {
      // 预留与绘制两处都走同一个吸收判据，否则又回到「预留 28px 却画在底栏后面」
      // 或「不预留却画出来压正文」。
      expect(
        src.contains('absorbedByBar: _statusFooterAbsorbedByBar,'),
        isTrue,
        reason: '状态行预留必须受吸收判据门控',
      );
      expect(
        src.contains(
            '_statusFooterAbsorbedByBar => readerStatusFooterAbsorbedByBar('),
        isTrue,
      );
      final String footerBuild = _slice(
        src,
        '  Widget _buildStatusFooter() {',
        '    return Positioned(',
      );
      expect(
        footerBuild.contains('_statusFooterShouldPaint'),
        isTrue,
        reason: '绘制门控走单一真相源 readerStatusFooterVisible',
      );
      final String shouldPaint = _slice(
        src,
        '  bool get _statusFooterShouldPaint => readerStatusFooterVisible(',
        '  double get _statusFooterPaintedBand',
      );
      expect(
        shouldPaint.contains('absorbedByBar: _statusFooterAbsorbedByBar,'),
        isTrue,
        reason: '底栏已并入读数时状态行整条不画（不再叠两行同样的数字）',
      );
      expect(
        shouldPaint.contains('transientVisible: _chromeTransientVisible,'),
        isTrue,
        reason: '悬浮态状态行随控制栏唤出 / 收起',
      );
      final String barBuild = _slice(
        src,
        '  Widget _buildAudiobookBar() {',
        '  /// 小说页的窗口全屏切换',
      );
      // 播放条右端 = 底栏槽位按钮 + 状态读数（_buildAudiobookBarTrailing）。
      expect(
        barBuild.contains('trailing: _buildAudiobookBarTrailing(),'),
        isTrue,
      );
      final String trailing = _slice(
        src,
        '  Widget? _buildAudiobookBarTrailing() {',
        '  /// 小说页的窗口全屏切换',
      );
      expect(
        trailing
            .contains('_playbackStatusInline ? _buildBarStatusText() : null'),
        isTrue,
        reason: '底栏右端仍是读数的唯一落点',
      );
    });

    test('footer replaces the top progress pill on every platform', () {
      final String showTop = _slice(
        src,
        '  bool get _showTopProgress =>',
        '  bool get _statusFooterEnabled',
      );
      expect(showTop.contains('!_statusFooterEnabled &&'), isTrue,
          reason: '各平台进度数字统一挪到右下角');
      final String anyFloating = _slice(
        src,
        '  bool get _anyChromeFloating =>',
        // 结束锚点用结构（下一个 getter 定义），不用某条注释：BUG-1343 那段
        // macOS 拖拽带的文档注释已随该功能删除。
        '  double get _readerTopOffset =>',
      );
      expect(
        anyFloating.contains('(_topProgressFloating && !_statusFooterEnabled)'),
        isTrue,
        reason: '顶部进度没有可见面，其悬浮开关不得再驱动「点空白唤出」状态机',
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
      expect(
        _slice(
          src,
          '  bool get _statusFooterShouldPaint => readerStatusFooterVisible(',
          '  double get _statusFooterPaintedBand',
        ).contains('hasEverLoaded: _hasEverLoaded,'),
        isTrue,
        reason: '绘制门控与底栏同源用 set-once _hasEverLoaded（切章不闪烁）',
      );
      expect(build.contains('_readerContentReady'), isFalse);
      expect(
        build.contains('bottom: 0,'),
        isTrue,
        reason: 'BUG-2470：状态行贴屏底、整条带坐进系统底部安全区；'
            '挤压态窄屏是底栏坐到它上面（_wrapBottomChromeBar），不是它往上挪',
      );
      expect(
        build.contains('bottomInset: _stableBottomInset,'),
        isTrue,
        reason: '带高 = max(行高, 系统底 inset) 由组件按 bottomInset 画',
      );
      expect(build.contains('Focus(') || build.contains('canRequestFocus'),
          isFalse,
          reason: '纯指针面，不进焦点遍历池（TODO-700 不变式）');
      // 钉「先后」而不是「两行相邻」：相邻只是当时的偶然事实，不是不变式。
      // 任何排在两者之间的新层（如有声书悬浮球）都不该让这条无理由地红，
      // 真正要守的是「状态行在词典弹层之前绘制」这个顺序。
      final int footerAt = src.indexOf('_buildStatusFooter(),');
      final int dictAt = src.indexOf('buildDictionary(),');
      expect(footerAt, isNonNegative, reason: '状态行不再挂在页面 Stack 上了，守卫需同步更新');
      expect(
        dictAt,
        greaterThan(footerAt),
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

    test('settings: obsolete top-progress placement controls removed', () {
      final String schema =
          File('lib/src/settings/settings_schema_reading.dart')
              .readAsStringSync()
              .replaceAll('\r\n', '\n');
      expect(
        schema.contains("id: 'reading_controls.top_progress_floating'"),
        isFalse,
        reason: '各平台统一用底部进度，不再展示悬浮阅读进度开关',
      );
      expect(
        schema.contains("id: 'reading_controls.top_progress_position'"),
        isFalse,
      );
      expect(
        schema.contains('c.readerSource.topProgressFloating'),
        isFalse,
        reason: '自动收起时长的可见条件不再读取已移除的顶部进度悬浮开关',
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
