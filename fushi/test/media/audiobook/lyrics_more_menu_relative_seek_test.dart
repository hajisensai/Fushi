import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_control_layout.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show kLyricsOverlayMenuItems, lyricsOverlayMenuItems;
import 'package:fushi/src/reader/reader_control_layout.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 MnVAGO_nry：歌词覆盖层 ⋯ 菜单里的「后退 / 前进 10 秒」与播放器上的 ±10
/// 键重复。⋯ 的锚点如实报告「此刻屏上有没有 ±10 键」，页面据此去重；没有 ±10 键
/// 的形态（经典 Apple、新版窄屏收起的迷你条）菜单照列，触屏仍有入口。
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
  group('lyricsOverlayMenuItems', () {
    const Set<ReaderControlItem> seek = <ReaderControlItem>{
      ReaderControlItem.audiobookSeekBack,
      ReaderControlItem.audiobookSeekForward,
    };

    test('drops ±10s when the player shows them', () {
      final List<ReaderControlItem> items = lyricsOverlayMenuItems(
        relativeSeekOnScreen: true,
      );
      expect(items.where(seek.contains), isEmpty);
      expect(items, <ReaderControlItem>[
        for (final ReaderControlItem i in kLyricsOverlayMenuItems)
          if (!seek.contains(i)) i,
      ]);
    });

    test('keeps ±10s when the player has none on screen', () {
      expect(
        lyricsOverlayMenuItems(relativeSeekOnScreen: false),
        kLyricsOverlayMenuItems,
      );
      expect(kLyricsOverlayMenuItems, containsAll(seek));
    });
  });

  group('⋯ anchor reports on-screen ±10s', () {
    late List<LyricsMenuAnchor> anchors;

    LyricsPlayerCallbacks callbacks() => LyricsPlayerCallbacks(
      onClose: () {},
      onExitBook: () {},
      onPlayPause: () {},
      onPreviousCue: () {},
      onNextCue: () {},
      onSeek: (_) {},
      onToggleMask: () {},
      onOpenStatistics: () {},
      onSpeedChanged: (_) {},
      onMore: anchors.add,
      onTapBackground: () {},
      onSeekRelative: (_) {},
      onReplayCue: () {},
      onToggleStatsTimer: () {},
      onTypography: (_) {},
      onSwapSides: () {},
      onCompactControlsExpandedChanged: (_) {},
    );

    Widget app({
      required bool apple,
      required LyricsControlsStyle style,
      required bool expanded,
    }) => MaterialApp(
      theme: apple ? _appleTheme() : null,
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: ReaderLyricsPlayerOverlay(
          lyricsView: const SizedBox.expand(),
          data: LyricsPlayerData(
            title: 'book',
            chapterLabel: '第四章　聖歌',
            cover: null,
            isPlaying: false,
            speed: 1,
            lyricsMasked: false,
            clock: _Clock(),
            controlsStyle: style,
            compactControlsExpanded: expanded,
          ),
          callbacks: callbacks(),
          onHtmlThemeChanged: (_) {},
        ),
      ),
    );

    setUp(() => anchors = <LyricsMenuAnchor>[]);

    Finder key(String k) => find.byKey(ValueKey<String>(k)).hitTestable();

    Future<void> pumpAt(WidgetTester tester, Size size, Widget widget) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(widget);
      await tester.pump(const Duration(seconds: 1));
    }

    /// 按 ⋯，返回锚点；该形态屏上没有 ⋯ 时返回 null。
    Future<LyricsMenuAnchor?> tapMore(WidgetTester tester) async {
      final Finder more = key('lyrics_more_button');
      if (more.evaluate().isEmpty) return null;
      await tester.tap(more.last);
      await tester.pump();
      expect(anchors, hasLength(1));
      return anchors.single;
    }

    const List<Size> sizes = <Size>[Size(400, 860), Size(1600, 900)];
    for (final bool apple in <bool>[false, true]) {
      for (final LyricsControlsStyle style in LyricsControlsStyle.values) {
        for (final Size size in sizes) {
          for (final bool expanded in <bool>[false, true]) {
            final String name =
                '${apple ? 'apple' : 'md3'} ${style.name} '
                '${size.width.toInt()}x${size.height.toInt()} '
                '${expanded ? 'expanded' : 'collapsed'}';
            testWidgets('$name: anchor matches the visible ±10s keys', (
              WidgetTester tester,
            ) async {
              await pumpAt(
                tester,
                size,
                app(apple: apple, style: style, expanded: expanded),
              );
              final bool seekVisible =
                  key('lyrics_seek_back_button').evaluate().isNotEmpty &&
                  key('lyrics_seek_forward_button').evaluate().isNotEmpty;
              final LyricsMenuAnchor? anchor = await tapMore(tester);
              if (anchor == null) {
                // 只有 MD3 新版窄屏收起的迷你条没有 ⋯（展开卡才有）。
                expect(
                  !apple &&
                      style == LyricsControlsStyle.modern &&
                      size.width < 600 &&
                      !expanded,
                  isTrue,
                  reason: '$name: ⋯ missing',
                );
                return;
              }
              expect(anchor.relativeSeekOnScreen, seekVisible);
            });
          }
        }
      }
    }

    testWidgets('md3 modern narrow expanded card (the reported layout) '
        'dedupes', (WidgetTester tester) async {
      await pumpAt(
        tester,
        const Size(400, 860),
        app(apple: false, style: LyricsControlsStyle.modern, expanded: true),
      );
      expect(key('lyrics_seek_back_button'), findsOneWidget);
      final LyricsMenuAnchor? anchor = await tapMore(tester);
      expect(anchor?.relativeSeekOnScreen, isTrue);
    });

    testWidgets('apple modern narrow mini bar keeps ±10s in the menu', (
      WidgetTester tester,
    ) async {
      await pumpAt(
        tester,
        const Size(400, 860),
        app(apple: true, style: LyricsControlsStyle.modern, expanded: false),
      );
      expect(key('lyrics_seek_back_button'), findsNothing);
      final LyricsMenuAnchor? anchor = await tapMore(tester);
      expect(anchor?.relativeSeekOnScreen, isFalse);
    });

    testWidgets('apple classic has no ±10s keys and keeps them in the menu', (
      WidgetTester tester,
    ) async {
      await pumpAt(
        tester,
        const Size(400, 860),
        app(apple: true, style: LyricsControlsStyle.classic, expanded: false),
      );
      expect(key('lyrics_seek_back_button'), findsNothing);
      final LyricsMenuAnchor? anchor = await tapMore(tester);
      expect(anchor?.relativeSeekOnScreen, isFalse);
    });
  });
}
