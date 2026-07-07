import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/subtitle_waveform_align_panel.dart';
import 'package:hibiki/src/media/video/subtitle_waveform_painter.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-1315 lazy waveform render / TODO-1316 in-zoom auto-align button tests.
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
  Future<int?> Function()? onAutoAlign,
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
            onAutoAlign: onAutoAlign,
            onPlayCue: onPlayCue,
          ),
        ),
      ),
    ),
  );
}

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

/// TODO-1315: tapping the entry lazily probes then opens the zoom dialog.
Future<void> _openZoom(WidgetTester tester) async {
  await tester.tap(find.byKey(_openKey));
  await tester.pumpAndSettle();
}

/// The zoom view's single FilledButton is the auto-align button (TODO-1316).
Finder get _autoAlignButton => find.descendant(
      of: find.byType(SubtitleWaveformZoomView),
      matching: find.byType(FilledButton),
    );

void main() {
  testWidgets('TODO-1315: mount does NOT probe waveform (lazy); entry visible',
      (WidgetTester tester) async {
    int loads = 0;
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async {
        loads++;
        return <double>[-60, -20, -40, -10, -30, -5];
      },
    ));
    await tester.pumpAndSettle();
    expect(loads, 0);
    expect(find.byKey(_openKey), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(SubtitleWaveformZoomView), findsNothing);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is CustomPaint && w.painter is SubtitleWaveformPainter,
      ),
      findsNothing,
    );
  });

  testWidgets(
      'TODO-1315: tap entry probes once then opens zoom (legend+slider)',
      (WidgetTester tester) async {
    int loads = 0;
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000), _cue(3000, 4000)],
      loadWaveform: () async {
        loads++;
        return <double>[-60, -20, -40, -10, -30, -5];
      },
      onCommitDelay: (int _) async {},
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    expect(loads, 1);
    expect(find.byType(SubtitleWaveformZoomView), findsOneWidget);
    expect(find.text(t.video_subtitle_waveform_legend_energy), findsOneWidget);
    expect(find.text(t.video_subtitle_waveform_legend_cue), findsOneWidget);
    expect(
        find.text(t.video_subtitle_waveform_legend_playhead), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets(
      'TODO-1315: empty envelope (mobile degrade) => unavailable hint, no dialog',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => const <double>[],
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    expect(find.byType(SubtitleWaveformZoomView), findsNothing);
    expect(find.text(t.video_subtitle_waveform_unavailable), findsOneWidget);
  });

  testWidgets(
      'TODO-1315: closing zoom view releases envelope; re-open re-probes',
      (WidgetTester tester) async {
    int loads = 0;
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async {
        loads++;
        return <double>[-60, -20, -40, -10, -30, -5];
      },
      onCommitDelay: (int _) async {},
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    expect(loads, 1);
    expect(find.byType(SubtitleWaveformZoomView), findsOneWidget);
    await tester.tap(find.descendant(
      of: find.byType(SubtitleWaveformZoomView),
      matching: find.byIcon(Icons.close),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(SubtitleWaveformZoomView), findsNothing);
    await _openZoom(tester);
    expect(loads, 2);
    expect(find.byType(SubtitleWaveformZoomView), findsOneWidget);
  });

  testWidgets('TODO-1316: zoom auto-align button calls onAutoAlign + commits',
      (WidgetTester tester) async {
    final List<int> committed = <int>[];
    int autoCalls = 0;
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      onCommitDelay: (int ms) async => committed.add(ms),
      onAutoAlign: () async {
        autoCalls++;
        return 250;
      },
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    expect(_zoomPainter(tester).previewDelayMs, 0);
    expect(_autoAlignButton, findsOneWidget);
    await tester.ensureVisible(_autoAlignButton);
    await tester.pumpAndSettle();
    await tester.tap(_autoAlignButton);
    await tester.pumpAndSettle();
    expect(autoCalls, 1);
    expect(committed, <int>[250]);
    expect(_zoomPainter(tester).previewDelayMs, 250);
  });

  testWidgets('TODO-1316: auto-align low confidence (null) => hint, no commit',
      (WidgetTester tester) async {
    final List<int> committed = <int>[];
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      onCommitDelay: (int ms) async => committed.add(ms),
      onAutoAlign: () async => null,
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    await tester.ensureVisible(_autoAlignButton);
    await tester.pumpAndSettle();
    await tester.tap(_autoAlignButton);
    await tester.pumpAndSettle();
    expect(committed, isEmpty);
    expect(_zoomPainter(tester).previewDelayMs, 0);
    expect(
        find.text(t.video_subtitle_auto_align_low_confidence), findsOneWidget);
  });

  testWidgets('TODO-1316: no onAutoAlign => no auto-align button in zoom view',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      onCommitDelay: (int _) async {},
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    expect(find.byType(SubtitleWaveformZoomView), findsOneWidget);
    expect(_autoAlignButton, findsNothing);
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
    await _openZoom(tester);
    expect(_zoomPainter(tester).previewDelayMs, 0);
    final Finder plus = find.descendant(
      of: find.byType(SubtitleWaveformZoomView),
      matching: find.byIcon(Icons.chevron_right),
    );
    await tester.ensureVisible(plus);
    await tester.pumpAndSettle();
    await tester.tap(plus);
    await tester.pumpAndSettle();
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
    await _openZoom(tester);
    final int before = _zoomPainter(tester).previewDelayMs;
    await tester.drag(
      find.descendant(
        of: find.byType(SubtitleWaveformZoomView),
        matching: find.byType(Scrollbar),
      ),
      const Offset(-160, 0),
    );
    await tester.pumpAndSettle();
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
    await _openZoom(tester);
    expect(find.text('ohayou'), findsOneWidget);
    expect(find.text('konbanwa'), findsOneWidget);
  });

  testWidgets('TODO-1244: empty-text cues render no strip chip',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
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
    await _openZoom(tester);
    expect(find.byIcon(Icons.play_circle_outline), findsWidgets);
    await tester.tap(find.text('ohayou'));
    await tester.pumpAndSettle();
    expect(played, <int>[1000]);
  });

  testWidgets(
      'TODO-1244: per-cue play seeks to shifted time (start + preview delay)',
      (WidgetTester tester) async {
    final List<int> played = <int>[];
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000, text: 'ohayou')],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      initialDelayMs: 200,
      onCommitDelay: (int _) async {},
      onPlayCue: (int startMs) async => played.add(startMs),
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    expect(_zoomPainter(tester).previewDelayMs, 200);
    await tester.tap(find.text('ohayou'));
    await tester.pumpAndSettle();
    expect(played, <int>[1200]);
  });
}
