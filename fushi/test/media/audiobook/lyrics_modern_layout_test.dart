import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_control_layout.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_illustration_view.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_illustrations.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_modern_shared.dart'
    show lyricsSessionText;
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:material_ui/material_ui.dart';

/// 歌词模式 MD3 新版播放控件（2026-10-31 用户拍板，设计稿 layout_v3）：
///  * 窄屏：默认收起成迷你条，把手 / 章名时间区 / 上滑展开，展开后五颗统一 48 的
///    主控钮；歌词矩形随目标态让位；
///  * 宽屏：三浮岛，关闭键在底部右岛、不再在右上角，没有「左右互换」，放不下的
///    动作按优先级收进 ⋯ 并交给页面；
///  * 经典布局原样保留，可切回；
///  * 插图：「弹出停留 / 红点」两种提示方式的状态机，竖排书翻页方向镜像；
///  * 宽屏底栏常驻（播放中闲置再久也不收起），读数一行在宽 / 窄屏都看得见。
class _Clock implements LyricsPlayerClock {
  @override
  Duration get position => const Duration(minutes: 3);

  @override
  Duration get duration => const Duration(minutes: 10);

  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

/// 1×1 内存图（插图卡测试用）。
Future<ImageProvider> _image(WidgetTester tester) async {
  late ImageProvider provider;
  await tester.runAsync(() async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 4, 6),
      Paint()..color = const Color(0xFF336699),
    );
    final ui.Image image = await recorder.endRecording().toImage(4, 6);
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    provider = MemoryImage(bytes!.buffer.asUint8List());
  });
  return provider;
}

