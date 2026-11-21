import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(int i) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = '第$i行　今日はいい天気ですね'
  ..startMs = i * 2000
  ..endMs = i * 2000 + 1500
  ..audioFileIndex = 0;

/// video-23（路线图 #3722 m3）：字幕列表的 `itemExtentBuilder` 每次布局都遍历全部行。
/// 行高在一次构建内按可见行下标备忘后，**不重建的布局帧**（滚动 / 自动跟随动画）
/// 不再对每一行重拼缓存键、重跑收藏谓词——收藏谓词的调用次数只跟新构建出来的
/// 那几行有关，与总行数无关。没有备忘时一帧就要对全部行各调十几次。
void main() {
  testWidgets('M3E 列表滚动帧不按总行数重跑收藏谓词', (WidgetTester tester) async {
    videoSubtitleRowExtentCache.reset();
    const int total = 3000;
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    controller.setCues(List<AudioCue>.generate(total, _cue, growable: false));
    int favoriteCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              SizedBox(
                width: 420,
                height: 800,
                child: VideoSubtitleJumpPanel(
                  layout: VideoSubtitleListLayout.m3e,
                  controller: controller,
                  onTapCue: (_) {},
                  onClose: () {},
                  onCopyCue: (_) => true,
                  onFavoriteCue: (_) async {},
                  isCueFavorited: (AudioCue cue) {
                    favoriteCalls++;
                    return cue.sentenceIndex % 40 == 0;
                  },
                  colorScheme: const ColorScheme.dark(),
                  title: 'Subtitle list',
                  emptyHint: 'empty',
                  width: 420,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder list = find.byType(Scrollable).last;
    for (int i = 0; i < 5; i++) {
      favoriteCalls = 0;
      await tester.drag(list, const Offset(0, -300));
      await tester.pump();
      expect(
        favoriteCalls,
        lessThan(total ~/ 10),
        reason:
            '滚动帧只该为新进视口的行调收藏谓词，'
            '不该随总行数（$total）对每行重算行高（第 $i 次滚动调了 $favoriteCalls 次）',
      );
    }
  });
}
