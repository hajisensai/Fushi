import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-841 守卫：特效叠加 / 多层 ASS 用多条 Dialogue 事件渲染**同一句可见文本**（不同
/// layer / style / 位置做描边、辉光、逐字变色特效），字幕列表必须按 `(startMs, 文本)` 折叠
/// 这些重复、一句话只出一行；双语（同时间不同文本）文本不同不折叠，各占一行。画面 overlay
/// 仍全渲染各层特效（不走列表这条路径）。
AudioCue _cue(int sentence, int startMs, String text) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = sentence
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = startMs + 2000
  ..audioFileIndex = 0;

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: Stack(children: <Widget>[child])),
    );

int _rowCount(WidgetTester tester) =>
    tester.widgetList<Text>(find.byType(Text)).where((Text w) {
      final String? d = w.data;
      return d == 'CH line' || d == 'JP line';
    }).length;

void main() {
  testWidgets('特效叠加重复行（同 start 同文本 ×2）在列表里折叠成一行；双语文本不同各占一行',
      (WidgetTester tester) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    // 复现第一张图：1:40 处 ZH / JP / JP / ZH —— 每语言各被特效层复制一遍。
    const int t = 100000; // 1:40
    controller.setCues(<AudioCue>[
      _cue(0, t, 'CH line'),
      _cue(1, t, 'JP line'),
      _cue(2, t, 'JP line'),
      _cue(3, t, 'CH line'),
    ]);

    await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
      controller: controller,
      onTapCue: (_) {},
      onClose: () {},
      onCopyCue: (_) {},
      onFavoriteCue: (_) async {},
      isCueFavorited: (_) => false,
      colorScheme: const ColorScheme.dark(),
      title: 'Subtitle list',
      emptyHint: 'empty',
    )));

    // 各文本只渲染一行（折叠前是各 2 行）。
    expect(find.text('CH line'), findsOneWidget);
    expect(find.text('JP line'), findsOneWidget);
    expect(_rowCount(tester), 2, reason: '4 条特效重复应折叠成 2 行');
  });

  testWidgets('点折叠后的代表行仍能 seek 到真实 cue', (WidgetTester tester) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    const int t = 100000;
    controller.setCues(<AudioCue>[
      _cue(0, t, 'CH line'),
      _cue(1, t, 'JP line'),
      _cue(2, t, 'JP line'),
      _cue(3, t, 'CH line'),
    ]);
    AudioCue? tapped;

    await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
      controller: controller,
      onTapCue: (AudioCue cue) => tapped = cue,
      onClose: () {},
      onCopyCue: (_) {},
      onFavoriteCue: (_) async {},
      isCueFavorited: (_) => false,
      colorScheme: const ColorScheme.dark(),
      title: 'Subtitle list',
      emptyHint: 'empty',
    )));

    await tester.tap(find.text('JP line'));
    await tester.pump();
    expect(tapped, isNotNull);
    expect(tapped!.text, 'JP line');
    expect(tapped!.startMs, t);
  });

  testWidgets('当前播放句落在被折叠的重复项时，代表行仍高亮（不脱靶）', (WidgetTester tester) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    const int t = 100000;
    controller.setCues(<AudioCue>[
      _cue(0, t, 'CH line'),
      _cue(1, t, 'JP line'),
      _cue(2, t, 'JP line'), // 重复：被折叠，raw=2
      _cue(3, t, 'CH line'),
    ]);
    // 让当前句定位到重叠区（多条同刻活跃，currentCueIndex 可能取到重复项）。
    controller.debugUpdateCueForPosition(t + 500);

    await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
      controller: controller,
      onTapCue: (_) {},
      onClose: () {},
      onCopyCue: (_) {},
      onFavoriteCue: (_) async {},
      isCueFavorited: (_) => false,
      colorScheme: const ColorScheme.dark(),
      title: 'Subtitle list',
      emptyHint: 'empty',
    )));
    await tester.pump();

    // 列表仍是 2 行、无异常（渲染不因当前句是重复项而崩）。
    expect(_rowCount(tester), 2);
    expect(find.text('CH line'), findsOneWidget);
    expect(find.text('JP line'), findsOneWidget);
  });
}
