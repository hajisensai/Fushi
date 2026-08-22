import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-1776 守卫：卡拉OK交替特效把同一句歌词拆成**时间首尾相接、startMs 各异**的多组
/// Dialogue（用户片源真值：神稲ぼたん S01E08 OP，同句在 1:01.67/1:03.13/1:04.67/1:06.21
/// 各起一对 \clip 分屏层），BUG-841 的 `(startMs, 文本)` 精确键折不掉 → 列表同句连出
/// 四行。第二轮邻接链折叠：同文本 + 与链尾窗口相接/重叠（空隙 ≤ 40ms）→ 折进链首行。
/// 隔了真实静默段（> 40ms）的重复台词不折叠，各占一行。
AudioCue _cue(int sentence, int startMs, int endMs, String text) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = sentence
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Stack(children: <Widget>[child])),
);

Future<void> _pumpPanel(
  WidgetTester tester,
  VideoPlayerController controller,
) async {
  await tester.pumpWidget(
    _wrap(
      VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (_) {},
        onClose: () {},
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
      ),
    ),
  );
}

void main() {
  testWidgets('E08 OP 形状：同句四段首尾相接（各段再有同 start 特效对）折叠成一行', (
    WidgetTester tester,
  ) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    const String lyric = 'OP lyric line';
    // 61670-63130-64670-66210-68050：四段相接，每段两层（同 start 同文本）。
    controller.setCues(<AudioCue>[
      _cue(0, 61670, 63130, lyric),
      _cue(1, 61670, 63130, lyric),
      _cue(2, 63130, 64670, lyric),
      _cue(3, 63130, 64670, lyric),
      _cue(4, 64670, 66210, lyric),
      _cue(5, 64670, 66210, lyric),
      _cue(6, 66210, 68050, lyric),
    ]);

    await _pumpPanel(tester, controller);

    expect(
      find.text(lyric),
      findsOneWidget,
      reason: '首尾相接的同句特效链必须折叠成一行（修复前四行）',
    );
  });

  testWidgets('隔了静默段的重复台词不折叠：两次「はい」各占一行', (WidgetTester tester) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    controller.setCues(<AudioCue>[
      _cue(0, 1000, 2000, 'はい'),
      _cue(1, 4000, 5000, 'はい'),
    ]);

    await _pumpPanel(tester, controller);

    expect(
      find.text('はい'),
      findsNWidgets(2),
      reason: '空隙 2s >> 40ms，是两句真实台词，不得错合',
    );
  });

  testWidgets('链中段与非链行交错时只折叠同文本链，异文本行保留', (WidgetTester tester) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    controller.setCues(<AudioCue>[
      _cue(0, 1000, 2500, 'lyric A'),
      _cue(1, 2000, 3000, 'dialogue B'),
      _cue(2, 2500, 4000, 'lyric A'),
    ]);

    await _pumpPanel(tester, controller);

    expect(find.text('lyric A'), findsOneWidget);
    expect(find.text('dialogue B'), findsOneWidget);
  });

  testWidgets('当前句落在链中任一段都高亮到链首代表行（跳转 seek 用链首 cue）', (
    WidgetTester tester,
  ) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    const String lyric = 'OP lyric line';
    controller.setCues(<AudioCue>[
      _cue(0, 61670, 63130, lyric),
      _cue(1, 63130, 64670, lyric),
      _cue(2, 64670, 66210, lyric),
    ]);
    // 播放位置落在第三段：链首行仍应是唯一渲染行（不炸、不空）。
    controller.debugUpdateCueForPosition(65000);

    await _pumpPanel(tester, controller);
    await tester.pump();

    expect(find.text(lyric), findsOneWidget);
  });
}
