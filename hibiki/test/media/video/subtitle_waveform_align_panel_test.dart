import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool Function()? isPlaying,
  Future<void> Function()? onTogglePlayPause,
  Map<ShortcutActivator, VoidCallback>? keyboardShortcuts,
  Future<void> Function(int positionMs)? onSeek,
  int Function()? currentPositionMs,
  Listenable? positionListenable,
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
            isPlaying: isPlaying,
            onTogglePlayPause: onTogglePlayPause,
            keyboardShortcuts: keyboardShortcuts,
            onSeek: onSeek,
            currentPositionMs: currentPositionMs,
            positionListenable: positionListenable,
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

/// 波形 [CustomPaint] 的高度（= 当前 _waveHeight）。拖调节把手后应随之变化。
double _waveHeight(WidgetTester tester) {
  final CustomPaint paint = tester
      .widgetList<CustomPaint>(find.descendant(
        of: find.byType(SubtitleWaveformZoomView),
        matching: find.byType(CustomPaint),
      ))
      .firstWhere((CustomPaint w) => w.painter is SubtitleWaveformPainter);
  return paint.size.height;
}

const Key _resizeKey = ValueKey<String>('subtitle-waveform-resize-handle');

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

  // TODO-1315 回归守卫（BUG-623）：入口按钮**永不**因波形探测结果消失。历史上
  // 挂载时预探测、探测为空即 [SizedBox.shrink] 收起整个入口，弱设备 / 移动端因此「字幕调轴
  // 入口也没了、进不去」。现在入口常驻可见：挂载即在、点击探测为空只内联提示不可用、入口
  // 仍在可重试。这三态（挂载 / 探测中 / 探测空）下入口 key 都必须 findsOneWidget。
  testWidgets(
      'TODO-1315 guard: entry button never disappears (mount / probing / empty)',
      (WidgetTester tester) async {
    final Completer<List<double>> gate = Completer<List<double>>();
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () => gate.future,
    ));
    await tester.pumpAndSettle();
    // 挂载态：入口在，无 spinner（未预探测）。
    expect(find.byKey(_openKey), findsOneWidget);
    expect(find.byType(SubtitleWaveformZoomView), findsNothing);

    // 点击进入探测中态：入口仍在（切成 spinner），探测未完成。
    await tester.tap(find.byKey(_openKey));
    await tester.pump();
    expect(find.byKey(_openKey), findsOneWidget);

    // 探测返回空包络（移动端降级）：入口仍在、不弹窗、内联提示不可用。
    gate.complete(const <double>[]);
    await tester.pumpAndSettle();
    expect(find.byKey(_openKey), findsOneWidget);
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
      find.byKey(const ValueKey<String>('subtitle-waveform-hscroll')),
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
    // 文本同时出现在波形文本条与新加的字幕列表里（各一处）。
    expect(find.text('ohayou'), findsWidgets);
    expect(find.text('konbanwa'), findsWidgets);
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
    // 文本条与列表都渲染该句；点第一处（波形文本条 chip）即 seek+play。
    await tester.tap(find.text('ohayou').first);
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
    await tester.tap(find.text('ohayou').first);
    await tester.pumpAndSettle();
    expect(played, <int>[1200]);
  });

  testWidgets('cue list: shows all non-empty cues; empty-text cue is skipped',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[
        _cue(1000, 2000, text: 'ohayou'),
        _cue(2500, 3000), // 空文本：列表与文本条都跳过。
        _cue(3000, 4000, text: 'konbanwa'),
      ],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      onPlayCue: (int _) async {},
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    final Finder list =
        find.byKey(const ValueKey<String>('subtitle-waveform-cue-list'));
    expect(list, findsOneWidget);
    // 列表里两句都在（文本条另有一份，故用 descendant 限定到列表内各一处）。
    expect(find.descendant(of: list, matching: find.text('ohayou')),
        findsOneWidget);
    expect(find.descendant(of: list, matching: find.text('konbanwa')),
        findsOneWidget);
  });

  testWidgets('cue list: tapping a list row seeks+plays that line',
      (WidgetTester tester) async {
    final List<int> played = <int>[];
    await tester.pumpWidget(_host(
      cues: <AudioCue>[
        _cue(1000, 2000, text: 'ohayou'),
        _cue(5000, 6000, text: 'konbanwa'),
      ],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      onPlayCue: (int startMs) async => played.add(startMs),
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    final Finder list =
        find.byKey(const ValueKey<String>('subtitle-waveform-cue-list'));
    final Finder row =
        find.descendant(of: list, matching: find.text('konbanwa'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(played, <int>[5000]);
  });

  testWidgets('no cue list section when all cues are empty-text',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000)],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    expect(find.byKey(const ValueKey<String>('subtitle-waveform-cue-list')),
        findsNothing);
  });

  testWidgets('play/pause button: hidden without callbacks, shown + toggles',
      (WidgetTester tester) async {
    // 无 isPlaying/onTogglePlayPause：不显示播放/暂停按钮。
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000, text: 'ohayou')],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    expect(find.byIcon(Icons.pause), findsNothing);
    // 关掉再用带回调的宿主重开。
    await tester.tap(find.descendant(
      of: find.byType(SubtitleWaveformZoomView),
      matching: find.byIcon(Icons.close),
    ));
    await tester.pumpAndSettle();

    bool playing = true;
    int toggles = 0;
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000, text: 'ohayou')],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      isPlaying: () => playing,
      onTogglePlayPause: () async {
        toggles++;
        playing = !playing;
      },
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    // 播放中显示暂停图标。
    expect(find.byIcon(Icons.pause), findsOneWidget);
    await tester.tap(find.byIcon(Icons.pause));
    await tester.pumpAndSettle();
    expect(toggles, 1);
    // 暂停后图标翻成播放。
    expect(find.byIcon(Icons.play_arrow), findsWidgets);
  });

  testWidgets('playhead ticker: currentPositionMs drives painter live (~30fps)',
      (WidgetTester tester) async {
    int posMs = 1500;
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000, text: 'ohayou')],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      currentPositionMs: () => posMs,
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    expect(_zoomPainter(tester).currentPositionMs, 1500);
    // 位置推进但 controller 未通知（模拟句中）：自驱 ticker 仍在 ~33ms 后刷新播放头。
    posMs = 1750;
    await tester.pump(const Duration(milliseconds: 40));
    expect(_zoomPainter(tester).currentPositionMs, 1750);
    // 关闭放大视图，停掉 ticker（避免 pending timer 泄漏）。
    await tester.tap(find.descendant(
      of: find.byType(SubtitleWaveformZoomView),
      matching: find.byIcon(Icons.close),
    ));
    await tester.pumpAndSettle();
  });

  testWidgets('keyboard shortcuts: space binding fires inside the zoom dialog',
      (WidgetTester tester) async {
    int spaceHits = 0;
    final Map<ShortcutActivator, VoidCallback> shortcuts =
        <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.space): () => spaceHits++,
    };
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000, text: 'ohayou')],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      keyboardShortcuts: shortcuts,
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    // 弹窗自动聚焦 → 空格冒泡到 CallbackShortcuts 命中绑定（视频页快捷键在弹窗夺焦后收不到）。
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(spaceHits, 1);
  });

  testWidgets('waveform tap seeks the playhead to the tapped time',
      (WidgetTester tester) async {
    final List<int> seeks = <int>[];
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000, text: 'ohayou')],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      onSeek: (int ms) async => seeks.add(ms),
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    // 点波形近左缘 → seek 到接近 0 的时间；只验证 tap→seek 接线（几何精度不苛求）。
    final Rect r = tester.getRect(
        find.byKey(const ValueKey<String>('subtitle-waveform-hscroll')));
    await tester.tapAt(Offset(r.left + 2, r.top + 20));
    await tester.pumpAndSettle();
    expect(seeks, hasLength(1));
    expect(seeks.single, inInclusiveRange(0, 60000));
    expect(seeks.single, lessThan(1000)); // 近左缘 → 时间很小
  });

  testWidgets('resize handle: dragging up shrinks the waveform height',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000, text: 'ohayou')],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    expect(find.byKey(_resizeKey), findsOneWidget);
    final double before = _waveHeight(tester);
    // 向上拖把手 → 波形变矮（露出下方控件，短屏不必滚整弹窗）。
    await tester.drag(find.byKey(_resizeKey), const Offset(0, -80));
    await tester.pumpAndSettle();
    final double after = _waveHeight(tester);
    expect(after, lessThan(before));
    expect(after, greaterThanOrEqualTo(96.0)); // 不低于 _minWaveHeight
  });

  testWidgets('resize handle: dragging down grows the waveform height',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      cues: <AudioCue>[_cue(1000, 2000, text: 'ohayou')],
      loadWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
    ));
    await tester.pumpAndSettle();
    await _openZoom(tester);
    final double before = _waveHeight(tester);
    await tester.drag(find.byKey(_resizeKey), const Offset(0, 120));
    await tester.pumpAndSettle();
    final double after = _waveHeight(tester);
    expect(after, greaterThan(before));
    expect(after, lessThanOrEqualTo(360.0)); // 不高于 _maxWaveHeight
  });
}
