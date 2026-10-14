// 暂停 OCR 覆盖层：识别完成标记到时淡出（反馈 YtbinN_pBG / -6dAnq8S6f）、
// 无图形字幕的视频按 VideoPauseOcrScope 识别（反馈 i5A0mu1-AT / BUG-3314）。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_stream_ocr.dart'
    show MangaStreamOcrSetup;
import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_ocr_overlay.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_ocr_progress.dart';
import 'package:fushi/src/media/video/video_pause_ocr_scope.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:material_ui/material_ui.dart';

const GraphicSubtitleOcrFrame _frame = GraphicSubtitleOcrFrame(
  imageSize: Size(1920, 1080),
  chars: <GraphicSubtitleOcrChar>[
    (sentence: '字幕', graphemeIndex: 0, rect: Rect.fromLTWH(900, 950, 60, 60)),
    (sentence: '字幕', graphemeIndex: 1, rect: Rect.fromLTWH(960, 950, 60, 60)),
  ],
);

VideoPlayerController _pausedController({required bool graphic}) {
  final VideoPlayerController c = VideoPlayerController()
    ..debugVideoWidthOverride = 1920
    ..debugVideoHeightOverride = 1080;
  c.debugSetGraphicSubtitleActiveForTesting(graphic);
  c.debugSetPositionForTesting(5000);
  c.debugSetIsPlayingForTesting(false);
  return c;
}

AudioCue _textCue(String text) => AudioCue()
  ..bookKey = ''
  ..chapterHref = ''
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = 4000
  ..endMs = 7000
  ..audioFileIndex = 0;

Future<MangaStreamOcrSetup> _noPrepare(String _) =>
    throw StateError('recognizeFrame is injected; prepare must not run');

class _Probe {
  int captures = 0;

  Future<Uint8List?> capture() async {
    captures++;
    return Uint8List.fromList(<int>[1, 2, 3]);
  }

  Future<GraphicSubtitleOcrFrame?> recognize(Uint8List _) async => _frame;
}

Widget _overlay(
  VideoPlayerController c,
  _Probe probe, {
  VideoPauseOcrScope scope = VideoPauseOcrScope.graphicSubtitles,
  VoidCallback? onEnableRequested,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 960,
        height: 540,
        child: VideoGraphicSubtitleOcrOverlay(
          controller: c,
          fit: BoxFit.contain,
          prepare: _noPrepare,
          onCharTap: (_, _, _) {},
          captureFrame: probe.capture,
          recognizeFrame: probe.recognize,
          scope: scope,
          onEnableRequested: onEnableRequested,
        ),
      ),
    ),
  );
}

final Finder _hitBoxes = find.descendant(
  of: find.byType(VideoGraphicSubtitleOcrOverlay),
  matching: find.byType(GestureDetector),
);

