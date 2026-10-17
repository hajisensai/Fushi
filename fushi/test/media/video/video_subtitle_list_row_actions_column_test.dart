// 字幕列表行尾动作不压句尾（反馈 otakuDt 2026-10-08：每行行尾的播放 / 复制 / 收藏按钮
// 浮在字幕句尾上，被压住的词点不了查词，例如「チャート」）。
//
// 桌面（有悬停）M3E 行：动作独占行尾一列，正文的排版宽度先扣掉这一列，悬停浮出动作时
// 文字不在动作底下，句尾的字照常点得到查词；窄面板同样成立。
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  for (final double width in <double>[520, 300]) {
    testWidgets('hovered row actions never cover the sentence end '
        '(panel ${width.round()})', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      const String sentence = 'ヒットチャート';
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, sentence)]);
      AudioCue? lookedUp;
      int? lookedUpIndex;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: <Widget>[
                VideoSubtitleJumpPanel(
                  layout: VideoSubtitleListLayout.m3e,
                  controller: controller,
                  onTapCue: (_) {},
                  onLookupCue: (AudioCue c, int i, Rect _) {
                    lookedUp = c;
                    lookedUpIndex = i;
                  },
                  onCopyCue: (_) => true,
                  onFavoriteCue: (_) async {},
                  isCueFavorited: (_) => false,
                  onClose: () {},
                  colorScheme: const ColorScheme.dark(),
                  title: 'Subtitle list',
                  emptyHint: 'empty',
                  width: width,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final Finder text = find.text(sentence, findRichText: true);
      final Finder column = find.byKey(
        const ValueKey<String>('video-subtitle-row-action-column'),
      );
      expect(column, findsOneWidget, reason: '桌面行尾动作有自己的一列');

      // 悬停整行 → 动作浮出。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: tester.getCenter(text));
      addTearDown(mouse.removePointer);
      await tester.pumpAndSettle();

      final Rect textRect = tester.getRect(text);
      final Rect columnRect = tester.getRect(column);
      expect(
        textRect.right,
        lessThanOrEqualTo(columnRect.left),
        reason: '正文不进动作列：句尾的字不在动作按钮底下',
      );

      // 点句尾最后一个字（「ト」）→ 查词，而不是被动作按钮吃掉。
      // 测试字体 Ahem 每个字形宽 = 字号，按字号算出末字中心。
      final RichText rich = tester.widget<RichText>(text);
      final double fontSize = rich.text.style?.fontSize ?? 14;
      await tester.tapAt(
        Offset(
          textRect.left + fontSize * (sentence.length - 0.5),
          textRect.top + fontSize * 0.6,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(lookedUp?.text, sentence);
      expect(lookedUpIndex, sentence.length - 1);
    });
  }
}
