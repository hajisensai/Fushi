import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/video_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/video_companion_panel.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiSlider, FushiSwitch;
import 'package:material_ui/material_ui.dart';

import 'companion_panel_harness.dart';

const String _cueA = '今日はいい天気だね。';
const String _cueB = 'うん、散歩でも行こうか。';
const String _cueC = '駅前に新しい店ができたらしいよ。';

Map<String, Object?> _sample({
  bool playing = true,
  bool withInfo = true,
  bool withCues = true,
  bool subtitlesOff = false,
  Map<String, Object?> lineStudy = const <String, Object?>{},
}) => <String, Object?>{
  VideoCompanionKeys.title: 'Episode file 03',
  VideoCompanionKeys.series: 'Playlist name',
  VideoCompanionKeys.episodeIndex: 2,
  VideoCompanionKeys.episodeCount: 12,
  VideoCompanionKeys.playing: playing,
  VideoCompanionKeys.positionMs: 492000,
  VideoCompanionKeys.durationMs: 1420000,
  VideoCompanionKeys.speed: 1.0,
  VideoCompanionKeys.cueStart: withCues ? 490000 : -1,
  VideoCompanionKeys.cues: <Map<String, Object?>>[
    if (withCues) ...<Map<String, Object?>>[
      <String, Object?>{
        VideoCompanionKeys.start: 478000,
        VideoCompanionKeys.end: 480000,
        VideoCompanionKeys.text: _cueA,
      },
      <String, Object?>{
        VideoCompanionKeys.start: 490000,
        VideoCompanionKeys.end: 494000,
        VideoCompanionKeys.text: _cueB,
      },
      <String, Object?>{
        VideoCompanionKeys.start: 495000,
        VideoCompanionKeys.end: 499000,
        VideoCompanionKeys.text: _cueC,
      },
    ],
  ],
  VideoCompanionKeys.audioTracks: <Map<String, Object?>>[
    <String, Object?>{
      VideoCompanionKeys.id: '1',
      VideoCompanionKeys.label: 'Japanese',
      VideoCompanionKeys.selected: true,
    },
    <String, Object?>{
      VideoCompanionKeys.id: '2',
      VideoCompanionKeys.label: 'English',
      VideoCompanionKeys.selected: false,
    },
  ],
  VideoCompanionKeys.subtitleTracks: <Map<String, Object?>>[
    <String, Object?>{
      VideoCompanionKeys.source: 'embedded:0',
      VideoCompanionKeys.label: 'JP full',
      VideoCompanionKeys.selected: !subtitlesOff,
    },
    <String, Object?>{
      VideoCompanionKeys.source: '/subs/ep03.en.srt',
      VideoCompanionKeys.label: 'EN',
      VideoCompanionKeys.selected: false,
    },
  ],
  VideoCompanionKeys.subtitlesOff: subtitlesOff,
  if (withInfo)
    VideoCompanionKeys.info: <String, Object?>{
      VideoCompanionKeys.workTitle: 'Series title',
      VideoCompanionKeys.rating: 8.43,
      VideoCompanionKeys.votes: 1234,
      VideoCompanionKeys.overview: 'Series overview text.',
      VideoCompanionKeys.episodeNumber: 3,
      VideoCompanionKeys.episodeTitle: 'The walk',
      VideoCompanionKeys.episodeOverview: 'Episode overview text.',
    },
  ...lineStudy,
};

List<String> _actions(RecordingCompanionSession rec) =>
    rec.commands.map((CompanionCommandMessage c) => c.action).toList();

Future<RecordingCompanionSession> _pump(
  WidgetTester tester,
  Map<String, Object?> snapshot,
) async {
  final RecordingCompanionSession rec = RecordingCompanionSession();
  rec.show(CompanionContextKind.video, snapshot, title: 'Series title');
  await pumpCompanionPanel(
    tester,
    rec.session,
    VideoCompanionPanel(session: rec.session),
  );
  return rec;
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(VideoCompanionPanel)));

/// Builds [finder]'s target when the panel's lazy list has not built it yet
/// (sections below the first screen): scrolls the panel list (not the line
/// window inside it) down until it exists, then brings it into view.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.hitTestable().evaluate().isNotEmpty) return;
  final ScrollPosition panel = tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position;
  if (finder.evaluate().isEmpty) {
    panel.jumpTo(0);
    await tester.pumpAndSettle();
  }
  for (int i = 0; i < 10 && finder.evaluate().isEmpty; i++) {
    panel.jumpTo(
      (panel.pixels + 200).clamp(0, panel.maxScrollExtent).toDouble(),
    );
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
}

