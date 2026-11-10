/// Audiobook module of the companion (`CompanionContextKind.audiobook`): the
/// reader page in its audiobook (lyrics) view publishes it. Shared by the
/// reader page (`reader_fushi/companion.part.dart`) and
/// `AudiobookCompanionPanel`. Pure Dart.
///
/// Snapshot (~1/s while the companion is up):
/// - [title] String, [author] String?, [cover] String? (local file path).
/// - [chapterTitle] String, [chapterIndex] int, [chapterCount] int.
/// - [playing] bool, [speed] double.
/// - [positionMs] / [durationMs] int: whole-book position and length
///   (0 = unknown).
/// - [current] int (index of the current transcript line in the chapter,
///   -1 = none), [lines] List of {[lineIndex], [lineText]}: a window of at
///   most `2 * lineRadius + 1` lines around the current one.
abstract final class AudiobookCompanionKeys {
  static const int lineRadius = 40;

  static const String title = 'title';
  static const String author = 'author';
  static const String cover = 'cover';
  static const String chapterTitle = 'chapterTitle';
  static const String chapterIndex = 'chapterIndex';
  static const String chapterCount = 'chapterCount';
  static const String playing = 'playing';
  static const String speed = 'speed';
  static const String positionMs = 'positionMs';
  static const String durationMs = 'durationMs';
  static const String current = 'current';
  static const String lines = 'lines';
  static const String lineIndex = 'index';
  static const String lineText = 'text';
}

/// Audiobook commands (`session.command(action, args)`).
abstract final class AudiobookCompanionActions {
  static const String playPause = 'playPause';

  /// `{seconds: int}` (negative = back).
  static const String seekRelative = 'seekRelative';
  static const String seconds = 'seconds';

  /// `{index: int}`: play from that transcript line of the chapter.
  static const String seekLine = 'seekLine';
  static const String index = 'index';

  static const String previousChapter = 'previousChapter';
  static const String nextChapter = 'nextChapter';

  /// `{speed: double}`.
  static const String setSpeed = 'setSpeed';
  static const String speed = 'speed';

  /// Speeds the panel offers.
  static const List<double> speeds = <double>[0.75, 1.0, 1.25, 1.5, 2.0];
}
