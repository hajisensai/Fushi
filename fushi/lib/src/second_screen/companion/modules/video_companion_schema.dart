/// Video module of the companion (`CompanionContextKind.video`): snapshot
/// keys and command names shared by the video page (main engine,
/// `video_companion_hook.dart`) and `VideoCompanionPanel` (companion
/// engine). Pure Dart.
///
/// Snapshot (published ~1/s while the video page is the top page and the
/// companion is up):
/// - [title] String (the video / episode file title), [series] String?
///   (playlist / series name), [cover] String? (local file path only).
/// - [episodeIndex] int (0-based playlist position, -1 = not a playlist
///   episode), [episodeCount] int.
/// - [playing] bool, [positionMs] int, [durationMs] int (0 = unknown),
///   [speed] double.
/// - [cue] String? (current primary subtitle line), [cueStart] int (start of
///   the current cue in subtitle time, -1 = between cues / none), [cues]
///   List of {[start], [end], [text]}: a window of at most
///   `VideoCompanionKeys.maxCues` cues around the current one.
/// - [audioTracks] List of {[id], [label], [selected]}.
/// - [subtitleTracks] List of {[source], [label], [selected]}: the primary
///   subtitle tracks that can be selected; [subtitlesOff] bool.
/// - [info] Map? (cached scrape metadata, every field optional, missing =
///   unknown): [workTitle], [rating] double, [votes] int, [overview],
///   [episodeNumber] int, [episodeTitle], [episodeOverview]; since S5 also
///   [year] int, [studios] / [genres] List<String> (each at most
///   [maxTerms]), [cast] List of {[personName], [personRole]?} (at most
///   [maxCast], billing order) and [staff] List of {[personName],
///   [staffKind] (`director` / `writer` / ... as cached), [staffJob]?} (at
///   most [maxStaff]). Old panels ignore the new keys.
///
/// Commands (`session.command(action, args)`): see [VideoCompanionActions].
abstract final class VideoCompanionKeys {
  static const String title = 'title';
  static const String series = 'series';
  static const String cover = 'cover';
  static const String episodeIndex = 'episodeIndex';
  static const String episodeCount = 'episodeCount';
  static const String playing = 'playing';
  static const String positionMs = 'positionMs';
  static const String durationMs = 'durationMs';
  static const String speed = 'speed';
  static const String cue = 'cue';
  static const String cueStart = 'cueStart';
  static const String cues = 'cues';
  static const String audioTracks = 'audioTracks';
  static const String subtitleTracks = 'subtitleTracks';
  static const String subtitlesOff = 'subtitlesOff';
  static const String info = 'info';

  // Cue entries.
  static const String start = 'start';
  static const String end = 'end';
  static const String text = 'text';

  // Track entries.
  static const String id = 'id';
  static const String source = 'source';
  static const String label = 'label';
  static const String selected = 'selected';

  // Info fields.
  static const String workTitle = 'workTitle';
  static const String rating = 'rating';
  static const String votes = 'votes';
  static const String overview = 'overview';
  static const String episodeNumber = 'episodeNumber';
  static const String episodeTitle = 'episodeTitle';
  static const String episodeOverview = 'episodeOverview';
  static const String year = 'year';
  static const String studios = 'studios';
  static const String genres = 'genres';
  static const String cast = 'cast';
  static const String staff = 'staff';

  // Cast / staff entries.
  static const String personName = 'name';
  static const String personRole = 'role';
  static const String staffKind = 'kind';
  static const String staffJob = 'job';

  // Command args.
  static const String ms = 'ms';

  /// Most cues sent in one snapshot (the window around the current cue).
  static const int maxCues = 80;

  /// Most cast / staff entries and studio / genre names in [info].
  static const int maxCast = 10;
  static const int maxStaff = 6;
  static const int maxTerms = 6;
}

/// Commands the video panel sends (args in brackets):
/// - [playPause], [previousCue], [nextCue]
/// - [seekTo] [`ms` int, player position], [seekBy] [`ms` int, may be
///   negative]
/// - [jumpToCue] [`start` int, `text` String]: the cue with that start (the
///   same jump as tapping a line in the page's subtitle list)
/// - [selectAudio] [`id`], [selectSubtitle] [`source`], [subtitleOff]
/// - [mineLine]: mine the current subtitle line (the page's existing mining
///   path for the current cue).
///
/// Line-study tools (auto-pause, loop, A-B) are a later step and have no
/// command here yet.
abstract final class VideoCompanionActions {
  static const String playPause = 'playPause';
  static const String previousCue = 'previousCue';
  static const String nextCue = 'nextCue';
  static const String seekTo = 'seekTo';
  static const String seekBy = 'seekBy';
  static const String jumpToCue = 'jumpToCue';
  static const String selectAudio = 'selectAudio';
  static const String selectSubtitle = 'selectSubtitle';
  static const String subtitleOff = 'subtitleOff';
  static const String mineLine = 'mineLine';
}
