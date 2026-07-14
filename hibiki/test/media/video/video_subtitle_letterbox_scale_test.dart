import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG-818 守卫：ASS 字号/描边的缩放基准必须是 fit:contain 后的**视频内容矩形**
/// （mpv/libass 锚定视频帧显示尺寸，与 `\pos` 定位的 [mapPosFractionToContainer]
/// 同一几何），不是 overlay 容器——窗口比≠视频比（letterbox）时按容器缩放整体偏大。
AudioCue _cue() => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'c'
  ..sentenceIndex = 0
  ..textFragmentId = '[data-cue-id="0"]'
  ..text = 'あ'
  ..markup = const SubtitleMarkup(
    plainText: 'あ',
    spans: <SubtitleSpan>[],
    cueStyle: SubtitleCueStyle(fontSizePx: 65, outlineWidthPx: 2.5),
    playResY: 1080,
  )
  ..startMs = 0
  ..endMs = 5000
  ..audioFileIndex = 0;

Future<void> _pump(
  WidgetTester tester, {
  required int? videoW,
  required int? videoH,
}) async {
  // 默认测试视口 800×600 会把 640×640 容器夹矮；放大视口让容器如实成方形。
  tester.view.physicalSize = const Size(1000, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
  c.debugVideoWidthOverride = videoW;
  c.debugVideoHeightOverride = videoH;
  c.setCues(<AudioCue>[_cue()]);
  c.debugUpdateCueForPosition(1);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 640,
          height: 640, // 方形容器：16:9 视频 letterbox，内容高 = 640×1080/1920 = 360
          child: VideoSubtitleOverlay(
            controller: c,
            fontSize: 36,
            shadowThickness: 5,
            respectAssStyle: true,
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

Text _fill(WidgetTester tester) => tester
    .widgetList<Text>(find.text('あ'))
    .firstWhere((Text t) => t.style?.foreground == null);
Text _stroke(WidgetTester tester) => tester
    .widgetList<Text>(find.text('あ'))
    .firstWhere((Text t) => t.style?.foreground != null);

void main() {
  testWidgets(
      'letterboxed container: font/outline scale by video content height, '
      'not container height (BUG-818)', (WidgetTester tester) async {
    await _pump(tester, videoW: 1920, videoH: 1080);
    // 内容矩形高 = 640×(1080/1920) = 360 → 字号 65×360/1080 = 21.67，
    // 而非容器基准的 65×640/1080 = 38.5（偏大 78%）。
    expect(_fill(tester).style?.fontSize, closeTo(65 * 360 / 1080, 0.01));
    expect(_stroke(tester).style?.foreground?.strokeWidth,
        closeTo(2.5 * 360 / 1080, 0.01));
  });

  testWidgets(
      'video resolution unknown: falls back to container height (historical)',
      (WidgetTester tester) async {
    await _pump(tester, videoW: null, videoH: null);
    expect(_fill(tester).style?.fontSize, closeTo(65 * 640 / 1080, 0.01));
  });
}
