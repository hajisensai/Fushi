// 字幕列表行菜单「编辑字幕 / 还原原文」（反馈 gleDreKAvo / dpAsMkUjKT）：触屏长按、
// 桌面右键弹出同一份行菜单；编辑项交给 onEditCue，手改过的句子才出现「还原原文」，
// 改后文本经控制器覆盖层直接显示在列表里。
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle_text_override.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(int i, int s, int e, String text) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = text
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

Future<void> _pumpPanel(
  WidgetTester tester,
  VideoPlayerController controller, {
  required List<AudioCue> edited,
  required List<AudioCue> restored,
  VideoSubtitleListLayout layout = VideoSubtitleListLayout.m3e,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(
          children: <Widget>[
            VideoSubtitleJumpPanel(
              layout: layout,
              controller: controller,
              onTapCue: (_) {},
              onCopyCue: (_) => true,
              onFavoriteCue: (_) async {},
              isCueFavorited: (_) => false,
              onEditCue: (AudioCue c) async => edited.add(c),
              onRestoreCue: (AudioCue c) async => restored.add(c),
              onClose: () {},
              colorScheme: const ColorScheme.dark(),
              title: 'Subtitle list',
              emptyHint: 'empty',
              width: 420,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('右键行弹出菜单，「编辑字幕」交给 onEditCue；没改过的句子没有「还原原文」', (
    WidgetTester tester,
  ) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    controller.setCues(<AudioCue>[_cue(0, 0, 1000, '間違った字幕')]);
    final List<AudioCue> edited = <AudioCue>[];
    final List<AudioCue> restored = <AudioCue>[];
    await _pumpPanel(tester, controller, edited: edited, restored: restored);

    await tester.tap(
      find.text('間違った字幕', findRichText: true),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text(t.video_subtitle_list_edit), findsOneWidget);
    expect(find.text(t.video_subtitle_list_edit_restore), findsNothing);

    await tester.tap(find.text(t.video_subtitle_list_edit));
    await tester.pumpAndSettle();
    expect(edited.single.text, '間違った字幕');
  });

  testWidgets('改过的句子显示改后文本，长按菜单出现「还原原文」', (WidgetTester tester) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    controller.setCues(<AudioCue>[_cue(0, 0, 1000, '間違った字幕')]);
    controller.setCueTextOverrides(
      SubtitleTextOverrides(<(int, String), String>{(0, '間違った字幕'): '正しい字幕'}),
    );
    final List<AudioCue> edited = <AudioCue>[];
    final List<AudioCue> restored = <AudioCue>[];
    await _pumpPanel(tester, controller, edited: edited, restored: restored);

    final Finder row = find.text('正しい字幕', findRichText: true);
    expect(row, findsOneWidget);
    expect(find.text('間違った字幕', findRichText: true), findsNothing);

    await tester.longPress(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.video_subtitle_list_edit_restore));
    await tester.pumpAndSettle();
    expect(restored.single.sourceText, '間違った字幕');
  });

  testWidgets('经典布局同样支持右键行菜单', (WidgetTester tester) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    controller.setCues(<AudioCue>[_cue(0, 0, 1000, '一行目')]);
    final List<AudioCue> edited = <AudioCue>[];
    await _pumpPanel(
      tester,
      controller,
      edited: edited,
      restored: <AudioCue>[],
      layout: VideoSubtitleListLayout.classic,
    );
    await tester.tap(
      find.text('一行目', findRichText: true),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.video_subtitle_list_edit));
    await tester.pumpAndSettle();
    expect(edited.single.text, '一行目');
  });
}