Future<void> _tapButton(WidgetTester tester, String tooltip) async {
  final Finder f = find.byWidgetPredicate(
    (Widget w) => w is Tooltip && w.message == tooltip,
  );
  await _reveal(tester, f);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders header, cached info, times, lines and pickers', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _sample());
    expect(
      find.text(
        '${t.second_screen_video_now_playing} · '
        '${t.second_screen_video_episode(n: 3)}',
      ),
      findsOneWidget,
    );
    expect(
      find.text('★ 8.4 · ${t.second_screen_video_votes(n: 1234)}'),
      findsOneWidget,
    );
    expect(find.text('Series title'), findsOneWidget);
    expect(
      find.text('${t.second_screen_video_episode_short(n: 3)} · The walk'),
      findsOneWidget,
    );
    expect(find.text('8:12'), findsOneWidget);
    expect(find.text('23:40'), findsOneWidget);
    expect(find.text(_cueB), findsOneWidget);
    expect(companionButton(t.pause), findsOneWidget);
    expect(companionButton(t.second_screen_video_info), findsOneWidget);
    await tester.ensureVisible(
      find.text(t.second_screen_video_audio_label(label: 'Japanese')),
    );
    expect(
      find.text(t.second_screen_video_subtitles_label(label: 'JP full')),
      findsOneWidget,
    );
  });

  testWidgets('missing metadata and subtitles: rows hidden, nothing invented', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      _sample(withInfo: false, withCues: false, playing: false),
    );
    // Playlist position stands in for the episode number; no rating line.
    expect(
      find.text(
        '${t.second_screen_video_now_playing} · '
        '${t.second_screen_video_episode(n: 3)}',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('★'), findsNothing);
    expect(find.text('Playlist name'), findsOneWidget);
    expect(
      find.text(
        '${t.second_screen_video_episode_short(n: 3)} · Episode file 03',
      ),
      findsOneWidget,
    );
    expect(companionButton(t.second_screen_video_info), findsNothing);
    expect(companionButton(t.play), findsOneWidget);
    await tester.ensureVisible(find.text(t.second_screen_video_no_subtitles));
    expect(find.text(t.second_screen_video_no_subtitles), findsOneWidget);
  });

  testWidgets('no snapshot yet: waiting state', (WidgetTester tester) async {
    final RecordingCompanionSession rec = RecordingCompanionSession();
    rec.push(
      const CompanionContextMessage(
        CompanionContext(CompanionContextKind.video),
      ),
    );
    await pumpCompanionPanel(
      tester,
      rec.session,
      VideoCompanionPanel(session: rec.session),
    );
    expect(find.text(t.second_screen_video_waiting), findsOneWidget);
  });

  testWidgets('transport buttons send their commands', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    await _tapButton(tester, t.second_screen_video_back_10);
    await _tapButton(tester, t.second_screen_video_previous_line);
    await _tapButton(tester, t.pause);
    await _tapButton(tester, t.second_screen_video_next_line);
    await _tapButton(tester, t.second_screen_video_forward_10);
    expect(
      rec.commands.map((CompanionCommandMessage c) => c.action).toList(),
      <String>[
        VideoCompanionActions.seekBy,
        VideoCompanionActions.previousCue,
        VideoCompanionActions.playPause,
        VideoCompanionActions.nextCue,
        VideoCompanionActions.seekBy,
      ],
    );
    expect(rec.commands.first.args[VideoCompanionKeys.ms], -10000);
    expect(rec.commands.last.args[VideoCompanionKeys.ms], 10000);
    expect(
      rec.commands.every(
        (CompanionCommandMessage c) => c.kind == CompanionContextKind.video,
      ),
      isTrue,
    );
  });

  testWidgets('the slider seeks on release', (WidgetTester tester) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    await tester.drag(find.byType(FushiSlider), const Offset(60, 0));
    await tester.pumpAndSettle();
    final List<CompanionCommandMessage> seeks = rec.commands
        .where(
          (CompanionCommandMessage c) =>
              c.action == VideoCompanionActions.seekTo,
        )
        .toList();
    expect(seeks, hasLength(1));
    final int ms = seeks.single.args[VideoCompanionKeys.ms]! as int;
    expect(ms, greaterThan(492000));
    expect(ms, lessThanOrEqualTo(1420000));
  });

  testWidgets('tap a line jumps, long-press looks it up on the panel', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    await tester.ensureVisible(find.text(_cueC));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_cueC));
    await tester.pumpAndSettle();
    expect(rec.commands.single.action, VideoCompanionActions.jumpToCue);
    expect(rec.commands.single.args, <String, Object?>{
      VideoCompanionKeys.start: 495000,
      VideoCompanionKeys.text: _cueC,
    });

    // Long-press the 4th character (いい天気): the pressed word is looked up,
    // not the start of the line.
    final RenderParagraph line = tester.renderObject<RenderParagraph>(
      find.text(_cueA),
    );
    final Offset caret = line.getOffsetForCaret(
      const TextPosition(offset: 3),
      Rect.zero,
    );
    await tester.longPressAt(
      line.localToGlobal(caret + Offset(4, line.size.height / 2)),
    );
    await tester.pumpAndSettle();
    final CompanionLookupEntry? entry = _container(
      tester,
    ).read(companionLookupControllerProvider).current;
    expect(entry?.text, _cueA);
    expect(entry?.sentence, _cueA);
    expect(entry?.charIndex, 3);
    expect(entry?.term, 'いい天気だね');
    // Looked up on the panel: no round trip to the main screen.
    expect(rec.commands, hasLength(1));
  });

  testWidgets('mine this line sends mineLine', (WidgetTester tester) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    await _tapButton(tester, t.second_screen_video_mine_line);
    expect(rec.commands.single.action, VideoCompanionActions.mineLine);
  });

  testWidgets('audio picker selects a track and goes back', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    await _tapButton(
      tester,
      t.second_screen_video_audio_label(label: 'Japanese'),
    );
    expect(find.text(t.second_screen_video_audio_tracks), findsOneWidget);
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(rec.commands.single.action, VideoCompanionActions.selectAudio);
    expect(rec.commands.single.args[VideoCompanionKeys.id], '2');
    expect(find.text(t.second_screen_video_audio_tracks), findsNothing);
  });

  testWidgets('subtitle picker selects a track or turns subtitles off', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    final String subs = t.second_screen_video_subtitles_label(label: 'JP full');
    await _tapButton(tester, subs);
    await tester.tap(find.text('EN'));
    await tester.pumpAndSettle();
    await _tapButton(tester, subs);
    await tester.tap(find.text(t.second_screen_video_subtitles_off));
    await tester.pumpAndSettle();
    expect(
      rec.commands.map((CompanionCommandMessage c) => c.action).toList(),
      <String>[
        VideoCompanionActions.selectSubtitle,
        VideoCompanionActions.subtitleOff,
      ],
    );
    expect(
      rec.commands.first.args[VideoCompanionKeys.source],
      '/subs/ep03.en.srt',
    );
  });

  testWidgets('subtitles off shows Off on the picker button', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _sample(subtitlesOff: true));
    await tester.ensureVisible(
      find.text(
        t.second_screen_video_subtitles_label(label: t.second_screen_video_off),
      ),
    );
    expect(
      find.text(
        t.second_screen_video_subtitles_label(label: t.second_screen_video_off),
      ),
      findsOneWidget,
    );
  });

  testWidgets('info page shows the cached overviews', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _sample());
    await _tapButton(tester, t.second_screen_video_info);
    expect(find.text('Series overview text.'), findsOneWidget);
    expect(find.text('Episode overview text.'), findsOneWidget);
    expect(find.text(t.second_screen_video_info_series), findsOneWidget);
    await _tapButton(tester, t.back);
    expect(find.text('Series overview text.'), findsNothing);
  });

  testWidgets('following the current line scrolls only the line window', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    final Map<String, Object?> next = Map<String, Object?>.of(_sample())
      ..[VideoCompanionKeys.cueStart] = 495000;
    rec.show(CompanionContextKind.video, next, title: 'Series title');
    await tester.pumpAndSettle();
    final ScrollableState panelList = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(panelList.position.pixels, 0);
    expect(find.text('Series title').hitTestable(), findsOneWidget);
  });

  group('line study', () {
    testWidgets('replay then pause and the A-B button send their commands', (
      WidgetTester tester,
    ) async {
      final RecordingCompanionSession rec = await _pump(tester, _sample());
      expect(find.text(t.second_screen_video_line_study), findsOneWidget);
      await _tapButton(tester, t.second_screen_video_replay_line_pause);
      await _tapButton(tester, t.second_screen_video_ab_set_a);
      expect(_actions(rec), <String>[
        VideoCompanionActions.replayLineThenPause,
        VideoCompanionActions.abLoop,
      ]);
      expect(rec.commands.last.args, <String, Object?>{
        VideoCompanionKeys.step: VideoCompanionAbSteps.a,
      });
    });

    testWidgets('the A-B button follows the loop points', (
      WidgetTester tester,
    ) async {
      final RecordingCompanionSession rec = await _pump(
        tester,
        _sample(
          lineStudy: const <String, Object?>{VideoCompanionKeys.abA: 61000},
        ),
      );
      await _tapButton(tester, t.second_screen_video_ab_set_b);
      expect(rec.commands.single.args[VideoCompanionKeys.step], 'b');
      expect(
        find.text('${t.second_screen_video_ab_loop} · A 1:01'),
        findsOneWidget,
      );

      rec.show(
        CompanionContextKind.video,
        _sample(
          lineStudy: const <String, Object?>{
            VideoCompanionKeys.abA: 61000,
            VideoCompanionKeys.abB: 65000,
          },
        ),
        title: 'Series title',
      );
      await tester.pumpAndSettle();
      expect(
        find.text('${t.second_screen_video_ab_loop} · A 1:01 → B 1:05'),
        findsOneWidget,
      );
      await _tapButton(tester, t.second_screen_video_ab_clear);
      expect(rec.commands.last.args[VideoCompanionKeys.step], 'clear');
    });

    testWidgets('the auto-pause switch sends the new state', (
      WidgetTester tester,
    ) async {
      final RecordingCompanionSession rec = await _pump(tester, _sample());
      final Finder toggle = find.byType(FushiSwitch);
      await _reveal(tester, toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(rec.commands.single.action, VideoCompanionActions.setAutoPause);
      expect(rec.commands.single.args, <String, Object?>{
        VideoCompanionKeys.on: true,
      });
    });

    testWidgets('loop chooser: pick a count, forever or off', (
      WidgetTester tester,
    ) async {
      final RecordingCompanionSession rec = await _pump(
        tester,
        _sample(
          lineStudy: const <String, Object?>{
            VideoCompanionKeys.loop: <String, Object?>{
              VideoCompanionKeys.on: true,
              VideoCompanionKeys.times: 2,
              VideoCompanionKeys.remaining: 1,
            },
          },
        ),
      );
      final Finder three = find.text(
        t.second_screen_video_loop_count(count: 3),
      );
      await _reveal(tester, three);
      expect(
        find.text(t.second_screen_video_loop_remaining(count: 1)),
        findsOneWidget,
      );
      await tester.tap(three);
      await tester.pumpAndSettle();
      await _tapButton(tester, t.second_screen_video_loop_forever);
      await tester.tap(find.text(t.second_screen_video_off));
      await tester.pumpAndSettle();
      expect(_actions(rec), <String>[
        VideoCompanionActions.loopLine,
        VideoCompanionActions.loopLine,
        VideoCompanionActions.loopLine,
      ]);
      expect(
        rec.commands.map(
          (CompanionCommandMessage c) => c.args[VideoCompanionKeys.times],
        ),
        <int>[3, 0, -1],
      );
    });

    testWidgets('without subtitle lines replay and loop are disabled', (
      WidgetTester tester,
    ) async {
      final RecordingCompanionSession rec = await _pump(
        tester,
        _sample(withCues: false),
      );
      await _tapButton(tester, t.second_screen_video_replay_line_pause);
      final Finder three = find.text(
        t.second_screen_video_loop_count(count: 3),
      );
      await _reveal(tester, three);
      await tester.tap(three, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(rec.commands, isEmpty);
    });
  });

  testWidgets('every control is at least 48 dp tall', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _sample());
    for (final String tooltip in <String>[
      t.second_screen_video_back_10,
      t.second_screen_video_previous_line,
      t.pause,
      t.second_screen_video_next_line,
      t.second_screen_video_forward_10,
      t.second_screen_video_info,
      t.second_screen_video_replay_line_pause,
      t.second_screen_video_ab_set_a,
    ]) {
      await _reveal(
        tester,
        find.byWidgetPredicate(
          (Widget w) => w is Tooltip && w.message == tooltip,
        ),
      );
      final Size size = tester.getSize(companionButton(tooltip));
      expect(size.height, greaterThanOrEqualTo(48), reason: tooltip);
      expect(size.width, greaterThanOrEqualTo(48), reason: tooltip);
    }
  });
}
