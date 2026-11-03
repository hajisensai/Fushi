import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/reader/reader_navigation_widgets.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 所有者 2026-11-02「跳转记录」定稿（取代浮在内容上的胶囊）在小说阅读器一侧的
/// 落地：
///  * 歌词覆盖层：↶ / ↷ 挂在顶栏右侧动作区（[LyricsPlayerData.jumpActions]），
///    不再为胶囊从歌词矩形底边让一条带子——图标出现 / 消失不挪歌词 WebView、
///    不重建它；长按开面板。
///  * 桌面经典顶栏的按钮支持长按 / 右键（开面板）。
///  * 导航页全书进度条画跳转落点刻度。
class _FakeClock implements LyricsPlayerClock {
  @override
  Duration get position => const Duration(seconds: 42);

  @override
  Duration get duration => const Duration(minutes: 10);

  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

class _LyricsProbe extends StatefulWidget {
  const _LyricsProbe({required this.onCreate});

  final VoidCallback onCreate;

  @override
  State<_LyricsProbe> createState() => _LyricsProbeState();
}

class _LyricsProbeState extends State<_LyricsProbe> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
  }

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey<String>('lyrics_probe'));
}

LyricsPlayerCallbacks _callbacks() => LyricsPlayerCallbacks(
  onClose: () {},
  onPlayPause: () {},
  onPreviousCue: () {},
  onNextCue: () {},
  onSeek: (_) {},
  onToggleMask: () {},
  onOpenStatistics: () {},
  onSpeedChanged: (_) {},
  onMore: (_) {},
  onTapBackground: () {},
  // 有退书回调时各外观都画 ×：用它当「顶栏动作区」的参照物。
  onExitBook: () {},
);

const Key _closeKey = ValueKey<String>('lyrics_close_button');

const Key _backKey = ValueKey<String>('fushi_jump_back');

