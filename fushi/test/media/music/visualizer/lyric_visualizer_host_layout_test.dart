/// 全屏歌词动画宿主的版面：场景铺满整窗时浮在上面的悬停条按安全区内缩；
/// 选择面板的样式卡高度按字体行高量出，说明两行不被裁。
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

Future<void> _openPicker(WidgetTester tester, double textScale) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(1280, 900),
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

  for (final double scale in <double>[1, 1.3]) {
    testWidgets('样式卡说明完整显示两行（字号 ×$scale）', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _openPicker(tester, scale);
      final LyricVisualizerEntry entry = lyricVisualizerEntryOf(
        LyricVisualizerMode.luminous,
      );
      final Finder desc = find.text(entry.description!());
      expect(desc, findsOneWidget);
      final RenderParagraph p = tester.renderObject<RenderParagraph>(desc);
      // 说明给多少行就有多少行的高度：被 Flexible 压矮 = 字形上下被裁。
      expect(
        p.size.height,
        greaterThanOrEqualTo(p.getMaxIntrinsicHeight(p.size.width) - 0.5),
      );
      expect(tester.takeException(), isNull);
    });
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
