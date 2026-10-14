import 'package:fushi_audio/fushi_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_apple.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_md3.dart';

/// 用户建议 yAS98O7PlZ：歌词模式只有上一句 / 下一句，缺「重播当前句」。
class _FakeClock implements LyricsPlayerClock {
  @override
  Duration get position => const Duration(seconds: 42);

  @override
  Duration get duration => const Duration(minutes: 10);

  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

void main() {
  group('replayCurrentCue 目标句', () {
    AudioCue cue(int start, int end) => AudioCue()
      ..bookKey = 'b'
      ..chapterHref = 'c'
      ..sentenceIndex = start
      ..textFragmentId = 'c$start'
      ..text = 'cue $start'
      ..startMs = start
      ..endMs = end
      ..audioFileIndex = 0;
    final List<AudioCue> cues = <AudioCue>[
      cue(0, 1000),
      cue(1500, 2500),
      cue(3000, 4000),
    ];

    test('有当前句（含句间静音里保留的上一句）就重播它，不跳到下一句', () {
      expect(
        AudiobookPlayerController.replayCueIndexForTesting(
          cues: cues,
          currentCueIndex: 1,
          positionMs: 2800, // 第 2、3 句之间的静音
        ),
        1,
      );
    });

    test('还没定位到句时按播放器位置解析', () {
      expect(
        AudiobookPlayerController.replayCueIndexForTesting(
          cues: cues,
          currentCueIndex: -1,
          positionMs: 3500,
        ),
        2,
      );
    });

    test('没有 cue 时不动作', () {
      expect(
        AudiobookPlayerController.replayCueIndexForTesting(
          cues: const <AudioCue>[],
          currentCueIndex: -1,
          positionMs: 0,
        ),
        -1,
      );
    });
  });

  final Map<String, LyricsPlayerDesign> designs = <String, LyricsPlayerDesign>{
    'md3': const Md3LyricsPlayerDesign(),
    'apple': const AppleLyricsPlayerDesign(),
  };
  final Map<String, Size> sizes = <String, Size>{
    'wide': const Size(1280, 760),
    'narrow': const Size(390, 844),
  };

  for (final MapEntry<String, LyricsPlayerDesign> d in designs.entries) {
    for (final MapEntry<String, Size> s in sizes.entries) {
      testWidgets('${d.key} ${s.key}：重播当前句键存在且接到回调', (
        WidgetTester tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = s.value;
        addTearDown(tester.view.reset);
        int replays = 0;
        Widget app({required bool withReplay}) => MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => d.value.buildChrome(
                context,
                LyricsPlayerData(
                  title: '四つ子ぐらし',
                  cover: null,
                  isPlaying: true,
                  speed: 1,
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
                  onReplayCue: withReplay ? () => replays++ : null,
                ),
                size: s.value,
                padding: EdgeInsets.zero,
                lyricsRect: d.value.lyricsRect(
                  context,
                  s.value,
                  EdgeInsets.zero,
                ),
              ),
            ),
          ),
        );

        const ValueKey<String> key = ValueKey<String>(
          'lyrics_replay_cue_button',
        );
        await tester.pumpWidget(app(withReplay: true));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(key), findsOneWidget);
        await tester.tap(find.byKey(key));
        await tester.pump();
        expect(replays, 1);

        await tester.pumpWidget(app(withReplay: false));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(key), findsNothing, reason: '未接回调的宿主不显示该键');
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
