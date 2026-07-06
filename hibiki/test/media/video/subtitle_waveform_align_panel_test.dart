import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/subtitle_waveform_align_panel.dart';
import 'package:hibiki/src/media/video/subtitle_waveform_painter.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-1051 阶段B / TODO-1207：波形对轴入口面板（按钮触发放大可交互视图）widget 行为测试。
AudioCue _cue(int startMs, int endMs) {
  return AudioCue()
    ..bookKey = ''
    ..chapterHref = ''
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = ''
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}

Widget _host({
  required List<AudioCue> cues,
  required Future<List<double>> Function() loadWaveform,
  int initialDelayMs = 0,
  Future<void> Function(int delayMs)? onCommitDelay,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          child: SubtitleWaveformAlignPanel(
            initialDelayMs: initialDelayMs,
            cues: cues,
            durationMs: 60000,
            loadWaveform: loadWaveform,
            onCommitDelay: onCommitDelay,
          ),
        ),
      ),
    ),
  );
}

/// 面板缩略图上墙的波形 painter（关闭放大视图时唯一的 SubtitleWaveformPainter）。
SubtitleWaveformPainter _thumbPainter(WidgetTester tester) {
  final CustomPaint paint =
      tester.widgetList<CustomPaint>(find.byType(CustomPaint)).firstWhere(
            (CustomPaint w) => w.painter is SubtitleWaveformPainter,
          );
  return paint.painter! as SubtitleWaveformPainter;
}

/// 放大视图里的波形 painter（限定在 SubtitleWaveformZoomView 子树内）。
SubtitleWaveformPainter _zoomPainter(WidgetTester tester) {
  final CustomPaint paint = tester
      .widgetList<CustomPaint>(find.descendant(
        of: find.byType(SubtitleWaveformZoomView),
        matching: find.byType(CustomPaint),
      ))
      .firstWhere((CustomPaint w) => w.painter is SubtitleWaveformPainter);
  return paint.painter! as SubtitleWaveformPainter;
}

const Key _openKey = ValueKey<String>('subtitle-waveform-open-button');

void main() {
  testWidgets('loaded => compact entry button, no dialog/slider yet',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000), _cue(3000, 4000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
    // 入口按钮上墙；放大视图未打开。
    expect(find.byKey(_openKey), findsOneWidget);
    expect(find.byType(SubtitleWaveformZoomView), findsNothing);
    // 面板本体不含调轴滑条（调轴在放大视图里）。
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('empty envelope (mobile degrade) => no entry button, no painter',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => const <double>[],
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(_openKey), findsNothing);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is CustomPaint && w.painter is SubtitleWaveformPainter,
      ),
      findsNothing,
    );
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets(
      'TODO-1206/1207: initialDelayMs change shifts thumbnail cue lines',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      initialDelayMs: 0,
    ));
    await tester.pumpAndSettle();
    expect(_thumbPainter(tester).previewDelayMs, 0);
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      initialDelayMs: 750,
    ));
    await tester.pumpAndSettle();
    expect(_thumbPainter(tester).previewDelayMs, 750);
  });

  testWidgets('tap entry => opens zoom view with legend + align slider',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000), _cue(3000, 4000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      onCommitDelay: (int _) async {},
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    expect(find.byType(SubtitleWaveformZoomView), findsOneWidget);
    // 图例三层都在。
    expect(find.text(t.video_subtitle_waveform_legend_energy), findsOneWidget);
    expect(find.text(t.video_subtitle_waveform_legend_cue), findsOneWidget);
    expect(
        find.text(t.video_subtitle_waveform_legend_playhead), findsOneWidget);
    // 调轴滑条在放大视图里。
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('zoom view +50 step writes back _delayMs via onCommitDelay',
      (WidgetTester tester) async {
    final List<int> committed = <int>[];
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      onCommitDelay: (int ms) async => committed.add(ms),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    expect(_zoomPainter(tester).previewDelayMs, 0);
    // 点 +50ms 步进（放大视图里唯一的 chevron_right）。
    await tester.tap(find.descendant(
      of: find.byType(SubtitleWaveformZoomView),
      matching: find.byIcon(Icons.chevron_right),
    ));
    await tester.pumpAndSettle();
    // 写回上方权威 _delayMs（onCommitDelay 收到 50），波形 cue 线随之平移。
    expect(committed, <int>[50]);
    expect(_zoomPainter(tester).previewDelayMs, 50);
  });

  testWidgets('horizontal scan drag over waveform does NOT change delay',
      (WidgetTester tester) async {
    final List<int> committed = <int>[];
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5, -50, -12],
      onCommitDelay: (int ms) async => committed.add(ms),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    final int before = _zoomPainter(tester).previewDelayMs;
    // 在波形区横向拖动（平移查看时间轴）——只滚动，不调轴。
    await tester.drag(
      find.descendant(
        of: find.byType(SubtitleWaveformZoomView),
        matching: find.byType(Scrollbar),
      ),
      const Offset(-160, 0),
    );
    await tester.pumpAndSettle();
    // 无任何延迟提交，波形延迟不变（平移查看与调轴手势物理分离，永不冲突）。
    expect(committed, isEmpty);
    expect(_zoomPainter(tester).previewDelayMs, before);
  });
}