/// 读数一行（阅读速度 · 进度 · 时间）真的看得见：在窗口里、有尺寸、没被缩成一条线，
/// 祖先里没有透明度为 0 的层。
void _expectStatsVisible(WidgetTester tester, Finder stat) {
  expect(stat, findsOneWidget);
  final Rect rect = tester.getRect(stat);
  final Rect window = Offset.zero & tester.view.physicalSize;
  expect(
    window.contains(rect.topLeft) && window.contains(rect.bottomRight),
    isTrue,
    reason: '$rect 不在窗口 $window 内',
  );
  expect(rect.height, greaterThan(8));
  expect(rect.width, greaterThan(40));
  for (final Opacity o in tester.widgetList<Opacity>(
    find.ancestor(of: stat, matching: find.byType(Opacity)),
  )) {
    expect(o.opacity, greaterThan(0));
  }
  for (final AnimatedOpacity o in tester.widgetList<AnimatedOpacity>(
    find.ancestor(of: stat, matching: find.byType(AnimatedOpacity)),
  )) {
    expect(o.opacity, greaterThan(0));
  }
}

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
    bool heldForLookup = false,
    ValueChanged<Rect>? onLyricsRect,
    LyricsPlayerClock? clock,
  }) => MaterialApp(
    home: Scaffold(
      body: ReaderLyricsPlayerOverlay(
        lyricsView: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            return const SizedBox.expand(
              key: ValueKey<String>('lyrics_view_probe'),
            );
          },
        ),
        data: LyricsPlayerData(
          title: 'book',
          chapterLabel: '第四章　聖歌',
          cover: null,
          isPlaying: playing,
          playbackHeldForLookup: heldForLookup,
          speed: 1,
          lyricsMasked: false,
          clock: clock ?? _Clock(),
          controlsStyle: style,
          compactControlsExpanded: expanded,
        ),
        callbacks: callbacks(),
        onHtmlThemeChanged: (_) {},
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

  group('pref wire values', () {
    test('controls style defaults to modern, unknown falls back', () {
      expect(LyricsControlsStyle.fromWire(null), LyricsControlsStyle.modern);
      expect(LyricsControlsStyle.fromWire(''), LyricsControlsStyle.modern);
      expect(
        LyricsControlsStyle.fromWire('classic'),
        LyricsControlsStyle.classic,
      );
      expect(
        const LyricsPlayerData(
          title: '',
          cover: null,
          isPlaying: false,
          speed: 1,
          lyricsMasked: false,
          clock: _ConstClock(),
        ).controlsStyle,
        LyricsControlsStyle.modern,
      );
    });

    test('illustration cue defaults to popup', () {
      expect(LyricsIllustrationCue.fromWire(null), LyricsIllustrationCue.popup);
      expect(LyricsIllustrationCue.fromWire('dot'), LyricsIllustrationCue.dot);
    });
  });

  group('narrow modern card', () {
    testWidgets('collapsed by default: mini bar, expand via grab handle', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(390, 844), app());
      expect(key('lyrics_modern_mini_info'), findsOneWidget);
      // 迷你条：重播 / 上一句 / 播放 / 下一句，没有 ±10 秒。
      expect(key('lyrics_replay_cue_button'), findsOneWidget);
      expect(key('lyrics_play_button'), findsOneWidget);
      expect(key('lyrics_seek_back_button'), findsNothing);
      final Rect card = tester.getRect(key('lyrics_modern_card'));
      expect(card.height, closeTo(64, 0.5));
      await tester.tap(key('lyrics_modern_grab_handle'));
      await tester.tap(key('lyrics_modern_mini_info'));
      expect(calls, <Object>['expanded:true', 'expanded:true']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('expanded: five 48dp transport buttons, ~160dp card', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(390, 844), app(expanded: true));
      final Rect card = tester.getRect(key('lyrics_modern_card'));
      expect(card.height, closeTo(160, 0.5));
      for (final String k in <String>[
        'lyrics_seek_back_button',
        'lyrics_previous_cue_button',
        'lyrics_play_button',
        'lyrics_next_cue_button',
        'lyrics_seek_forward_button',
      ]) {
        final Size s = tester.getSize(key(k));
        expect(s.width, closeTo(48, 0.5), reason: k);
        expect(s.height, closeTo(48, 0.5), reason: k);
      }
      await tester.tap(key('lyrics_modern_grab_handle'));
      expect(calls, <Object>['expanded:false']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('swipe up expands, lyrics rect follows the target state', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(390, 844), app());
      final Rect collapsedLyrics = tester.getRect(key('lyrics_view_probe'));
      await tester.drag(key('lyrics_modern_card'), const Offset(0, -80));
      expect(calls, contains('expanded:true'));
      await pumpAt(tester, const Size(390, 844), app(expanded: true));
      final Rect expandedLyrics = tester.getRect(key('lyrics_view_probe'));
      // 卡片从 64 长到 160：歌词底边让出 96。
      expect(collapsedLyrics.bottom - expandedLyrics.bottom, closeTo(96, 0.5));
      expect(
        tester.getRect(key('lyrics_modern_card')).top,
        greaterThan(expandedLyrics.bottom),
      );
    });

    testWidgets('reading stats (speed · progress · time) show in the header '
        '(collapsed and expanded)', (WidgetTester tester) async {
      final Finder stats = find.textContaining(
        lyricsSessionText(LyricsPlayerStats.empty),
      );
      await pumpAt(tester, const Size(390, 844), app());
      _expectStatsVisible(tester, stats);
      await pumpAt(tester, const Size(390, 844), app(expanded: true));
      _expectStatsVisible(tester, stats);
    });

    testWidgets('360 wide collapsed bar does not overflow', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(360, 780), app());
      expect(tester.takeException(), isNull);
      await pumpAt(tester, const Size(360, 780), app(expanded: true));
      expect(tester.takeException(), isNull);
    });
  });

  group('wide modern islands', () {
    testWidgets('close lives in the bottom island, no swap button', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(1600, 900), app());
      final Rect close = tester.getRect(key('lyrics_close_button'));
      expect(close.center.dy, greaterThan(900 * 0.8));
      expect(key('lyrics_swap_sides_button'), findsNothing);
      expect(key('lyrics_return_to_book_button'), findsOneWidget);
      // 正文横向占满（左右各 40 外边距），在进度线 / 浮岛之上。
      final Rect lyrics = tester.getRect(key('lyrics_view_probe'));
      expect(lyrics.left, closeTo(40, 0.5));
      expect(lyrics.right, closeTo(1560, 0.5));
      expect(lyrics.bottom, lessThan(close.top));
      // 1600 宽全部平铺：⋯ 不带收起项。
      await tester.tap(key('lyrics_more_button').last);
      expect(calls.last, isEmpty);
      await tester.tap(key('lyrics_close_button'));
      expect(calls.last, 'exit');
      expect(tester.takeException(), isNull);
    });

    // BUG-4027：新版宽屏原先只在左岛留了一个百分比，阅读速度 / 已读字数 / 本次
    // 阅读时长全丢了（经典宽屏左栏、窄屏顶栏都有）。
    testWidgets('reading stats (speed · progress · session) above the seek '
        'line', (WidgetTester tester) async {
      await pumpAt(
        tester,
        const Size(1600, 900),
        app(clock: const _StatsClock()),
      );
      final Finder stats = key('lyrics_modern_stats_line');
      expect(stats, findsOneWidget);
      final String text = tester
          .widgetList<Text>(
            find.descendant(of: stats, matching: find.byType(Text)),
          )
          .map((Text w) => w.data ?? '')
          .join(' · ');
      expect(text, contains(t.reader_stats_chars_per_hour(n: '7,200')));
      expect(text, contains('2.2%'));
      expect(text, contains('30:00'));
      // 在进度线上方、浮岛之上（与两端时间同一行）。
      final Rect statsRect = tester.getRect(stats);
      final Rect close = tester.getRect(key('lyrics_close_button'));
      expect(statsRect.bottom, lessThan(close.top));
      final Rect lyrics = tester.getRect(key('lyrics_view_probe'));
      expect(statsRect.top, greaterThanOrEqualTo(lyrics.bottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow window collapses low-priority actions into ⋯', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(900, 700), app());
      expect(tester.takeException(), isNull);
      await tester.tap(key('lyrics_more_button').last);
      final Object collapsed = calls.last;
      expect(collapsed, isA<List<LyricsControlItem>>());
      final List<LyricsControlItem> items =
          collapsed as List<LyricsControlItem>;
      expect(items, isNotEmpty);
      // 倍速是最高优先级，永远不收。
      expect(items, isNot(contains(LyricsControlItem.speed)));
      // 收起的按钮不在岛上。
      if (items.contains(LyricsControlItem.statistics)) {
        expect(key('lyrics_statistics_button'), findsNothing);
      }
    });

    testWidgets('classic layout keeps the corner buttons and side swap', (
      WidgetTester tester,
    ) async {
      await pumpAt(
        tester,
        const Size(1600, 900),
        app(style: LyricsControlsStyle.classic),
      );
      expect(key('lyrics_swap_sides_button'), findsOneWidget);
      final Rect close = tester.getRect(key('lyrics_close_button'));
      expect(close.center.dy, lessThan(900 * 0.2));
    });

    double fontSizeOf(WidgetTester tester, String text) =>
        tester.widget<Text>(find.text(text)).style!.fontSize!;

    testWidgets('info island text scales up with the window width', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(1000, 700), app());
      final double small = fontSizeOf(tester, 'book');
      await pumpAt(tester, const Size(1600, 900), app());
      final double medium = fontSizeOf(tester, 'book');
      await pumpAt(tester, const Size(2000, 1100), app());
      final double large = fontSizeOf(tester, 'book');
      expect(small, 14);
      expect(medium, greaterThan(small));
      expect(large, greaterThan(medium));
      expect(tester.takeException(), isNull);
    });

    testWidgets('playing: bottom chrome stays however long it idles; '
        'lyrics rect never changes', (WidgetTester tester) async {
      await pumpAt(tester, const Size(1600, 900), app(playing: true));
      final Rect shown = tester.getRect(key('lyrics_view_probe'));
      final Rect close = tester.getRect(key('lyrics_close_button'));
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(800, 300));
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.getRect(key('lyrics_view_probe')), shown);
      expect(tester.getRect(key('lyrics_close_button')), close);
      // 反馈 njN2KIQS_j：读数（速度 · 进度 · 时间）在进度线上方一直看得见。
      _expectStatsVisible(tester, key('lyrics_modern_stats_line'));
      expect(
        tester.getRect(key('lyrics_modern_stats_line')).top,
        greaterThanOrEqualTo(shown.bottom),
      );
      // 底栏钮照常可点（没有「先唤出再点」）。
      await tester.tap(key('lyrics_close_button'));
      expect(calls.last, 'exit');
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    });

    MouseCursor? activeCursor() =>
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);

    testWidgets('playing: idle mouse cursor hides (above the WebView), '
        'any movement shows it; paused keeps it', (WidgetTester tester) async {
      await pumpAt(tester, const Size(1600, 900), app(playing: true));
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(800, 300));
      await tester.pump();
      expect(activeCursor(), isNot(SystemMouseCursors.none));

      final Rect lyrics = tester.getRect(key('lyrics_view_probe'));
      await tester.pump(kLyricsCursorIdleHideDelay);
      await tester.pump();
      expect(activeCursor(), SystemMouseCursors.none);
      // 只藏光标：底栏与歌词矩形不动。
      expect(tester.getRect(key('lyrics_view_probe')), lyrics);
      expect(key('lyrics_close_button'), findsOneWidget);

      // 正文上一动光标就回来，歌词矩形不变。
      await mouse.moveTo(const Offset(810, 300));
      await tester.pump();
      expect(activeCursor(), isNot(SystemMouseCursors.none));
      expect(tester.getRect(key('lyrics_view_probe')), lyrics);

      // 暂停：光标常显。
      await pumpAt(tester, const Size(1600, 900), app());
      await mouse.moveTo(const Offset(820, 300));
      await tester.pump(kLyricsCursorIdleHideDelay * 2);
      await tester.pump();
      expect(activeCursor(), isNot(SystemMouseCursors.none));
      await mouse.removePointer();
    });

    testWidgets('lookup-held pause keeps the cursor hidden; a real pause '
        'shows it', (WidgetTester tester) async {
      await pumpAt(tester, const Size(1600, 900), app(playing: true));
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(800, 300));
      await tester.pump(kLyricsCursorIdleHideDelay);
      await tester.pump();
      expect(activeCursor(), SystemMouseCursors.none);
      await tester.pumpWidget(app(heldForLookup: true));
      await tester.pump();
      expect(activeCursor(), SystemMouseCursors.none, reason: '查词暂停不算暂停');
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.pump();
      expect(activeCursor(), isNot(SystemMouseCursors.none));
      await mouse.removePointer();
    });
  });

  group('illustration controller', () {
    List<LyricsIllustration> items(ImageProvider image) => <LyricsIllustration>[
      LyricsIllustration(
        key: 'a',
        position: const LyricsBookPosition(1, 10),
        image: image,
      ),
      LyricsIllustration(
        key: 'b',
        position: const LyricsBookPosition(1, 20),
        image: image,
      ),
    ];

    testWidgets('popup: natural pass reveals once and opens the card', (
      WidgetTester tester,
    ) async {
      final ImageProvider image = await _image(tester);
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..load(
          items(image),
          position: const LyricsBookPosition(1, 0),
          audioPosition: Duration.zero,
        );
      expect(
        c.observe(
          const LyricsBookPosition(1, 12),
          audioPosition: const Duration(seconds: 5),
        ),
        isTrue,
      );
      expect(c.cardVisible, isTrue);
      // 同一张插图再观测不再报。
      expect(
        c.observe(
          const LyricsBookPosition(1, 13),
          audioPosition: const Duration(seconds: 6),
        ),
        isFalse,
      );
      c.closeCard();
      expect(c.cardVisible, isFalse);
      expect(c.shownIllustration?.key, 'a', reason: '缩略图 + 红点留着');
      c.dismiss();
      expect(c.shown, isNull);
    });

    testWidgets('dot: natural pass swaps the thumbnail without the card', (
      WidgetTester tester,
    ) async {
      final ImageProvider image = await _image(tester);
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..autoOpenCard = false
        ..load(
          items(image),
          position: const LyricsBookPosition(1, 0),
          audioPosition: Duration.zero,
        );
      c.observe(
        const LyricsBookPosition(1, 12),
        audioPosition: const Duration(seconds: 5),
      );
      expect(c.shownIllustration?.key, 'a');
      expect(c.cardVisible, isFalse);
    });

    testWidgets('right-to-left books: tap left = next, right = previous', (
      WidgetTester tester,
    ) async {
      final ImageProvider image = await _image(tester);
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..rightToLeft = true
        ..load(
          items(image),
          position: const LyricsBookPosition(1, 30),
          audioPosition: Duration.zero,
        )
        ..showAt(0)
        ..observe(
          const LyricsBookPosition(1, 30),
          audioPosition: Duration.zero,
        );
      // load 后 showAt 不开卡；手动标记卡可见：走一次「顺着播」不可行（已全部听到），
      // 直接用宽屏经典封面位的插图卡（只认 shown）验证点按方向。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 400,
                child: LyricsIllustrationArtworkSlot(
                  controller: c,
                  side: 300,
                  height: 400,
                  borderRadius: BorderRadius.zero,
                  cover: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final Rect card = tester.getRect(key('lyrics_illustration_card').last);
      await tester.tapAt(Offset(card.left + 5, card.center.dy));
      await tester.pump(const Duration(seconds: 1));
      expect(c.shown, 1, reason: '竖排书点左 = 下一张');
      final Rect card2 = tester.getRect(key('lyrics_illustration_card').last);
      await tester.tapAt(Offset(card2.right - 5, card2.center.dy));
      await tester.pump(const Duration(seconds: 1));
      expect(c.shown, 0, reason: '竖排书点右 = 上一张');
    });
  });

  // 2026-10-31 用户拍板：歌词模式网格背景静止（原 30fps 常驻流动是发热源），
  // 只在配色变化时交叉过渡一次，过渡完不再出帧。新旧两种布局都适用。进度条两种
  // 布局都是 FushiWavySeekBar：播放中照经典按 ≈30fps 流动，暂停时振幅收完不再
  // 要帧——所以这里在暂停态断言整页零出帧（= 背景静止 + 波浪按经典暂停行为）。
  group('static mesh backdrop', () {
    testWidgets('lyrics backdrop params: static, no frames once painted', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: FushiMeshBackdrop(animate: false, colorTransition: true),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    for (final LyricsControlsStyle style in LyricsControlsStyle.values) {
      for (final Size size in const <Size>[Size(390, 844), Size(1600, 900)]) {
        testWidgets('${style.name} $size: paused overlay schedules no frames', (
          WidgetTester tester,
        ) async {
          await pumpAt(tester, size, app(style: style));
          await tester.pump(const Duration(seconds: 2));
          expect(tester.binding.hasScheduledFrame, isFalse);
          // 等过一个原流动帧间隔（33ms 档）也不再要帧。
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.binding.hasScheduledFrame, isFalse);
        });
      }
    }

    // 进度条按经典行为：暂停时不流动（上面的空闲用例已断言不出帧），播放时波浪
    // 按 ≈30fps 档位流动；背景网格静止，所以整页出帧数就是波浪那一档（不会叠出
    // 背景的另一档）。
    for (final Size size in const <Size>[Size(390, 844), Size(1600, 900)]) {
      testWidgets('modern $size uses wavy seek bars, flows only when playing', (
        WidgetTester tester,
      ) async {
        int drawn = 0;
        bool counting = false;
        tester.binding.addPersistentFrameCallback((_) {
          if (counting) drawn++;
        });
        // 每次推 1ms，数这段时间实际画了几帧（测试绑定只在有人要帧时才画）。
        Future<int> framesOver(int ms) async {
          drawn = 0;
          counting = true;
          for (int i = 0; i < ms; i++) {
            await tester.pump(const Duration(milliseconds: 1));
          }
          counting = false;
          return drawn;
        }

        await pumpAt(tester, size, app());
        expect(find.byType(FushiWavySeekBar), findsWidgets);
        await tester.pump(const Duration(seconds: 2));
        expect(await framesOver(300), 0, reason: '暂停空闲');
        await pumpAt(tester, size, app(playing: true));
        expect(
          await framesOver(1000),
          inInclusiveRange(20, 40),
          reason: '播放时波浪按 ≈30fps 流动，背景不另出帧',
        );
        // 换回暂停：振幅收成直线后重新静止。
        await pumpAt(tester, size, app());
        await tester.pump(const Duration(seconds: 3));
        await tester.pump(const Duration(seconds: 1));
        expect(await framesOver(300), 0, reason: '暂停后重新静止');
      });
    }

    testWidgets('color change crossfades once, then stops', (
      WidgetTester tester,
    ) async {
      Widget themed(Color seed) => MaterialApp(
        theme: ThemeData(colorSchemeSeed: seed),
        home: Scaffold(
          body: ReaderLyricsPlayerOverlay(
            lyricsView: const SizedBox.expand(),
            data: LyricsPlayerData(
              title: 'book',
              cover: null,
              isPlaying: false,
              speed: 1,
              lyricsMasked: false,
              clock: _Clock(),
            ),
            callbacks: callbacks(),
            onHtmlThemeChanged: (_) {},
          ),
        ),
      );
      await pumpAt(tester, const Size(1600, 900), themed(Colors.teal));
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(themed(Colors.deepOrange));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isTrue, reason: '过渡进行中');
      // 单次 pump 只推进一帧：MaterialApp 的 AnimatedTheme 先在一帧里跳到终点，
      // 网格背景的过渡在那一帧才拿到最终目标色、再走一段 FushiMotion.medium。
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isFalse, reason: '过渡完静止');
    });
  });

  group('continuous playback predicate', () {
    test('normal playback counts, registered jumps / pause do not', () {
      bool f({bool playing = true, int jumpsBetween = 0, int audio = 3000}) =>
          isContinuousLyricsPlayback(
            playing: playing,
            previousJumpSerial: 7,
            currentJumpSerial: 7 + jumpsBetween,
            audioDeltaMs: audio,
          );
      expect(f(), isTrue);
      // 不按墙钟猜：两次观测隔得再近、音频走得再多（后台节流后一次补上来的
      // cue 通知、高倍速），只要控制器没登记过跳转就是顺着播。
      expect(f(audio: 60000), isTrue);
      expect(f(playing: false), isFalse);
      expect(f(jumpsBetween: 1), isFalse, reason: '±10 秒 / 拖进度 / 跳句');
      expect(f(jumpsBetween: 1, audio: 500), isFalse, reason: '小幅 seek 也算跳');
      expect(f(audio: -2000), isFalse, reason: '往回走');
    });
  });
}

/// 带读数的时钟：30 分钟读 3600 字（= 7,200 字/时），全书 1,234 / 56,789。
class _StatsClock implements LyricsPlayerClock {
  const _StatsClock();

  @override
  Duration get position => const Duration(minutes: 3);

  @override
  Duration get duration => const Duration(minutes: 10);

  @override
  LyricsPlayerStats get stats => const LyricsPlayerStats(
    sessionDurationMs: 30 * 60 * 1000,
    sessionChars: 3600,
    tracking: true,
    currentChars: 1234,
    totalChars: 56789,
  );
}

class _ConstClock implements LyricsPlayerClock {
  const _ConstClock();

  @override
  Duration get position => Duration.zero;

  @override
  Duration get duration => Duration.zero;

  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}
