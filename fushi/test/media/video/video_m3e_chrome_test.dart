import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_chapter_skip.dart';
import 'package:fushi/src/media/video/video_control_bar.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_m3e_chrome.dart';
import 'package:media_kit_video/media_kit_video.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('videoM3eFormatTime', () {
    test('short clips use m:ss, long ones h:mm:ss', () {
      expect(videoM3eFormatTime(const Duration(seconds: 65)), '1:05');
      expect(
        videoM3eFormatTime(
          const Duration(minutes: 5),
          reference: const Duration(hours: 2),
        ),
        '0:05:00',
      );
      expect(videoM3eFormatTime(const Duration(seconds: -3)), '0:00');
    });
  });

  group('videoCueDensity', () {
    test('empty or unknown duration yields no marks', () {
      expect(
        videoCueDensity(const <({int startMs, int endMs})>[], 1000),
        isEmpty,
      );
      expect(
        videoCueDensity(<({int startMs, int endMs})>[
          (startMs: 0, endMs: 10),
        ], 0),
        isEmpty,
      );
    });

    test('coverage per bucket is clamped to 0..1', () {
      final List<double> d = videoCueDensity(
        <({int startMs, int endMs})>[
          (startMs: 0, endMs: 500),
          (startMs: 0, endMs: 1000),
          (startMs: 3000, endMs: 3500),
        ],
        4000,
        buckets: 4,
      );
      expect(d, hasLength(4));
      expect(d[0], 1.0);
      expect(d[1], 0.0);
      expect(d[3], closeTo(0.5, 1e-9));
    });
  });

  group('videoSkippableChapterKind', () {
    test('recognises opening / ending chapter names', () {
      for (final String t in <String>[
        'OP',
        'Opening',
        'op2',
        'オープニング',
        'Intro',
      ]) {
        expect(
          videoSkippableChapterKind(t),
          VideoSkippableChapter.opening,
          reason: t,
        );
      }
      for (final String t in <String>[
        'ED',
        'Ending',
        'Credits',
        'エンディング',
        'ed 1',
      ]) {
        expect(
          videoSkippableChapterKind(t),
          VideoSkippableChapter.ending,
          reason: t,
        );
      }
    });

    test('content chapters are never skippable', () {
      for (final String t in <String>[
        'Part A',
        'Episode Preview',
        'Prologue',
        '',
        'Opening Act One',
      ]) {
        expect(videoSkippableChapterKind(t), isNull, reason: t);
      }
    });
  });

  group('default layout (M3E rework)', () {
    final VideoControlLayout layout = VideoControlLayout.currentChrome;

    test('bottom-left is episode / play / episode + time', () {
      expect(layout.itemsIn(VideoControlSlot.bottomLeft), <VideoControlItem>[
        VideoControlItem.previousEpisode,
        VideoControlItem.playPause,
        VideoControlItem.nextEpisode,
        VideoControlItem.positionIndicator,
      ]);
    });

    test('bottom-centre is the learning group with replay in the middle', () {
      expect(layout.itemsIn(VideoControlSlot.bottomCenter), <VideoControlItem>[
        VideoControlItem.seekBackward,
        VideoControlItem.frameBackward,
        VideoControlItem.previousCue,
        VideoControlItem.replayCue,
        VideoControlItem.nextCue,
        VideoControlItem.frameForward,
        VideoControlItem.seekForward,
      ]);
    });

    test('replay folds together with the other cue keys', () {
      expect(
        videoControlItemBarHideGroup(VideoControlItem.replayCue),
        videoControlItemBarHideGroup(VideoControlItem.nextCue),
      );
      expect(
        videoControlItemBarPriority(VideoControlItem.replayCue),
        videoControlItemBarPriority(VideoControlItem.previousCue),
      );
    });

    test('saved layouts without replayCue get it in the learning group', () {
      final VideoControlLayout old = VideoControlLayout.decode(
        '{"version":3,"slots":{"bottomCenter":["previousCue","playPause","nextCue"]},"removed":[]}',
      );
      expect(
        old.slotOf(VideoControlItem.replayCue),
        VideoControlSlot.bottomCenter,
      );
      // 用户自己的按钮位置不被新默认改写。
      expect(
        old.slotOf(VideoControlItem.playPause),
        VideoControlSlot.bottomCenter,
      );
    });
  });

  group('widgets', () {
    testWidgets('time text toggles via tap and Enter', (
      WidgetTester tester,
    ) async {
      int toggles = 0;
      await tester.pumpWidget(
        _host(
          VideoM3eTimeText(
            position: const Duration(minutes: 1),
            duration: const Duration(minutes: 3),
            showRemaining: true,
            style: const TextStyle(fontSize: 13),
            onToggle: () => toggles++,
          ),
        ),
      );
      expect(find.textContaining('-2:00'), findsOneWidget);
      await tester.tap(find.byType(InkWell));
      expect(toggles, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(toggles, 2);
    });

    testWidgets('icon button is focusable and Enter activates it', (
      WidgetTester tester,
    ) async {
      int presses = 0;
      await tester.pumpWidget(
        _host(
          VideoM3eIconButton(
            icon: const Icon(Icons.subtitles),
            onPressed: () => presses++,
            extent: 44,
            tonal: true,
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(presses, 1);
    });

    testWidgets('play button morphs and Enter toggles', (
      WidgetTester tester,
    ) async {
      int presses = 0;
      Widget build(bool playing) => _host(
        VideoM3ePlayPauseButton(
          playing: playing,
          extent: 96,
          style: VideoM3ePlayButtonStyle.translucent,
          onPressed: () => presses++,
        ),
      );
      await tester.pumpWidget(build(false));
      await tester.pumpWidget(build(true));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(presses, 1);
    });

    testWidgets('center paused hint is a small, plate-less, dimmed icon', (
      WidgetTester tester,
    ) async {
      int presses = 0;
      await tester.pumpWidget(
        _host(VideoCenterPausedHint(extent: 44, onPressed: () => presses++)),
      );
      final Icon icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.play_arrow_rounded);
      expect(icon.size, 44);
      expect(icon.color!.a, lessThan(1));
      // 不再有半透明大圆块：提示子树里没有任何带底色的 DecoratedBox / Material。
      expect(
        find.descendant(
          of: find.byType(VideoCenterPausedHint),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(VideoCenterPausedHint),
          matching: find.byType(Material),
        ),
        findsNothing,
      );
      // 命中区不小于 48dp，且不超出图标太多（不吃掉画面中央的单击切控制栏）。
      final Size hit = tester.getSize(find.byType(VideoCenterPausedHint));
      expect(hit, const Size.square(48));
      await tester.tap(find.byType(VideoCenterPausedHint));
      expect(presses, 1);
    });

    testWidgets('seek track paints for every state without throwing', (
      WidgetTester tester,
    ) async {
      for (final bool playing in <bool>[true, false]) {
        for (final bool dragging in <bool>[true, false]) {
          await tester.pumpWidget(
            _host(
              SizedBox(
                width: 600,
                height: 36,
                child: VideoM3eSeekTrack(
                  visual: VideoSeekBarVisual(
                    position: 0.4,
                    buffer: 0.6,
                    hover: dragging ? 0.4 : null,
                    hovering: false,
                    dragging: dragging,
                    playing: playing,
                    duration: const Duration(minutes: 20),
                    alignment: Alignment.center,
                  ),
                  color: Colors.purple,
                  scale: 1,
                  hoverBubble: true,
                  cueDensity: const <double>[0, 0.5, 1, 0.2],
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull);
          expect(find.text('8:00'), dragging ? findsOneWidget : findsNothing);
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
