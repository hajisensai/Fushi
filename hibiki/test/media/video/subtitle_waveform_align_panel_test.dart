import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/subtitle_waveform_align_panel.dart';
import 'package:hibiki/src/media/video/subtitle_waveform_painter.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-1051 阶段B / TODO-1207：波形对轴入口面板（按钮触发放大可交互视图）widget 行为测试。
AudioCue _cue(int startMs, int endMs, {String text = ''}) {
  return AudioCue()
    ..bookKey = ''
    ..chapterHref = ''
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = text
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}

Widget _host({
  required List<AudioCue> cues,
  required Future<List<double>> Function() loadWaveform,
  int initialDelayMs = 0,
  Future<void> Function(int delayMs)? onCommitDelay,
  Future<void> Function(int startMs)? onPlayCue,
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
            onPlayCue: onPlayCue,
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
    // 点 +50ms 步进（放大视图里唯一的 chevron_right）。文本条让对轴弹窗更高，调轴控件
    // 在滚动区下方——测试先滚到它再点（真机弹窗 SingleChildScrollView 可滚，非溢出）。
    final Finder plus = find.descendant(
      of: find.byType(SubtitleWaveformZoomView),
      matching: find.byIcon(Icons.chevron_right),
    );
    await tester.ensureVisible(plus);
    await tester.pumpAndSettle();
    await tester.tap(plus);
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

  testWidgets('TODO-1244: zoom view shows cue text on the aligned strip',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[
        _cue(1000, 2000, text: 'ohayou'),
        _cue(3000, 4000, text: 'konbanwa'),
      ],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    // 每句字幕文本按时间位置铺在波形下方的文本条上（用户一眼看出哪段是哪句）。
    expect(find.text('ohayou'), findsOneWidget);
    expect(find.text('konbanwa'), findsOneWidget);
  });

  testWidgets('TODO-1244: empty-text cues render no strip chip',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)], // 无文本
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    // 无 onPlayCue + 无文本 => 文本条无播放按钮、无文字片段。
    expect(find.byIcon(Icons.play_circle_outline), findsNothing);
  });

  testWidgets('TODO-1244: tapping a cue chip seeks+plays that line (delay 0)',
      (WidgetTester tester) async {
    final List<int> played = <int>[];
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000, text: 'ohayou')],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      onPlayCue: (int startMs) async => played.add(startMs),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    // 有 onPlayCue => 每句旁挂播放按钮。
    expect(find.byIcon(Icons.play_circle_outline), findsWidgets);
    // 点该句片段 => 播放器 seek 到该句起点（延迟 0，seek == startMs）。
    await tester.tap(find.text('ohayou'));
    await tester.pumpAndSettle();
    expect(played, <int>[1000]);
  });

  testWidgets(
      'TODO-1244: per-cue play seeks to shifted time (start + preview delay)',
      (WidgetTester tester) async {
    final List<int> played = <int>[];
    // 已带 +200ms 延迟打开：cue 线与文本片段整体平移，试听应跳到「叠加延迟后」的位置。
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000, text: 'ohayou')],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      initialDelayMs: 200,
      onCommitDelay: (int _) async {},
      onPlayCue: (int startMs) async => played.add(startMs),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    // 试听跳到 start + delay = 1000 + 200：核对移动后的 cue 线是否压在语音峰值上。
    await tester.tap(find.text('ohayou'));
    await tester.pumpAndSettle();
    expect(played, <int>[1200]);
  });
}
