import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/music_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/music_companion_panel.dart';
import 'package:material_ui/material_ui.dart';

import 'companion_panel_harness.dart';

Map<String, Object?> _sample({
  bool synced = true,
  bool userSource = false,
  bool lyrics = true,
}) => <String, Object?>{
  MusicCompanionKeys.title: 'Yoru ni kakeru',
  MusicCompanionKeys.artist: 'YOASOBI',
  MusicCompanionKeys.album: 'THE BOOK',
  MusicCompanionKeys.playing: true,
  MusicCompanionKeys.positionMs: 65000,
  MusicCompanionKeys.durationMs: 261000,
  MusicCompanionKeys.canPrevious: true,
  MusicCompanionKeys.canSeek: true,
  MusicCompanionKeys.lyricsLoading: false,
  MusicCompanionKeys.hasLyrics: lyrics,
  MusicCompanionKeys.synced: synced,
  MusicCompanionKeys.offsetMs: 200,
  MusicCompanionKeys.userSource: userSource,
  MusicCompanionKeys.lyricIndex: synced ? 4 : -1,
  if (lyrics)
    MusicCompanionKeys.lyrics: <Map<String, Object?>>[
      <String, Object?>{
        MusicCompanionKeys.index: 3,
        MusicCompanionKeys.text: 'ABCDEFGH',
        MusicCompanionKeys.translation: 'first line',
      },
      <String, Object?>{
        MusicCompanionKeys.index: 4,
        MusicCompanionKeys.text: 'IJKLMNOP',
      },
    ],
};

Future<RecordingCompanionSession> _pump(
  WidgetTester tester,
  Map<String, Object?>? snapshot,
) async {
  final RecordingCompanionSession rec = RecordingCompanionSession();
  if (snapshot == null) {
    rec.push(
      const CompanionContextMessage(
        CompanionContext(CompanionContextKind.music),
      ),
    );
  } else {
    rec.show(CompanionContextKind.music, snapshot, title: 'Yoru ni kakeru');
  }
  await pumpCompanionPanel(
    tester,
    rec.session,
    MusicCompanionPanel(session: rec.session),
  );
  return rec;
}

void main() {
  testWidgets('renders the track, clock, lyrics and transport', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _sample());
    expect(find.text('Yoru ni kakeru'), findsOneWidget);
    expect(find.text('YOASOBI · THE BOOK'), findsOneWidget);
    expect(find.text('1:05 / 4:21'), findsOneWidget);
    expect(find.text('ABCDEFGH'), findsOneWidget);
    expect(find.text('first line'), findsOneWidget);
    expect(find.text('IJKLMNOP'), findsOneWidget);
    expect(find.text(t.music_lyrics_offset_value(ms: 200)), findsOneWidget);
    expect(companionButton(t.pause), findsOneWidget);
    expect(companionButton(t.music_lyrics_reset_source), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each control sends its command', (WidgetTester tester) async {
    final RecordingCompanionSession rec = await _pump(
      tester,
      _sample(userSource: true),
    );
    Future<void> tap(String tooltip) async {
      await tester.tap(companionButton(tooltip).first);
      await tester.pump();
    }

    await tap(t.pause);
    await tap(t.shortcut_action_music_previous_track);
    await tap(t.shortcut_action_music_next_track);
    await tap(t.music_lyrics_offset_earlier);
    await tap(t.music_lyrics_offset_later);
    await tap(t.music_lyrics_choose_source);
    await tap(t.music_lyrics_reset_source);
    await tap(t.second_screen_music_play_line);
    final List<CompanionCommandMessage> c = rec.commands;
    expect(c.map((CompanionCommandMessage m) => m.action).toList(), <String>[
      MusicCompanionActions.playPause,
      MusicCompanionActions.previous,
      MusicCompanionActions.next,
      MusicCompanionActions.nudgeOffset,
      MusicCompanionActions.nudgeOffset,
      MusicCompanionActions.chooseSource,
      MusicCompanionActions.resetSource,
      MusicCompanionActions.seekLine,
    ]);
    expect(
      c.every(
        (CompanionCommandMessage m) => m.kind == CompanionContextKind.music,
      ),
      isTrue,
    );
    expect(c[3].args[MusicCompanionKeys.direction], 1);
    expect(c[4].args[MusicCompanionKeys.direction], -1);
    expect(c[7].args[MusicCompanionKeys.index], 3);
  });

  testWidgets('seek bar sends a seek on release', (WidgetTester tester) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    final Finder slider = find.byType(Slider);
    expect(slider, findsOneWidget);
    await tester.tap(slider);
    await tester.pump();
    final CompanionCommandMessage seek = rec.commands.single;
    expect(seek.action, MusicCompanionActions.seek);
    final int ms = seek.args[MusicCompanionKeys.ms]! as int;
    expect(ms, greaterThan(100000));
    expect(ms, lessThan(160000));
  });

  testWidgets('tapping a lyric word looks it up on the panel', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    final Finder line = find.text('IJKLMNOP');
    // Left edge: the first character.
    await tester.tapAt(tester.getTopLeft(line) + const Offset(2, 6));
    await tester.pump();
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(MusicCompanionPanel)),
    );
    CompanionLookupEntry? entry = container
        .read(companionLookupControllerProvider)
        .current;
    expect(entry?.text, 'IJKLMNOP');
    expect(entry?.sentence, 'IJKLMNOP');
    expect(entry?.charIndex, 0);
    // Right edge: the last character.
    await tester.tapAt(tester.getTopRight(line) + const Offset(-2, 6));
    await tester.pump();
    entry = container.read(companionLookupControllerProvider).current;
    expect(entry?.charIndex, 7);
    // A lookup is not a module command.
    expect(rec.commands, isEmpty);
  });

  testWidgets('unsynced lyrics: no offset, no play-from-line', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _sample(synced: false));
    expect(find.text('ABCDEFGH'), findsOneWidget);
    expect(companionButton(t.second_screen_music_play_line), findsNothing);
    expect(companionButton(t.music_lyrics_offset_earlier), findsNothing);
    expect(companionButton(t.music_lyrics_choose_source), findsOneWidget);
  });

  testWidgets('no lyrics: the lyric section is hidden', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _sample(lyrics: false));
    expect(find.text(t.second_screen_music_lyrics_label), findsNothing);
    expect(find.text('ABCDEFGH'), findsNothing);
    expect(companionButton(t.music_lyrics_offset_earlier), findsNothing);
    expect(companionButton(t.music_lyrics_choose_source), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing data: empty state, no crash', (
    WidgetTester tester,
  ) async {
    await _pump(tester, null);
    expect(find.text(t.second_screen_music_nothing), findsOneWidget);
    await _pump(tester, <String, Object?>{
      MusicCompanionKeys.title: 'Only a title',
    });
    expect(find.text('Only a title'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(companionButton(t.play), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