void main() {
  for (final LyricsControlsStyle style in LyricsControlsStyle.values) {
    for (final ({String name, Size size}) layout
        in <({String name, Size size})>[
          (name: '手机竖屏（窄）', size: const Size(390, 844)),
          (name: '桌面（宽）', size: const Size(1280, 760)),
        ]) {
      testWidgets(
        'md3 ${style.name} ${layout.name}：↶ 在顶栏动作区最前、不挪歌词区、不重建 WebView、右键开面板',
        (WidgetTester tester) async {
          int created = 0;
          int backs = 0;
          int panels = 0;
          final Widget probe = _LyricsProbe(onCreate: () => created++);
          final List<FushiToolbarItem> jump = <FushiToolbarItem>[
            FushiToolbarItem(
              key: _backKey,
              icon: FushiIcons.undo,
              label: 'back',
              emphasized: true,
              onPressed: () => backs++,
              onLongPress: () => panels++,
            ),
          ];
          Widget app({required bool withJump}) => MaterialApp(
            home: Scaffold(
              body: ReaderLyricsPlayerOverlay(
                lyricsView: probe,
                data: LyricsPlayerData(
                  title: '無職転生',
                  cover: null,
                  isPlaying: false,
                  speed: 1,
                  lyricsMasked: false,
                  clock: _FakeClock(),
                  controlsStyle: style,
                  jumpActions: withJump ? jump : const <FushiToolbarItem>[],
                ),
                callbacks: _callbacks(),
                onHtmlThemeChanged: (_) {},
              ),
            ),
          );

          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          tester.view.physicalSize = layout.size;
          final Finder lyrics = find.byKey(
            const ValueKey<String>('lyrics_probe'),
          );

          await tester.pumpWidget(app(withJump: false));
          await tester.pump(const Duration(milliseconds: 600));
          final Rect full = tester.getRect(lyrics);
          expect(find.byKey(_backKey), findsNothing);

          await tester.pumpWidget(app(withJump: true));
          await tester.pump(const Duration(milliseconds: 600));
          expect(find.byKey(_backKey), findsOneWidget);
          expect(tester.getRect(lyrics), full, reason: '图标在顶栏里，不再从歌词矩形让带子');
          final Rect back = tester.getRect(find.byKey(_backKey));
          final Rect close = tester.getRect(find.byKey(_closeKey));
          // 各外观的「顶栏动作区」就是 × 所在那一排（新版宽屏没有顶栏，动作区是
          // 右侧的动作岛）：↶ 与 × 同排、排在它前面。
          expect(
            back.center.dy,
            moreOrLessEquals(close.center.dy, epsilon: 6),
            reason: '↶ 与 × 同在动作区那一排',
          );
          expect(back.center.dx, lessThan(close.center.dx), reason: '排在动作区最前');
          expect(
            back.center.dx,
            greaterThan(layout.size.width / 2),
            reason: '在右侧动作区',
          );

          await tester.tap(find.byKey(_backKey));
          await tester.pump();
          expect(backs, 1);
          // 右键（桌面）与触屏长按都开面板：提示在外、长按在里的手势装配只在
          // FushiToolbarLongPressTarget 一处，长按不会被提示抢走。
          await tester.tap(find.byKey(_backKey), buttons: kSecondaryButton);
          await tester.pump();
          expect(panels, 1);
          expect(backs, 1);
          await tester.longPress(find.byKey(_backKey));
          await tester.pump(const Duration(milliseconds: 600));
          expect(panels, 2);
          expect(backs, 1);

          await tester.pumpWidget(app(withJump: false));
          await tester.pump(const Duration(milliseconds: 600));
          expect(tester.getRect(lyrics), full);
          expect(created, 1, reason: '图标出现 / 消失不得重建歌词 WebView');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('桌面经典顶栏按钮：长按 / 右键走 onLongPress，点按走 onPressed', (
    WidgetTester tester,
  ) async {
    int pressed = 0;
    int longPressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ReaderDesktopHeaderButton(
              key: _backKey,
              icon: FushiIcons.undo,
              tooltip: 'back',
              color: Colors.black,
              onPressed: () => pressed++,
              onLongPress: () => longPressed++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(_backKey));
    await tester.pump();
    expect(pressed, 1);
    await tester.longPress(find.byKey(_backKey));
    await tester.pump();
    expect(longPressed, 1);
    await tester.tap(find.byKey(_backKey), buttons: kSecondaryButton);
    await tester.pump();
    expect(longPressed, 2);
    expect(pressed, 1);
  });

  testWidgets('导航页全书进度条：有落点才画跳转刻度，不改进度条占的高度', (WidgetTester tester) async {
    const Key bar = ValueKey<String>('reader_nav_progress_bar');
    const Key marks = ValueKey<String>('fushi_jump_progress_marks');
    Widget hero(({List<double> back, List<double> forward})? m) => MaterialApp(
      home: Scaffold(
        body: ReaderNavProgressHero(
          fraction: 0.4,
          chapter: '第三章',
          fallbackTitle: '阅读进度',
          jumpMarks: m,
        ),
      ),
    );
    await tester.pumpWidget(hero(null));
    await tester.pumpAndSettle();
    expect(find.byKey(marks), findsNothing);
    final double barHeight = tester.getSize(find.byKey(bar)).height;

    await tester.pumpWidget(
      hero((back: <double>[0.124], forward: <double>[0.8])),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(marks), findsOneWidget);
    expect(tester.getSize(find.byKey(bar)).height, barHeight);
    final Rect barRect = tester.getRect(find.byKey(bar));
    final Rect marksRect = tester.getRect(find.byKey(marks));
    expect(marksRect.left, barRect.left, reason: '刻度层与进度条同宽对齐');
    expect(marksRect.width, barRect.width);
    expect(marksRect.center.dy, moreOrLessEquals(barRect.center.dy));

    await tester.pumpWidget(
      hero((back: const <double>[], forward: const <double>[])),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(marks), findsNothing);
  });
}
