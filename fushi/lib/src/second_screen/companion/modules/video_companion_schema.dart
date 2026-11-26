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
///   subtitle tracks that can be selected; [subtitlesOff] bool;
///   [subtitleLoading] bool (a subtitle source is being extracted / loaded:
///   the panel shows the progress and picks wait, as the page's rows do).
/// - [info] Map? (cached scrape metadata, every field optional, missing =
///   unknown): [workTitle], [rating] double, [votes] int, [overview],
///   [episodeNumber] int, [episodeTitle], [episodeOverview]; since S5 also
///   [year] int, [studios] / [genres] List<String> (each at most
///   [maxTerms]), [cast] List of {[personName], [personRole]?} (at most
///   [maxCast], billing order) and [staff] List of {[personName],
///   [staffKind] (`director` / `writer` / ... as cached), [staffJob]?} (at
///   most [maxStaff]). Old panels ignore the new keys.
/// - Line study (S6): [autoPause] bool (pause after each line); [loop] Map
///   {[on] bool, [times] int? (the N of "loop N times", absent = forever),
///   [remaining] int? (rewinds still to come, absent = forever)}, the loop
///   being the player's "loop current line" mode; [abA] / [abB] int (A-B loop
///   points, player position ms; absent = not set, both set = looping).
/// - Seek steps: [seekSeconds] / [longSeekSeconds] int (the page's own short
///   / long seek step, what [VideoCompanionActions.seekStep] jumps by).
///   Absent (an older page): the panel falls back to [VideoCompanionActions.
///   seekBy] with [kVideoCompanionLegacySeekSeconds] /
///   [kVideoCompanionLegacyLongSeekSeconds].
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
  static const String subtitleLoading = 'subtitleLoading';
  static const String info = 'info';
  static const String autoPause = 'autoPause';
  static const String loop = 'loop';
  static const String abA = 'abA';
  static const String abB = 'abB';
  static const String seekSeconds = 'seekSeconds';
  static const String longSeekSeconds = 'longSeekSeconds';

  // Loop entries.
  static const String on = 'on';
  static const String times = 'times';
  static const String remaining = 'remaining';

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
  static const String step = 'step';
  static const String forward = 'forward';
  static const String long = 'long';

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
/// - [seekStep] [`forward` bool, `long` bool]: seek by the page's own short /
///   long step (the page is the single source of the step length; the
///   snapshot reports it as `seekSeconds` / `longSeekSeconds`).
/// - [jumpToCue] [`start` int, `text` String]: the cue with that start (the
///   same jump as tapping a line in the page's subtitle list)
/// - [selectAudio] [`id`], [selectSubtitle] [`source`], [subtitleOff]
/// - [mineLine]: mine the current subtitle line (the page's existing mining
///   path for the current cue).
/// - Line study: [replayLineThenPause] (replay the current line, pause at its
///   end); [setAutoPause] [`on` bool]; [loopLine] [`times` int: 0 = forever,
///   N > 0 = rewind N more times then play on, < 0 = stop looping]; [abLoop]
///   [`step` String, one of [VideoCompanionAbSteps]].
abstract final class VideoCompanionActions {
  static const String playPause = 'playPause';
  static const String previousCue = 'previousCue';
  static const String nextCue = 'nextCue';
  static const String seekTo = 'seekTo';
  static const String seekBy = 'seekBy';
  static const String seekStep = 'seekStep';
  static const String jumpToCue = 'jumpToCue';
  static const String selectAudio = 'selectAudio';
  static const String selectSubtitle = 'selectSubtitle';
  static const String subtitleOff = 'subtitleOff';
  static const String mineLine = 'mineLine';
  static const String replayLineThenPause = 'replayLineThenPause';
  static const String setAutoPause = 'setAutoPause';
  static const String loopLine = 'loopLine';
  static const String abLoop = 'abLoop';
}

/// `step` values of [VideoCompanionActions.abLoop]: [a] = set A here (drops
/// B), [b] = set B here and loop (ignored without A or when not after A),
/// [clear] = clear both, [toggle] = the shortcut's 3-state cycle.
abstract final class VideoCompanionAbSteps {
  static const String a = 'a';
  static const String b = 'b';
  static const String clear = 'clear';
  static const String toggle = 'toggle';
}

/// Loop counts the panel offers (0 = forever); `times` of
/// [VideoCompanionActions.loopLine].
const List<int> kVideoCompanionLoopTimes = <int>[1, 2, 3, 5, 0];

/// Steps a panel uses when the page's snapshot carries no
/// [VideoCompanionKeys.seekSeconds] / [VideoCompanionKeys.longSeekSeconds]
/// (a page older than [VideoCompanionActions.seekStep]): the old fixed 10 s
/// and the long step's factory default, 30 s.
const int kVideoCompanionLegacySeekSeconds = 10;
const int kVideoCompanionLegacyLongSeekSeconds = 30;

/// One short / long seek-step button press as the panel sends it.
class VideoCompanionSeekStepCommand {
  const VideoCompanionSeekStepCommand({
    required this.action,
    required this.args,
    required this.seconds,
  });

  final String action;
  final Map<String, Object?> args;

  /// The step length the button shows.
  final int seconds;
}

/// The command for a short / long seek-step press: [VideoCompanionActions.
/// seekStep] when [snapshot] reports the page's step lengths (the page then
/// seeks by its own configuration), otherwise [VideoCompanionActions.seekBy]
/// by the legacy fixed step (an older page that does not know `seekStep`).
VideoCompanionSeekStepCommand videoCompanionSeekStepCommand(
  Map<String, Object?> snapshot, {
  required bool forward,
  required bool long,
}) {
  final Object? reported =
      snapshot[long
          ? VideoCompanionKeys.longSeekSeconds
          : VideoCompanionKeys.seekSeconds];
  if (reported is int && reported > 0) {
    return VideoCompanionSeekStepCommand(
      action: VideoCompanionActions.seekStep,
      args: <String, Object?>{
        VideoCompanionKeys.forward: forward,
        VideoCompanionKeys.long: long,
      },
      seconds: reported,
    );
  }
  final int seconds = long
      ? kVideoCompanionLegacyLongSeekSeconds
      : kVideoCompanionLegacySeekSeconds;
  return VideoCompanionSeekStepCommand(
    action: VideoCompanionActions.seekBy,
    args: <String, Object?>{
      VideoCompanionKeys.ms: forward ? seconds * 1000 : -seconds * 1000,
    },
    seconds: seconds,
  );
}
