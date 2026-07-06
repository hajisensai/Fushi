import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/subtitle_waveform_align_panel.dart';
import 'package:hibiki/src/media/video/subtitle_waveform_painter.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-1051 阶段B / TODO-1207：波形对轴面板（纯可视化，已删自带滑条）widget 行为测试。
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
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        child: SubtitleWaveformAlignPanel(
          initialDelayMs: initialDelayMs,
          cues: cues,
          durationMs: 60000,
          loadWaveform: loadWaveform,
        ),
      ),
    ),
  );
}

/// 取当前上墙的波形 painter（用于断言 previewDelayMs 平移量）。
SubtitleWaveformPainter _painterOf(WidgetTester tester) {
  final CustomPaint paint =
      tester.widgetList<CustomPaint>(find.byType(CustomPaint)).firstWhere(
            (CustomPaint w) => w.painter is SubtitleWaveformPainter,
          );
  return paint.painter! as SubtitleWaveformPainter;
}

void main() {
  testWidgets('waveform loaded => paints SubtitleWaveformPainter, no slider',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000), _cue(3000, 4000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
    ));
    // 加载态先出 spinner。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
    // 加载完 => 波形 painter 上墙。
    final Finder painted = find.byWidgetPredicate(
      (Widget w) => w is CustomPaint && w.painter is SubtitleWaveformPainter,
    );
    expect(painted, findsWidgets);
    // TODO-1207：面板不再自带调轴滑条（与上方冗余，已删）。
    expect(find.byType(Slider), findsNothing);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets(
      'empty envelope (mobile degrade) => panel collapses, still no slider',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => const <double>[],
    ));
    await tester.pumpAndSettle();
    // 降级：不画波形 painter。
    final Finder painted = find.byWidgetPredicate(
      (Widget w) => w is CustomPaint && w.painter is SubtitleWaveformPainter,
    );
    expect(painted, findsNothing);
    // 无滑条 / 步进（纯可视化收起）。
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets(
      'TODO-1206/1207: initialDelayMs change (auto-align/manual) shifts cue '
      'lines via didUpdateWidget', (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000), _cue(3000, 4000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      initialDelayMs: 0,
    ));
    await tester.pumpAndSettle();
    // 初始预览延迟 = 0。
    expect(_painterOf(tester).previewDelayMs, 0);

    // 上方面板改延迟（等价自动对轴/手动调轴）→ 重建面板换新 initialDelayMs。
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000), _cue(3000, 4000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      initialDelayMs: 750,
    ));
    await tester.pumpAndSettle();
    // didUpdateWidget 同步 => 波形 cue 线平移到新延迟。
    expect(_painterOf(tester).previewDelayMs, 750);
  });
}
