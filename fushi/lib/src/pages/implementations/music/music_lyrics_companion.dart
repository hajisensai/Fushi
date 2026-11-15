/// The music now-playing / lyrics page's end of the companion (dual-screen
/// handhelds): the module snapshot it publishes, the commands it accepts and
/// the lyric lookup routing. Pure functions over the page's state, so they are
/// testable without pumping the page. Schema: [MusicCompanionKeys].
///
/// Only what the page already does: transport, seek, play from a line, the
/// whole-song offset step, "Choose lyrics source" (the page's own picker, on
/// the top screen) and "Use automatic source". No lyric editing, no furigana.
library;

import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart'
    show KaraokeLookupHit;
import 'package:fushi/src/media/music/lyrics/music_lyrics_learning.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/second_screen/companion/companion_lookup_routing.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/music_companion_schema.dart';

/// Lyric lines sent per snapshot (main lines only).
const int kMusicCompanionLyricWindow = 60;

/// Lines before the current one in the window.
const int kMusicCompanionLyricLead = 20;

/// The music module snapshot; null while nothing is loaded in the player
/// (the panel keeps its last one / shows its empty state).
///
/// [timeline] is the page's live timeline (offset applied), null when there
/// are no lyrics. [durationMs] null = unknown.
Map<String, Object?>? buildMusicCompanionSnapshot({
  required MusicPlayItem? item,
  required bool playing,
  required int positionMs,
  required int? durationMs,
  required bool canPrevious,
  required bool canSeek,
  required LyricTimeline? timeline,
  required bool lyricsLoading,
  required bool userSource,
}) {
  if (item == null) return null;
  final String? cover = item.coverPath;
  final bool localCover =
      cover != null &&
      cover.isNotEmpty &&
      !cover.startsWith('http://') &&
      !cover.startsWith('https://');
  final LyricTimeline? t = timeline != null && timeline.lines.isNotEmpty
      ? timeline
      : null;
  final int current = t == null || !t.isSynced
      ? -1
      : musicLyricCurrentLine(t, positionMs);
  final List<Map<String, Object?>> lines = <Map<String, Object?>>[];
  if (t != null) {
    final int center = current < 0 ? 0 : current;
    // Main lines only (background vocals / empty lines are not lookup
    // targets), counted around the current line.
    final List<int> main = <int>[
      for (int i = 0; i < t.lines.length; i++)
        if (!t.lines[i].isBackground && t.lines[i].text.trim().isNotEmpty) i,
    ];
    int at = main.indexWhere((int i) => i >= center);
    if (at < 0) at = main.length;
    final int from = (at - kMusicCompanionLyricLead).clamp(0, main.length);
    final int to = (from + kMusicCompanionLyricWindow).clamp(0, main.length);
    for (int k = from; k < to; k++) {
      final LyricLine line = t.lines[main[k]];
      final String? translation = line.primaryTranslation;
      lines.add(<String, Object?>{
        MusicCompanionKeys.index: main[k],
        MusicCompanionKeys.text: line.text.trim(),
        if (translation != null && translation.trim().isNotEmpty)
          MusicCompanionKeys.translation: translation.trim(),
      });
    }
  }
  final String? artist = item.artist;
  final String? album = item.album;
  return <String, Object?>{
    MusicCompanionKeys.title: item.title,
    if (artist != null && artist.isNotEmpty) MusicCompanionKeys.artist: artist,
    if (album != null && album.isNotEmpty) MusicCompanionKeys.album: album,
    if (localCover) MusicCompanionKeys.cover: cover,
    MusicCompanionKeys.playing: playing,
    MusicCompanionKeys.positionMs: positionMs < 0 ? 0 : positionMs,
    if (durationMs != null && durationMs > 0)
      MusicCompanionKeys.durationMs: durationMs,
    MusicCompanionKeys.canPrevious: canPrevious,
    MusicCompanionKeys.canSeek: canSeek,
    MusicCompanionKeys.lyricsLoading: lyricsLoading,
    MusicCompanionKeys.hasLyrics: t != null,
    MusicCompanionKeys.synced: t?.isSynced ?? false,
    MusicCompanionKeys.offsetMs: t?.offsetMs ?? 0,
    MusicCompanionKeys.userSource: userSource,
    MusicCompanionKeys.lyricIndex: current,
    if (t != null) MusicCompanionKeys.lyrics: lines,
  };
}

/// What the page does for the companion's commands (its existing
/// operations).
class MusicCompanionTarget {
  const MusicCompanionTarget({
    required this.togglePlayPause,
    required this.skipPrevious,
    required this.skipNext,
    required this.seek,
    required this.timeline,
    required this.trackDurationMs,
    required this.nudgeOffset,
    required this.chooseSource,
    required this.resetSource,
  });

  final Future<void> Function() togglePlayPause;
  final Future<void> Function() skipPrevious;
  final Future<void> Function() skipNext;
  final Future<void> Function(Duration position) seek;

  /// The live timeline (offset applied); null = no lyrics.
  final LyricTimeline? Function() timeline;
  final int? Function() trackDurationMs;

  /// One offset step; [direction] 1 = lyrics earlier, -1 = later.
  final void Function(int direction) nudgeOffset;
  final Future<void> Function() chooseSource;
  final Future<void> Function() resetSource;
}

/// Runs a companion command on the page. Unknown actions and bad args are
/// ignored (the panel may be newer / older than this engine).
Future<void> handleMusicCompanionCommand(
  String action,
  Map<String, Object?> args,
  MusicCompanionTarget target,
) async {
  switch (action) {
    case MusicCompanionActions.playPause:
      await target.togglePlayPause();
    case MusicCompanionActions.previous:
      await target.skipPrevious();
    case MusicCompanionActions.next:
      await target.skipNext();
    case MusicCompanionActions.seek:
      final int? ms = args.intOrNull(MusicCompanionKeys.ms);
      if (ms == null) return;
      await target.seek(Duration(milliseconds: ms < 0 ? 0 : ms));
    case MusicCompanionActions.seekLine:
      final int? index = args.intOrNull(MusicCompanionKeys.index);
      final LyricTimeline? t = target.timeline();
      if (index == null || t == null || !t.isSynced) return;
      final MusicLyricLineWindow? window = musicLyricLineWindow(
        t,
        index,
        trackDurationMs: target.trackDurationMs(),
      );
      if (window == null) return;
      await target.seek(Duration(milliseconds: window.startMs));
    case MusicCompanionActions.nudgeOffset:
      final int? direction = args.intOrNull(MusicCompanionKeys.direction);
      if (direction != 1 && direction != -1) return;
      if (!(target.timeline()?.isSynced ?? false)) return;
      target.nudgeOffset(direction!);
    case MusicCompanionActions.chooseSource:
      await target.chooseSource();
    case MusicCompanionActions.resetSource:
      await target.resetSource();
  }
}

/// A lyric lookup made on the main screen: shown in the companion's Lookup
/// tab when the companion is in use (true: skip the in-page popup), else
/// false and the page shows its popup as on a single screen. Mining sentence
/// = the line.
Future<bool> routeMusicLyricLookup(KaraokeLookupHit hit) =>
    routeCompanionLookup(
      text: hit.lineText,
      charIndex: hit.charIndexInLine,
      sentence: hit.lineText,
    );
