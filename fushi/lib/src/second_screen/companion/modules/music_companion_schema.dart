/// Music module of the companion (`CompanionContextKind.music`): snapshot
/// keys and command names shared by the now-playing / lyrics page (main
/// engine, `music_lyrics_companion.dart`) and `MusicCompanionPanel`
/// (companion engine). Pure Dart.
///
/// Snapshot (published while `MusicLyricsPage` is the top page):
/// - [title] String, [artist] / [album] String? (missing = unknown),
///   [cover] String? (local file path only; remote covers are not sent).
/// - [playing] bool, [positionMs] int, [durationMs] int? (missing = unknown),
///   [canPrevious] bool, [canSeek] bool.
/// - [lyricsLoading] bool; [hasLyrics] bool (a non-empty timeline is
///   loaded); [synced] bool (timed lyrics: seek to a line and the whole-song
///   offset are available); [offsetMs] int (whole-song offset, positive =
///   lyrics earlier); [userSource] bool (a hand-picked source is in use, so
///   "Use automatic source" is available).
/// - [lyricIndex] int (current line in the timeline, -1 = none); [lyrics]
///   List of {[index], [text], [translation]?}: a capped window of main lines
///   around the current one ([index] = timeline line index). Absent when
///   there are no lyrics.
///
/// Commands (`session.command(action, args)`): see [MusicCompanionActions].
/// There is deliberately no lyric editing (text / translation / ruby /
/// per-line offset) command.
abstract final class MusicCompanionKeys {
  static const String title = 'title';
  static const String artist = 'artist';
  static const String album = 'album';
  static const String cover = 'cover';
  static const String playing = 'playing';
  static const String positionMs = 'positionMs';
  static const String durationMs = 'durationMs';
  static const String canPrevious = 'canPrevious';
  static const String canSeek = 'canSeek';
  static const String lyricsLoading = 'lyricsLoading';
  static const String hasLyrics = 'hasLyrics';
  static const String synced = 'synced';
  static const String offsetMs = 'offsetMs';
  static const String userSource = 'userSource';
  static const String lyricIndex = 'lyricIndex';
  static const String lyrics = 'lyrics';

  // Lyric line entries.
  static const String index = 'index';
  static const String text = 'text';
  static const String translation = 'translation';

  // Command args.
  static const String ms = 'ms';
  static const String direction = 'direction';
}

abstract final class MusicCompanionActions {
  /// Play / pause (no args).
  static const String playPause = 'playPause';

  /// Previous track / back to the start of this one (no args).
  static const String previous = 'previous';

  /// Next track (no args).
  static const String next = 'next';

  /// Seek to `{ms: int}` (track time).
  static const String seek = 'seek';

  /// Play from lyric line `{index: int}` (timeline line index).
  static const String seekLine = 'seekLine';

  /// Whole-song lyric offset one step `{direction: 1 | -1}` (1 = lyrics
  /// earlier), the same step as the page's +/- buttons.
  static const String nudgeOffset = 'nudgeOffset';

  /// Opens the page's "Choose lyrics source" picker on the top screen.
  static const String chooseSource = 'chooseSource';

  /// Back to the automatic lyrics source (only when [MusicCompanionKeys
  /// .userSource]).
  static const String resetSource = 'resetSource';
}