final Finder _pill = find.byKey(
  const ValueKey<String>('graphic_subtitle_ocr_status_pill'),
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('「已识别」标记几秒后自动淡出，可点的字留到继续播放', (tester) async {
    final VideoPlayerController c = _pausedController(graphic: true);
    addTearDown(c.dispose);
    final _Probe probe = _Probe();
    await tester.pumpWidget(_overlay(c, probe));
    await tester.pump(kGraphicSubtitleOcrSettleDelay);
    await tester.pump(const Duration(milliseconds: 500));

    expect(probe.captures, 1);
    expect(
      find.text(t.video_subtitle_graphic_ocr_status_ready),
      findsOneWidget,
    );
    expect(_hitBoxes, findsNWidgets(_frame.chars.length));

    await tester.pump(kGraphicSubtitleOcrStatusHintDuration);
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.text(t.video_subtitle_graphic_ocr_status_ready),
      findsNothing,
      reason: '识别完成提示不该在暂停期间常驻（YtbinN_pBG）',
    );
    expect(_pill, findsNothing);
    expect(
      _hitBoxes,
      findsNWidgets(_frame.chars.length),
      reason: '淡出的只是提示，点字查词区域照旧可用',
    );
  });

  testWidgets('没有图形字幕：仅图形字幕档不识别，所有视频档且无文字字幕在屏才识别', (tester) async {
    final VideoPlayerController c = _pausedController(graphic: false);
    addTearDown(c.dispose);
    final _Probe probe = _Probe();

    await tester.pumpWidget(_overlay(c, probe));
    await tester.pump(kGraphicSubtitleOcrSettleDelay * 2);
    expect(probe.captures, 0, reason: '仅图形字幕档：无图形字幕的视频不做暂停 OCR');

    await tester.pumpWidget(_overlay(c, probe, scope: VideoPauseOcrScope.all));
    await tester.pump(kGraphicSubtitleOcrSettleDelay);
    await tester.pump(const Duration(milliseconds: 500));
    expect(probe.captures, 1, reason: '所有视频档：硬字幕视频暂停即识别');
    expect(_hitBoxes, findsNWidgets(_frame.chars.length));
    await tester.pump(kGraphicSubtitleOcrStatusHintDuration);
  });

  testWidgets('所有视频档但文字字幕在屏：不识别（不与字幕查词抢点击）', (tester) async {
    final VideoPlayerController c = _pausedController(graphic: false);
    addTearDown(c.dispose);
    c.setCues(<AudioCue>[_textCue('テキスト字幕')]);
    // 活动集由位置刷新求出（setCues 只复位）；走与播放时同一条路径让这条 cue 在屏。
    c.debugUpdateCueForPosition(5000);
    final _Probe probe = _Probe();
    await tester.pumpWidget(_overlay(c, probe, scope: VideoPauseOcrScope.all));
    await tester.pump(kGraphicSubtitleOcrSettleDelay * 2);
    expect(probe.captures, 0);
    expect(_hitBoxes, findsNothing);
  });

  testWidgets('所有视频档、主字幕关只开副字幕：不识别（BUG-1592 副字幕查词不被 OCR 盖住）', (tester) async {
    final VideoPlayerController c = _pausedController(graphic: false);
    addTearDown(c.dispose);
    c.setSecondaryCues(<AudioCue>[_textCue('副字幕テキスト')]);
    c.debugUpdateCueForPosition(5000);
    expect(c.cues, isEmpty, reason: '前提：主字幕关着');
    final _Probe probe = _Probe();
    await tester.pumpWidget(_overlay(c, probe, scope: VideoPauseOcrScope.all));
    await tester.pump(kGraphicSubtitleOcrSettleDelay * 2);
    expect(probe.captures, 0);
    expect(_hitBoxes, findsNothing);
  });

  testWidgets('已识别出可点区域后再开副字幕：OCR 结果立即撤掉', (tester) async {
    final VideoPlayerController c = _pausedController(graphic: false);
    addTearDown(c.dispose);
    final _Probe probe = _Probe();
    await tester.pumpWidget(_overlay(c, probe, scope: VideoPauseOcrScope.all));
    await tester.pump(kGraphicSubtitleOcrSettleDelay);
    await tester.pump(const Duration(milliseconds: 500));
    expect(_hitBoxes, findsNWidgets(_frame.chars.length));

    c.setSecondaryCues(<AudioCue>[_textCue('副字幕テキスト')]);
    c.debugUpdateCueForPosition(5000);
    await tester.pump();
    expect(_hitBoxes, findsNothing, reason: '副字幕出现后不能再有整帧 OCR 区域压在它上面');
    await tester.pump(kGraphicSubtitleOcrStatusHintDuration);
  });

  group('BUG-3342 暂停 OCR 默认关闭、仅图片字幕提示开启', () {
    final Finder hint = find.byKey(
      const ValueKey<String>('graphic_subtitle_ocr_enable_hint'),
    );
    final Finder enableButton = find.byKey(
      const ValueKey<String>('graphic_subtitle_ocr_enable_button'),
    );

    testWidgets('关闭档 + 图片字幕：不截帧、不识别（不弹 Lens 同意框），只显示开启提示', (tester) async {
      final VideoPlayerController c = _pausedController(graphic: true);
      addTearDown(c.dispose);
      final _Probe probe = _Probe();
      int enableRequests = 0;
      await tester.pumpWidget(
        _overlay(
          c,
          probe,
          scope: VideoPauseOcrScope.off,
          onEnableRequested: () => enableRequests++,
        ),
      );
      await tester.pump(kGraphicSubtitleOcrSettleDelay * 2);
      await tester.pump(const Duration(milliseconds: 500));
      expect(probe.captures, 0, reason: '默认不自动 OCR');
      expect(hint, findsOneWidget);
      expect(
        find.text(t.video_subtitle_graphic_ocr_enable_hint),
        findsOneWidget,
      );

      await tester.tap(enableButton);
      await tester.pump();
      expect(enableRequests, 1);
    });

    testWidgets('点开启后范围变为仅图片字幕：提示消失并立即识别当前帧', (tester) async {
      final VideoPlayerController c = _pausedController(graphic: true);
      addTearDown(c.dispose);
      final _Probe probe = _Probe();
      VideoPauseOcrScope scope = VideoPauseOcrScope.off;
      late StateSetter rebuild;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            rebuild = setState;
            return _overlay(
              c,
              probe,
              scope: scope,
              onEnableRequested: () =>
                  rebuild(() => scope = VideoPauseOcrScope.graphicSubtitles),
            );
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(hint, findsOneWidget);

      await tester.tap(enableButton);
      await tester.pump();
      await tester.pump(kGraphicSubtitleOcrSettleDelay);
      await tester.pump(const Duration(milliseconds: 500));
      expect(probe.captures, 1);
      expect(_hitBoxes, findsNWidgets(_frame.chars.length));
      expect(hint, findsNothing);
      await tester.pump(kGraphicSubtitleOcrStatusHintDuration);
    });

    testWidgets('关闭档 + 文本字幕 / 无字幕：不提示、不识别', (tester) async {
      final VideoPlayerController noSubs = _pausedController(graphic: false);
      addTearDown(noSubs.dispose);
      final _Probe probe = _Probe();
      await tester.pumpWidget(
        _overlay(
          noSubs,
          probe,
          scope: VideoPauseOcrScope.off,
          onEnableRequested: () {},
        ),
      );
      await tester.pump(kGraphicSubtitleOcrSettleDelay * 2);
      expect(hint, findsNothing, reason: '无字幕不提示');
      expect(probe.captures, 0);

      final VideoPlayerController text = _pausedController(graphic: false);
      addTearDown(text.dispose);
      text.setCues(<AudioCue>[_textCue('テキスト字幕')]);
      text.debugUpdateCueForPosition(5000);
      await tester.pumpWidget(
        _overlay(
          text,
          probe,
          scope: VideoPauseOcrScope.off,
          onEnableRequested: () {},
        ),
      );
      await tester.pump(kGraphicSubtitleOcrSettleDelay * 2);
      expect(hint, findsNothing, reason: '文本字幕不提示');
      expect(probe.captures, 0);
    });

    testWidgets('播放中不提示；关掉提示后本次不再出现', (tester) async {
      final VideoPlayerController c = _pausedController(graphic: true);
      addTearDown(c.dispose);
      c.debugSetIsPlayingForTesting(true);
      final _Probe probe = _Probe();
      await tester.pumpWidget(
        _overlay(
          c,
          probe,
          scope: VideoPauseOcrScope.off,
          onEnableRequested: () {},
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(hint, findsNothing, reason: '播放中不打扰');

      c.debugSetIsPlayingForTesting(false);
      await tester.pump(const Duration(milliseconds: 500));
      expect(hint, findsOneWidget);

      await tester.tap(
        find.byKey(
          const ValueKey<String>('graphic_subtitle_ocr_enable_dismiss'),
        ),
      );
      // 第一帧开始淡出动画，再推过淡出时长。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(hint, findsNothing);

      c.debugSetIsPlayingForTesting(true);
      await tester.pump();
      c.debugSetIsPlayingForTesting(false);
      await tester.pump(const Duration(milliseconds: 500));
      expect(hint, findsNothing, reason: '关掉后本次播放不再提示');
      expect(probe.captures, 0);
    });

    testWidgets('所有视频档的普通画面：状态标记说「画面文字」而不是「字幕」', (tester) async {
      final VideoPlayerController c = _pausedController(graphic: false);
      addTearDown(c.dispose);
      final _Probe probe = _Probe();
      await tester.pumpWidget(
        _overlay(c, probe, scope: VideoPauseOcrScope.all),
      );
      await tester.pump(kGraphicSubtitleOcrSettleDelay);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.text(t.video_subtitle_frame_ocr_status_ready),
        findsOneWidget,
      );
      expect(
        find.text(t.video_subtitle_graphic_ocr_status_ready),
        findsNothing,
      );
      await tester.pump(kGraphicSubtitleOcrStatusHintDuration);
    });
  });

  group('graphicSubtitlePauseOcrStatus', () {
    test('只有识别结果标记会自动淡出', () {
      expect(
        graphicSubtitlePauseOcrStatusAutoHides(
          GraphicSubtitlePauseOcrStatus.ready,
        ),
        isTrue,
      );
      expect(
        graphicSubtitlePauseOcrStatusAutoHides(
          GraphicSubtitlePauseOcrStatus.empty,
        ),
        isTrue,
      );
      expect(
        graphicSubtitlePauseOcrStatusAutoHides(
          GraphicSubtitlePauseOcrStatus.recognizing,
        ),
        isFalse,
      );
    });
  });
}
