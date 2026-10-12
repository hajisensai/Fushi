// 暂停 OCR 覆盖层：识别完成标记到时淡出（反馈 YtbinN_pBG / -6dAnq8S6f）、
// 无图形字幕的视频按开关识别（反馈 i5A0mu1-AT）。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_stream_ocr.dart'
    show MangaStreamOcrSetup;
import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_ocr_overlay.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_ocr_progress.dart';
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
  bool ocrWithoutSubtitleTrack = false,
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
          ocrWithoutSubtitleTrack: ocrWithoutSubtitleTrack,
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

  testWidgets('没有图形字幕：开关关时不识别，开了且无文本字幕才识别', (tester) async {
    final VideoPlayerController c = _pausedController(graphic: false);
    addTearDown(c.dispose);
    final _Probe probe = _Probe();

    await tester.pumpWidget(_overlay(c, probe));
    await tester.pump(kGraphicSubtitleOcrSettleDelay * 2);
    expect(probe.captures, 0, reason: '默认关：无图形字幕的视频不做暂停 OCR');

    await tester.pumpWidget(_overlay(c, probe, ocrWithoutSubtitleTrack: true));
    await tester.pump(kGraphicSubtitleOcrSettleDelay);
    await tester.pump(const Duration(milliseconds: 500));
    expect(probe.captures, 1, reason: '打开开关后，硬字幕视频暂停即识别');
    expect(_hitBoxes, findsNWidgets(_frame.chars.length));
    await tester.pump(kGraphicSubtitleOcrStatusHintDuration);
  });

  testWidgets('开关开着但有文本字幕 cue：不识别（不与字幕查词抢点击）', (tester) async {
    final VideoPlayerController c = _pausedController(graphic: false);
    addTearDown(c.dispose);
    c.setCues(<AudioCue>[
      AudioCue()
        ..bookKey = ''
        ..chapterHref = ''
        ..sentenceIndex = 0
        ..textFragmentId = ''
        ..text = 'テキスト字幕'
        ..startMs = 4000
        ..endMs = 7000
        ..audioFileIndex = 0,
    ]);
    final _Probe probe = _Probe();
    await tester.pumpWidget(_overlay(c, probe, ocrWithoutSubtitleTrack: true));
    await tester.pump(kGraphicSubtitleOcrSettleDelay * 2);
    expect(probe.captures, 0);
    expect(_hitBoxes, findsNothing);
  });

  group('graphicSubtitlePauseOcrEligible', () {
    bool eligible({
      bool playing = false,
      bool hasFirstFrame = true,
      bool graphic = false,
      bool toggle = false,
      bool cues = false,
      bool loading = false,
    }) => graphicSubtitlePauseOcrEligible(
      playing: playing,
      hasFirstFrame: hasFirstFrame,
      playerRenderedSubtitle: graphic,
      ocrWithoutSubtitleTrack: toggle,
      hasTextCues: cues,
      textCuesLoading: loading,
    );

    test('图形字幕暂停即识别，与开关无关', () {
      expect(eligible(graphic: true), isTrue);
      expect(eligible(graphic: true, playing: true), isFalse);
      expect(eligible(graphic: true, hasFirstFrame: false), isFalse);
    });

    test('无图形字幕：需开关 + 无文本 cue + 不在加载', () {
      expect(eligible(), isFalse);
      expect(eligible(toggle: true), isTrue);
      expect(eligible(toggle: true, cues: true), isFalse);
      expect(eligible(toggle: true, loading: true), isFalse);
      expect(eligible(toggle: true, playing: true), isFalse);
    });

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
