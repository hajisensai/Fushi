// BUG-2538：`\p` 绘图事件的播放侧数据流 + 渲染。
//
// - [VideoPlayerController.setCues] 把绘图事件分流到渲染专用流：对白流（cues /
//   currentCue / activeCues）不见它，overlay 经 activeDrawingCues 取同刻在屏的绘图；
// - overlay 用 [AssDrawingPainter] 画路径，盒尺寸 = 包围盒 × 显示缩放，按 `\an`/`\pos`
//   落位（libass 语义：绘图按包围盒对齐，不按坐标原点）；纯字幕模式不画。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

const String _kHead = r'''
[Script Info]
PlayResX: 1280
PlayResY: 720

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1
Style: Sign,Arial,40,&H00000000,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Sign,,0,0,0,,{\an7\pos(100,50)\1c&HFFFFFF&\p1}m 0 0 l 200 0 200 100 0 100{\p0}
Dialogue: 1,0:00:01.00,0:00:04.00,Default,,0,0,0,,That is why.
''';

List<AudioCue> _cues() => AssParser.parseString(
    content: _kHead, bookKey: 'b', includeDrawings: true);

Future<VideoPlayerController> _pump(WidgetTester tester,
    {required bool respect}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final VideoPlayerController c = VideoPlayerController()
    ..debugVideoWidthOverride = 1280
    ..debugVideoHeightOverride = 720;
  addTearDown(c.dispose);
  c.setCues(_cues());
  c.debugSetPositionForTesting(2000);
  c.debugUpdateCueForPosition(2000);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1280,
        height: 720,
        child: VideoSubtitleOverlay(controller: c, respectAssStyle: respect),
      ),
    ),
  ));
  await tester.pump();
  return c;
}

Finder _painterFinder() => find.byWidgetPredicate(
    (Widget w) => w is CustomPaint && w.painter is AssDrawingPainter);

void main() {
  test('controller：绘图事件分流到渲染专用流，对白流零污染', () {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(_cues());
    expect(c.cues.map((AudioCue x) => x.text), <String>['That is why.']);
    expect(c.drawingCues, hasLength(1));
    c.debugUpdateCueForPosition(2000);
    expect(c.currentCue!.text, 'That is why.');
    expect(c.activeCues.every((AudioCue x) => !x.isRenderOnly), isTrue);
    expect(c.activeDrawingCues, hasLength(1));
    // 离开时间窗：绘图活动集清空。
    c.debugUpdateCueForPosition(5000);
    expect(c.activeDrawingCues, isEmpty);
  });

  testWidgets('respect ON：白填充绘图按包围盒落在 \\an7\\pos(100,50)，盒 200×100',
      (WidgetTester tester) async {
    await _pump(tester, respect: true);
    expect(_painterFinder(), findsOneWidget);
    final Rect r = tester.getRect(_painterFinder());
    expect(r.left, closeTo(100, 0.5));
    expect(r.top, closeTo(50, 0.5));
    expect(r.width, closeTo(200, 0.5));
    expect(r.height, closeTo(100, 0.5));
    final AssDrawingPainter p =
        tester.widget<CustomPaint>(_painterFinder()).painter!
            as AssDrawingPainter;
    expect(p.fill, const Color(0xFFFFFFFF), reason: '\\1c&HFFFFFF& 白填充');
    expect(p.strokeWidth, 0, reason: 'Sign 样式 Outline=0 → 不描边');
    // 路径在盒内：包围盒左上角即盒原点。
    final Rect bounds = p.buildPath().getBounds();
    expect(bounds.left, closeTo(0, 1e-6));
    expect(bounds.top, closeTo(0, 1e-6));
    expect(bounds.width, closeTo(200, 1e-6));
    expect(bounds.height, closeTo(100, 1e-6));
    // 对白照常渲染。
    expect(find.text('T'), findsWidgets);
  });

  testWidgets('respect OFF（纯字幕模式）：不画图形', (WidgetTester tester) async {
    await _pump(tester, respect: false);
    expect(_painterFinder(), findsNothing);
    expect(find.text('T'), findsWidgets);
  });

  test('AssDrawingPainter：每个 m 起一个闭合子路径，非零环绕', () {
    const SubtitleDrawing d = SubtitleDrawing(
      segments: <SubtitleClipSegment>[
        SubtitleClipSegment.move(0, 0),
        SubtitleClipSegment.line(0.5, 0),
        SubtitleClipSegment.line(0.5, 0.5),
        SubtitleClipSegment.move(0.6, 0.6),
        SubtitleClipSegment.line(1, 0.6),
        SubtitleClipSegment.line(1, 1),
      ],
      minX: 0,
      minY: 0,
      maxX: 1,
      maxY: 1,
    );
    const AssDrawingPainter p = AssDrawingPainter(
      shape: d,
      scaleX: 100,
      scaleY: 100,
      fill: Color(0xFFFFFFFF),
      strokeColor: Color(0xFF000000),
      strokeWidth: 0,
    );
    final Path path = p.buildPath();
    expect(path.fillType, PathFillType.nonZero);
    expect(path.contains(const Offset(10, 2)), isTrue, reason: '第一个三角形内');
    expect(path.contains(const Offset(90, 65)), isTrue, reason: '第二个三角形内');
    expect(path.contains(const Offset(55, 55)), isFalse, reason: '两形之间是空');
    expect(path.getBounds(), const Rect.fromLTWH(0, 0, 100, 100));
  });
}
