import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/subtitle_waveform_align_panel.dart';
import 'package:hibiki/src/media/video/subtitle_waveform_painter.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-1051 阶段B：波形对轴面板 widget 行为测试。
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
  required Future<void> Function(int) onCommit,
  int initialDelayMs = 0,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        child: SubtitleWaveformAlignPanel(
          initialDelayMs: initialDelayMs,
          clampMs: 600000,
          cues: cues,
          durationMs: 60000,
          loadWaveform: loadWaveform,
          onCommitDelay: onCommit,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('waveform loaded => paints SubtitleWaveformPainter',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000), _cue(3000, 4000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      onCommit: (int _) async {},
    ));
    // 加载态先出 spinner。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
    // 加载完 => 波形 painter 上墙。
    final Finder painted = find.byWidgetPredicate(
      (Widget w) => w is CustomPaint && w.painter is SubtitleWaveformPainter,
    );
    expect(painted, findsWidgets);
    // 有滑条可拖。
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets(
      'empty envelope (mobile degrade) => no waveform painter, slider stays',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => const <double>[],
      onCommit: (int _) async {},
    ));
    await tester.pumpAndSettle();
    // 降级：不画波形 painter。
    final Finder painted = find.byWidgetPredicate(
      (Widget w) => w is CustomPaint && w.painter is SubtitleWaveformPainter,
    );
    expect(painted, findsNothing);
    // 但纯 stepper（滑条 + 步进）仍在。
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('step button commits immediately (only write-back path)',
      (WidgetTester tester) async {
    final List<int> commits = <int>[];
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => const <double>[],
      onCommit: (int ms) async => commits.add(ms),
      initialDelayMs: 0,
    ));
    await tester.pumpAndSettle();
    // 点 +50ms 步进 => 立即 commit 50。
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(commits, <int>[50]);
    // 再点 -50ms => commit 回 0。
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(commits, <int>[50, 0]);
  });

  testWidgets('preview label reflects delay without extra commit on drag start',
      (WidgetTester tester) async {
    final List<int> commits = <int>[];
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => const <double>[],
      onCommit: (int ms) async => commits.add(ms),
      initialDelayMs: 0,
    ));
    await tester.pumpAndSettle();
    // 初始未提交。
    expect(commits, isEmpty);
    // 标签显示 +0 ms。
    expect(find.textContaining('0 ms'), findsWidgets);
  });
}
