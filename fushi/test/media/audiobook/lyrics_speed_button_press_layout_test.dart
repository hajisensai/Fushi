import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_md3.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';

/// 歌词模式工具条的倍速键在点击时不得「跳」（用户录屏：按下 / 松手那几帧
/// 「1.5×」被挤成「1.5 / ×」两行，松手又弹回一行）。
///
/// 根因是 M3E 按钮组的按压弹簧无界：松手回弹冲到 0 以下，负进度把刚松手的
/// 按钮挤得比自身固有宽还窄，文字当场折行。
class _FakeClock implements LyricsPlayerClock {
  @override
  Duration get position => const Duration(seconds: 42);
  @override
  Duration get duration => const Duration(minutes: 10);
  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

void main() {
  Future<void> pumpChrome(WidgetTester tester) async {
    const Size size = Size(393, 852);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    const Md3LyricsPlayerDesign d = Md3LyricsPlayerDesign();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => d.buildChrome(
              context,
              LyricsPlayerData(
                title: 't',
                cover: null,
                isPlaying: true,
                speed: 1.5,
                lyricsMasked: false,
                clock: _FakeClock(),
              ),
              LyricsPlayerCallbacks(
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
                onReplayCue: () {},
                onSleepTimer: (_) {},
              ),
              size: size,
              padding: EdgeInsets.zero,
              lyricsRect: d.lyricsRect(context, size, EdgeInsets.zero),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  int lineCount(RenderParagraph p) => p
      .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 4))
      .map((TextBox b) => b.top)
      .toSet()
      .length;

  testWidgets('松手回弹时倍速键不窄于静止宽、标签不折行', (WidgetTester tester) async {
    await pumpChrome(tester);
    final Finder label = find.text('1.5×');
    // 松手后会弹出倍速面板（里面也有一个「1.5×」），先抓住工具条上这一个。
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      label,
    );
    final RenderBox button = tester.renderObject<RenderBox>(
      find.ancestor(of: label, matching: find.byType(FushiFilledButton)).first,
    );
    final double rest = button.size.width;

    final TestGesture g = await tester.startGesture(tester.getCenter(label));
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        button.size.width,
        greaterThanOrEqualTo(rest - 0.01),
        reason: '第 $i 帧：回弹冲过 0 把按钮挤窄了',
      );
      expect(lineCount(paragraph), 1, reason: '第 $i 帧：倍速标签折行');
    }
  });

  testWidgets('按下相邻的睡眠定时键时倍速标签不折行', (WidgetTester tester) async {
    await pumpChrome(tester);
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      find.text('1.5×'),
    );
    final TestGesture g = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey<String>('lyrics_sleep_timer_button')),
      ),
    );
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(lineCount(paragraph), 1, reason: '第 $i 帧：被邻居挤压时折行');
    }
    await g.cancel();
    // chrome 里有常驻时钟，pumpAndSettle 等不到静止。
    await tester.pump(const Duration(seconds: 1));
  });
}
