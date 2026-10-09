// 字幕列表「点字幕查词」开关（群反馈 GbN9MoKDCQ）：手机上列表旁的查词弹窗又扁又窄，
// 多数人只拿字幕列表跳转，点到字上反而误触查词。关掉后点哪里都只跳到该句；开关只在
// 本就能查词（onLookupCue 非 null）时出现，切换经 onTapLookupChanged 交页面落盘。
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

const ValueKey<String> _toggleKey = ValueKey<String>(
  'video-subtitle-list-tap-lookup',
);

void main() {
  for (final VideoSubtitleListLayout layout in <VideoSubtitleListLayout>[
    VideoSubtitleListLayout.classic,
    VideoSubtitleListLayout.m3e,
  ]) {
    testWidgets('${layout.name}: tap-lookup off → tapping text only seeks; '
        'toggling it back on restores lookup', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      const String sentence = 'シナモンが死んでなきゃいける';
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, sentence)]);
      AudioCue? seeked;
      AudioCue? lookedUp;
      final List<bool> persisted = <bool>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: <Widget>[
                VideoSubtitleJumpPanel(
                  layout: layout,
                  controller: controller,
                  onTapCue: (AudioCue c) => seeked = c,
                  onLookupCue: (AudioCue c, int _, Rect __) => lookedUp = c,
                  initialTapLookup: false,
                  onTapLookupChanged: persisted.add,
                  onCopyCue: (_) => true,
                  onFavoriteCue: (_) async {},
                  isCueFavorited: (_) => false,
                  onClose: () {},
                  colorScheme: const ColorScheme.dark(),
                  title: 'Subtitle list',
                  emptyHint: 'empty',
                  width: 520,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      Offset firstChar() {
        final Rect rect = tester.getRect(
          find.text(sentence, findRichText: true),
        );
        return rect.centerLeft + const Offset(6, 0);
      }

      // 关：点在字上也只是跳转，查词回调一次都不被调用。
      await tester.tapAt(firstChar());
      await tester.pump(const Duration(milliseconds: 400));
      expect(lookedUp, isNull, reason: '关掉点字幕查词后，点字不应查词');
      expect(seeked?.text, sentence, reason: '点字应跳到该句');

      // 开关在头部，切开 → 回调交页面落盘。
      expect(find.byKey(_toggleKey), findsOneWidget);
      await tester.tap(find.byKey(_toggleKey));
      await tester.pump();
      expect(persisted, <bool>[true]);

      // 开：点同一个字恢复查词。
      seeked = null;
      await tester.tapAt(firstChar());
      await tester.pump(const Duration(milliseconds: 400));
      expect(lookedUp?.text, sentence, reason: '重新打开后点字应查词');
      expect(seeked, isNull, reason: '查词时不跳转');
    });

    testWidgets('${layout.name}: no lookup capability → no tap-lookup toggle', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, 'seek me')]);
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
                  onClose: () {},
                  colorScheme: const ColorScheme.dark(),
                  title: 'Subtitle list',
                  emptyHint: 'empty',
                  width: 520,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(_toggleKey), findsNothing);
    });
  }
}
