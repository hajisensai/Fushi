import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_obscure_layer.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_obscure_mode.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/source_guard.dart' show compactCode;

/// aJqIVUPxnd：「手机隐藏字幕，点开进度条应该显示字幕……不然隐藏字幕没办法触发」。
///
/// 根因：遮蔽让位的判据只有「暂停 / 查词浮层开着」（`video_subtitle_overlay.dart`
/// `_buildSubtitleLayer` 的 `userIsReading`）。触屏没有悬停；隐藏态字幕不绘制，盒面上的
/// 点击显形热区用户也找不到——播放中点开进度条想看一眼这句，字幕仍然不在。
///
/// 修法：「用户在看」收成一个判据 [videoSubtitleViewerIsLooking]，移动端控制条可见
/// 计入（桌面不计：鼠标一动控制条就出来）；文本 overlay 与图形字幕遮蔽层共用。
///
/// ① overlay 真行为：控制条显隐直接驱动遮蔽（同一 controller 一直在播，不重建 widget）；
/// ② 判据真值表（含显形总闸、桌面不计）；③ 页面接线守卫。
AudioCue _cue(String text, int startMs, int endMs) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'ch'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

bool _obscured(WidgetTester tester, Finder of) => tester
    .widgetList<Opacity>(
      find.ancestor(of: of.first, matching: find.byType(Opacity)),
    )
    .any((Opacity o) => o.opacity == 0);

bool _blurred(WidgetTester tester, Finder of) => tester
    .widgetList<ImageFiltered>(
      find.ancestor(of: of.first, matching: find.byType(ImageFiltered)),
    )
    .isNotEmpty;

VideoPlayerController _playingController(WidgetTester tester) {
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
  c.setCues(<AudioCue>[_cue('主', 0, 6000)]);
  c.debugUpdateCueForPosition(1000);
  c.debugSetIsPlayingForTesting(true);
  return c;
}

Future<void> _pump(
  WidgetTester tester,
  VideoPlayerController c,
  ValueNotifier<bool> controls, {
  bool subtitleHidden = true,
  bool blurEnabled = false,
  bool revealWhileControlsVisible = true,
  bool revealOnInteraction = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          subtitleHidden: subtitleHidden,
          blurEnabled: blurEnabled,
          obscureRevealOnInteraction: revealOnInteraction,
          controlsVisible: controls,
          revealWhileControlsVisible: revealWhileControlsVisible,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('① 移动端控制条显示期间遮蔽让位', () {
    testWidgets('隐藏 + 播放中：点开控制条即显示，收起即遮回（不重建 widget）', (tester) async {
      final VideoPlayerController c = _playingController(tester);
      final ValueNotifier<bool> controls = ValueNotifier<bool>(false);
      addTearDown(controls.dispose);

      await _pump(tester, c, controls);
      expect(_obscured(tester, find.text('主')), isTrue, reason: '前置：播放中隐藏');

      controls.value = true;
      await tester.pump();
      expect(
        _obscured(tester, find.text('主')),
        isFalse,
        reason: '点开进度条 = 想看一眼这句；触屏没有悬停，这是唯一自然的通道',
      );

      controls.value = false;
      await tester.pump();
      expect(
        _obscured(tester, find.text('主')),
        isTrue,
        reason: '控制条自动收起即遮回（不是一刀关掉遮蔽）',
      );
    });

    testWidgets('模糊走同一条门', (tester) async {
      final VideoPlayerController c = _playingController(tester);
      final ValueNotifier<bool> controls = ValueNotifier<bool>(true);
      addTearDown(controls.dispose);

      await _pump(
        tester,
        c,
        controls,
        subtitleHidden: false,
        blurEnabled: true,
      );
      expect(_blurred(tester, find.text('主')), isFalse);
    });

    testWidgets('桌面（不开 revealWhileControlsVisible）：控制条显示不让位', (tester) async {
      final VideoPlayerController c = _playingController(tester);
      final ValueNotifier<bool> controls = ValueNotifier<bool>(true);
      addTearDown(controls.dispose);

      await _pump(tester, c, controls, revealWhileControlsVisible: false);
      expect(
        _obscured(tester, find.text('主')),
        isTrue,
        reason: '桌面鼠标一动控制条就出来，计入就等于遮蔽失效',
      );
    });

    testWidgets('显形总闸关掉：控制条显示也不让位（BUG-2256 同律）', (tester) async {
      final VideoPlayerController c = _playingController(tester);
      final ValueNotifier<bool> controls = ValueNotifier<bool>(true);
      addTearDown(controls.dispose);

      await _pump(tester, c, controls, revealOnInteraction: false);
      expect(_obscured(tester, find.text('主')), isTrue);
    });
  });

  group('② 判据真值表', () {
    test('videoSubtitleViewerIsLooking', () {
      bool look({
        bool reveal = true,
        bool playing = true,
        bool popup = false,
        bool controls = false,
      }) => videoSubtitleViewerIsLooking(
        revealOnInteraction: reveal,
        isPlaying: playing,
        lookupPopupVisible: popup,
        touchControlsVisible: controls,
      );
      expect(look(), isFalse);
      expect(look(controls: true), isTrue);
      expect(look(playing: false), isTrue);
      expect(look(popup: true), isTrue);
      expect(look(reveal: false, controls: true), isFalse);
      expect(look(reveal: false, playing: false), isFalse);
    });

    test('图形字幕遮蔽层同一条门', () {
      bool active({bool controls = false}) => graphicSubtitleObscureActive(
        obscure: GraphicSubtitleObscure.hide,
        graphicActive: true,
        hoverRevealed: false,
        revealOnInteraction: true,
        isPlaying: true,
        lookupPopupVisible: false,
        touchControlsVisible: controls,
      );
      expect(active(), isTrue);
      expect(active(controls: true), isFalse);
    });
  });

  test('③ 页面只在移动端控制条下接线', () {
    final String layout = compactCode(
      File(
        'lib/src/pages/implementations/video_fushi/layout.part.dart',
      ).readAsStringSync(),
    );
    expect(
      layout,
      contains(
        compactCode('revealWhileControlsVisible: !_isDesktopVideoControls,'),
      ),
    );
    expect(
      layout,
      contains(
        compactCode(
          'touchControlsVisible: _isDesktopVideoControls ? null : _videoControlsVisible,',
        ),
      ),
    );
  });
}
