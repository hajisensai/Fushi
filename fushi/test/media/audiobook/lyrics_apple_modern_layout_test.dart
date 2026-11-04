import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_control_layout.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiExpressivePlayButton, FushiWavySeekBar;
import 'package:material_ui/material_ui.dart';

/// 歌词模式 Apple 设计系统的新版播放控件（与 MD3 新版同一布局 / 交互，视觉换成
/// Apple 的件）：
///  * 宽屏：关闭键在底部右侧动作岛，正文横向占满，放不下的动作按优先级收进 ⋯，
///    播放中底栏空闲自动隐藏、只认底边带子唤出；
///  * 窄屏：可收起的迷你条 / 展开卡；
///  * 偏好 `lyrics_controls_style` 在 Apple 下也生效，经典布局仍可切回。
class _Clock implements LyricsPlayerClock {
  @override
  Duration get position => const Duration(minutes: 3);

  @override
  Duration get duration => const Duration(minutes: 10);

  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

ThemeData _appleTheme() => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
  textTheme: Typography.material2021().black,
  glass: FushiGlassMaterial.frosted,
  glassDesign: true,
).copyWith(platform: TargetPlatform.windows);

void main() {
  late List<Object> calls;

  LyricsPlayerCallbacks callbacks() => LyricsPlayerCallbacks(
    onClose: () => calls.add('close'),
    onExitBook: () => calls.add('exit'),
    onPlayPause: () {},
    onPreviousCue: () {},
    onNextCue: () {},
    onSeek: (_) {},
    onToggleMask: () {},
    onOpenStatistics: () {},
    onSpeedChanged: (_) {},
    onMore: (LyricsMenuAnchor anchor) => calls.add(anchor.collapsedItems),
    onTapBackground: () {},
    onSeekRelative: (_) {},
    onReplayCue: () {},
    onToggleStatsTimer: () {},
    onTypography: (_) {},
    onSwapSides: () => calls.add('swap'),
    onCompactControlsExpandedChanged: (bool v) => calls.add('expanded:$v'),
  );

  Widget app({
    LyricsControlsStyle style = LyricsControlsStyle.modern,
    bool expanded = false,
    bool playing = false,
  }) => MaterialApp(
    theme: _appleTheme(),
    themeAnimationDuration: Duration.zero,
    home: Scaffold(
      body: Builder(
        builder: (BuildContext context) {
          // 前提：确实走的是 Apple 设计系统。
          expect(isGlassDesign(context), isTrue);
          return ReaderLyricsPlayerOverlay(
            lyricsView: const SizedBox.expand(
              key: ValueKey<String>('lyrics_view_probe'),
            ),
            data: LyricsPlayerData(
              title: 'book',
              chapterLabel: '第四章　聖歌',
              cover: null,
              isPlaying: playing,
              speed: 1,
              lyricsMasked: false,
              clock: _Clock(),
              controlsStyle: style,
              compactControlsExpanded: expanded,
            ),
            callbacks: callbacks(),
            onHtmlThemeChanged: (_) {},
          );
        },
      ),
    ),
  );

  Future<void> pumpAt(WidgetTester tester, Size size, Widget widget) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    await tester.pump(const Duration(seconds: 1));
  }

  Finder key(String k) => find.byKey(ValueKey<String>(k));

  setUp(() => calls = <Object>[]);

  group('apple modern wide', () {
    testWidgets('close lives in the bottom-right island, lyrics span the '
        'width, no swap; play key keeps the Apple glyph (no polygon)', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(1600, 900), app());
      final Rect close = tester.getRect(key('lyrics_close_button'));
      expect(close.center.dy, greaterThan(900 * 0.8));
      expect(close.center.dx, greaterThan(1600 * 0.8));
      expect(key('lyrics_swap_sides_button'), findsNothing);
      expect(key('lyrics_return_to_book_button'), findsOneWidget);
      // 正文横向占满（左右各 40 外边距），在进度线 / 浮岛之上。
      final Rect lyrics = tester.getRect(key('lyrics_view_probe'));
      expect(lyrics.left, closeTo(40, 0.5));
      expect(lyrics.right, closeTo(1560, 0.5));
      expect(lyrics.bottom, lessThan(close.top));
      // 主控：±10 秒 / 上一句 / 播放 / 下一句，播放键更大、不是多边形。
      for (final String k in <String>[
        'lyrics_seek_back_button',
        'lyrics_previous_cue_button',
        'lyrics_next_cue_button',
        'lyrics_seek_forward_button',
      ]) {
        expect(tester.getSize(key(k)).width, closeTo(52, 0.5), reason: k);
      }
      expect(tester.getSize(key('lyrics_play_button')).width, closeTo(64, 0.5));
      expect(find.byType(FushiExpressivePlayButton), findsNothing);
      expect(find.byType(FushiWavySeekBar), findsNothing);
      // 读数一行在进度线上方。
      expect(key('lyrics_modern_stats_line'), findsOneWidget);
      // 1600 宽全部平铺：⋯ 不带收起项。
      await tester.tap(key('lyrics_more_button'));
      expect(calls.last, isEmpty);
      await tester.tap(key('lyrics_close_button'));
      expect(calls.last, 'exit');
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow window collapses low-priority actions into ⋯', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(900, 700), app());
      expect(tester.takeException(), isNull);
      await tester.tap(key('lyrics_more_button'));
      final Object collapsed = calls.last;
      expect(collapsed, isA<List<LyricsControlItem>>());
      final List<LyricsControlItem> items =
          collapsed as List<LyricsControlItem>;
      expect(items, isNotEmpty);
      // 倍速是最高优先级，永远不收。
      expect(items, isNot(contains(LyricsControlItem.speed)));
      expect(find.text('1.0×'), findsOneWidget);
      if (items.contains(LyricsControlItem.statistics)) {
        expect(key('lyrics_statistics_button'), findsNothing);
      }
    });

    double chromeOpacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.text('book'),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        )
        .opacity;

    Future<void> idleUntilHidden(WidgetTester tester) async {
      await tester.pump(kLyricsChromeIdleHideDelay);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('playing: bottom chrome auto-hides and lyrics extend; only '
        'the bottom edge band or Tab brings it back', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(1600, 900), app(playing: true));
      final Rect shown = tester.getRect(key('lyrics_view_probe'));
      expect(chromeOpacity(tester), 1);

      await idleUntilHidden(tester);
      expect(chromeOpacity(tester), 0);
      final Rect hidden = tester.getRect(key('lyrics_view_probe'));
      expect(hidden.top, shown.top);
      expect(hidden.bottom, closeTo(900 - 24, 0.5));
      expect(key('lyrics_modern_immersive_progress'), findsOneWidget);
      // 隐藏时看不见的钮不吃点击。
      await tester.tap(key('lyrics_close_button'), warnIfMissed: false);
      await tester.pump();
      expect(calls, isNot(contains('exit')));
      expect(chromeOpacity(tester), 0);

      // 正文上移动 / 点击不唤出、歌词矩形不变。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(800, 300));
      await mouse.moveTo(const Offset(820, 320));
      await tester.pump();
      await tester.tapAt(const Offset(820, 320));
      await tester.pump();
      expect(chromeOpacity(tester), 0);
      expect(tester.getRect(key('lyrics_view_probe')), hidden);

      // 移到底边带子 → 唤出，歌词矩形复位。
      await mouse.moveTo(const Offset(800, 890));
      await tester.pump();
      expect(chromeOpacity(tester), 1);
      expect(tester.getRect(key('lyrics_view_probe')), shown);

      // 回到正文上，空闲后照常隐藏；Tab 唤出。
      await mouse.moveTo(const Offset(800, 300));
      await idleUntilHidden(tester);
      expect(chromeOpacity(tester), 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(chromeOpacity(tester), 1);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    });

    testWidgets('paused: bottom chrome never auto-hides', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(1600, 900), app());
      final Rect shown = tester.getRect(key('lyrics_view_probe'));
      await tester.pump(kLyricsChromeIdleHideDelay * 3);
      expect(chromeOpacity(tester), 1);
      expect(tester.getRect(key('lyrics_view_probe')), shown);
    });

    testWidgets('classic style still switches back to the Apple two-column '
        'layout (corner close, side swap), and never auto-hides', (
      WidgetTester tester,
    ) async {
      await pumpAt(
        tester,
        const Size(1600, 900),
        app(style: LyricsControlsStyle.classic, playing: true),
      );
      expect(key('lyrics_swap_sides_button'), findsOneWidget);
      expect(key('lyrics_modern_stats_line'), findsNothing);
      final Rect close = tester.getRect(key('lyrics_close_button'));
      expect(close.center.dy, lessThan(900 * 0.2));
      final Rect lyrics = tester.getRect(key('lyrics_view_probe'));
      await tester.pump(kLyricsChromeIdleHideDelay * 3);
      expect(tester.getRect(key('lyrics_view_probe')), lyrics);
      expect(tester.takeException(), isNull);
    });
  });

  group('apple modern narrow', () {
    testWidgets('collapsed by default: mini bar, expand via grab handle / '
        'chapter area; ⋯ stays reachable in the header', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(390, 844), app());
      expect(key('lyrics_modern_card'), findsOneWidget);
      expect(key('lyrics_modern_mini_info'), findsOneWidget);
      expect(key('lyrics_replay_cue_button'), findsOneWidget);
      expect(key('lyrics_play_button'), findsOneWidget);
      expect(key('lyrics_seek_back_button'), findsNothing);
      expect(key('lyrics_more_button'), findsOneWidget);
      expect(key('lyrics_player_back'), findsOneWidget);
      final Rect card = tester.getRect(key('lyrics_modern_card'));
      final Rect lyrics = tester.getRect(key('lyrics_view_probe'));
      expect(lyrics.bottom, lessThan(card.top));
      await tester.tap(key('lyrics_modern_grab_handle'));
      await tester.tap(key('lyrics_modern_mini_info'));
      expect(calls, <Object>['expanded:true', 'expanded:true']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('expanded: five transport keys, lyrics rect yields to the '
        'taller card; swipe down collapses', (WidgetTester tester) async {
      await pumpAt(tester, const Size(390, 844), app());
      final Rect collapsedCard = tester.getRect(key('lyrics_modern_card'));
      final Rect collapsedLyrics = tester.getRect(key('lyrics_view_probe'));
      await pumpAt(tester, const Size(390, 844), app(expanded: true));
      final Rect card = tester.getRect(key('lyrics_modern_card'));
      final Rect lyrics = tester.getRect(key('lyrics_view_probe'));
      for (final String k in <String>[
        'lyrics_seek_back_button',
        'lyrics_previous_cue_button',
        'lyrics_play_button',
        'lyrics_next_cue_button',
        'lyrics_seek_forward_button',
      ]) {
        expect(key(k), findsOneWidget, reason: k);
      }
      expect(card.height, greaterThan(collapsedCard.height));
      expect(card.bottom, closeTo(collapsedCard.bottom, 0.5));
      expect(
        collapsedLyrics.bottom - lyrics.bottom,
        closeTo(card.height - collapsedCard.height, 0.5),
      );
      await tester.drag(key('lyrics_modern_card'), const Offset(0, 80));
      expect(calls, contains('expanded:false'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('360 wide mini bar and expanded card do not overflow', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(360, 780), app());
      expect(tester.takeException(), isNull);
      await pumpAt(tester, const Size(360, 780), app(expanded: true));
      expect(tester.takeException(), isNull);
    });
  });
}
