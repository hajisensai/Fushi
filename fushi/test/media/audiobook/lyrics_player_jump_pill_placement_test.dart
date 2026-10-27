import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';

/// 反馈 0AwuVqrNFn：歌词模式下「返回原位置」胶囊挂在歌词区顶部，压住歌词行。
/// 现在歌词矩形从底边为它让出一条带子，胶囊坐在带子里、紧贴底栏上方：
///  * 胶囊与歌词 WebView 不重叠（默认边距下也成立——让位发生在外观给的矩形上）；
///  * 胶囊仍在外观的歌词矩形内（不压到底栏 / 控件面板）；
///  * 胶囊出现 / 消失只改 WebView 矩形，不重建 WebView。
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
);

void main() {
  test('带子几何：歌词矩形让出底边一条带子，胶囊带子紧贴其下', () {
    const Rect lyrics = Rect.fromLTRB(0, 100, 400, 700);
    expect(lyricsViewRectFor(lyrics, hasAccessory: false), lyrics);
    final Rect view = lyricsViewRectFor(lyrics, hasAccessory: true);
    final Rect band = navigationAccessoryRectFor(lyrics);
    expect(view.top, lyrics.top);
    expect(view.bottom, lyrics.bottom - kLyricsNavigationAccessoryBand);
    expect(band.top, view.bottom);
    expect(band.bottom, lyrics.bottom);
    expect(band.height, greaterThanOrEqualTo(48), reason: '放得下 48dp 命中区');
    // 矩形极矮时不出负高度。
    const Rect tiny = Rect.fromLTRB(0, 100, 400, 120);
    expect(lyricsViewRectFor(tiny, hasAccessory: true).height, 1);
    expect(navigationAccessoryRectFor(tiny).height, greaterThanOrEqualTo(0));
  });

  for (final ({String name, Size size}) layout in <({String name, Size size})>[
    (name: '手机竖屏（窄）', size: const Size(390, 844)),
    (name: '桌面（宽）', size: const Size(1280, 760)),
  ]) {
    testWidgets('md3 ${layout.name}：胶囊在歌词区底边、不压歌词，不重建 WebView', (
      WidgetTester tester,
    ) async {
      int created = 0;
      final Widget probe = _LyricsProbe(onCreate: () => created++);
      const Key pillKey = ValueKey<String>('jump_pill');
      Widget app({required bool pill}) => MaterialApp(
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
            ),
            callbacks: _callbacks(),
            onHtmlThemeChanged: (_) {},
            navigationAccessory: pill
                ? const SizedBox(key: pillKey, width: 220, height: 48)
                : null,
          ),
        ),
      );

      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.view.physicalSize = layout.size;
      final Finder lyrics = find.byKey(const ValueKey<String>('lyrics_probe'));

      await tester.pumpWidget(app(pill: false));
      await tester.pump(const Duration(milliseconds: 50));
      final Rect full = tester.getRect(lyrics);

      await tester.pumpWidget(app(pill: true));
      await tester.pump(const Duration(milliseconds: 50));
      final Rect shrunk = tester.getRect(lyrics);
      final Rect pill = tester.getRect(find.byKey(pillKey));

      expect(
        pill.overlaps(shrunk),
        isFalse,
        reason: '胶囊不得压在歌词 WebView 上（旧实现挂在歌词区顶部）',
      );
      expect(pill.top, greaterThanOrEqualTo(shrunk.bottom));
      expect(
        pill.bottom,
        lessThanOrEqualTo(full.bottom),
        reason: '仍在外观的歌词矩形内，不压到底栏 / 控件面板',
      );
      expect(pill.top, greaterThan(full.center.dy), reason: '挂在下沿，不是顶部');
      expect(shrunk.top, full.top);
      expect(
        shrunk.bottom,
        moreOrLessEquals(full.bottom - kLyricsNavigationAccessoryBand),
      );
      expect(
        pill.center.dx,
        moreOrLessEquals(full.center.dx),
        reason: '水平居中于歌词区',
      );

      await tester.pumpWidget(app(pill: false));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getRect(lyrics), full, reason: '胶囊消失后歌词区还原');
      expect(created, 1, reason: '胶囊出现 / 消失不得重建歌词 WebView');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
