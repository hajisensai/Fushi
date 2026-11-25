/// 全屏歌词动画宿主的版面：场景铺满整窗时浮在上面的悬停条按安全区内缩；
/// 选择面板的样式卡高度按网格实际列宽排版量出，每张卡的说明都完整显示（不裁、不截断）。
library;

import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_registry.dart';
import 'package:fushi/src/pages/implementations/music/music_lyric_visualizer_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;

import 'visualizer_test_helpers.dart';

class _Clock implements FushiPlaybackClock {
  @override
  Duration get position => const Duration(milliseconds: 1200);

  @override
  Duration get duration => const Duration(minutes: 4);
}

Future<void> _openPicker(
  WidgetTester tester,
  double textScale, {
  Size size = const Size(1280, 900),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: GestureDetector(
                key: const ValueKey<String>('open'),
                behavior: HitTestBehavior.opaque,
                onTap: () => showLyricVisualizerPicker(
                  context: context,
                  current: LyricVisualizerMode.monet,
                  random: false,
                  tunings: const <String, Map<String, Object?>>{},
                  onTuningsChanged: (_, _) async {},
                  backgroundId: 'solid',
                ),
                child: const SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey<String>('open')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  // BUG-5355：说明被压矮、字形上下被裁；BUG-5369：说明多于两行被截成省略号。
  // 每种样式的说明都要在实际列宽下完整排出来（宽窗 / 窄窗 × 字号 1.0 / 1.3）。
  for (final Size size in <Size>[const Size(1280, 900), const Size(420, 900)]) {
    for (final double scale in <double>[1, 1.3]) {
      testWidgets('每张样式卡的说明都完整显示（窗口 ${size.width.toInt()} 宽，字号 ×$scale）', (
        WidgetTester tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await _openPicker(tester, scale, size: size);
        final Finder grid = find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        );
        int checked = 0;
        for (final LyricVisualizerMode mode in LyricVisualizerMode.values) {
          final LyricVisualizerEntry entry = lyricVisualizerEntryOf(mode);
          final Finder desc = find.text(entry.description!());
          await tester.scrollUntilVisible(desc, 120, scrollable: grid);
          await tester.pumpAndSettle();
          expect(desc, findsOneWidget, reason: mode.name);
          final RenderParagraph p = tester.renderObject<RenderParagraph>(desc);
          // 列宽要贴近 220 的上限，说明才会真的折成三四行。
          expect(p.size.width, greaterThan(120), reason: mode.name);
          expect(p.didExceedMaxLines, isFalse, reason: mode.name);
          // 说明有多高就给多高：被压矮 = 字形被裁或行被吞。
          expect(
            p.size.height,
            greaterThanOrEqualTo(p.getMaxIntrinsicHeight(p.size.width) - 0.5),
            reason: mode.name,
          );
          checked++;
        }
        expect(checked, LyricVisualizerMode.values.length);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('悬停条按安全区内缩（场景铺满整窗，顶栏拖动条那一条也画）', (WidgetTester tester) async {
    const double top = 40;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(1280, 800),
            padding: EdgeInsets.only(top: top),
          ),
          child: Scaffold(
            body: MusicLyricVisualizerView(
              mode: LyricVisualizerMode.luminous,
              timeline: sampleWordTimeline(),
              clock: _Clock(),
              offsetMs: 0,
              playing: false,
              trackUid: 't',
              tunings: const <String, Map<String, Object?>>{},
              fontScale: 1,
              onExit: () {},
              onPickStyle: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final Rect bar = tester.getRect(
      find.byKey(const ValueKey<String>('music_visualizer_exit')),
    );
    expect(bar.top, greaterThanOrEqualTo(top + 12 - 0.5));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
