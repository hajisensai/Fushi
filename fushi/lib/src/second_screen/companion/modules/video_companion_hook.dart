import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_page_link.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/video_companion_now_playing.dart';
import 'package:fushi/src/second_screen/companion/modules/video_companion_schema.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart'
    show SubtitleSource;
import 'package:material_ui/material_ui.dart' show Route;

/// An audio or subtitle track as the companion lists it. [id] is the audio
/// track id, or the subtitle source's persisted value.
@immutable
class VideoCompanionTrack {
  const VideoCompanionTrack({
    required this.id,
    required this.label,
    required this.selected,
  });

  final String id;
  final String label;
  final bool selected;

  @override
  bool operator ==(Object other) =>
      other is VideoCompanionTrack &&
      other.id == id &&
      other.label == label &&
      other.selected == selected;

  @override
  int get hashCode => Object.hash(id, label, selected);
}

//// One cast / staff line of the cached credits: [name] as cached, [role] =
/// the character (cast) or the job (staff), [kind] = the cached credit kind
/// (`actor`, `voice_actor`, `director`, `writer`, ...).
@immutable
class VideoCompanionCredit {
  const VideoCompanionCredit({required this.name, this.role, this.kind});

  final String name;
  final String? role;
  final String? kind;

  @override
  bool operator ==(Object other) =>
      other is VideoCompanionCredit &&
      other.name == name &&
      other.role == role &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(name, role, kind);
}

String? _infoText(String? v) {
  final String t = v?.trim() ?? '';
  return t.isEmpty ? null : t;
}

/// Cached scrape metadata of what plays (`VideoMetadataWorks` /
/// `VideoMetadataEpisodes` + the work's terms and credits). Every field is
/// optional: missing = unknown, the panel hides it.
@immutable
class VideoCompanionInfo {
  const VideoCompanionInfo({
    this.workTitle,
    this.rating,
    this.votes,
    this.overview,
    this.episodeNumber,
    this.episodeTitle,
    this.episodeOverview,
    this.year,
    this.studios = const <String>[],
    this.genres = const <String>[],
    this.cast = const <VideoCompanionCredit>[],
    this.staff = const <VideoCompanionCredit>[],
  });

  final String? workTitle;
  final double? rating;
  final int? votes;
  final String? overview;
  final int? episodeNumber;
  final String? episodeTitle;
  final String? episodeOverview;
  final int? year;
  final List<String> studios;
  final List<String> genres;

  /// Billing order; [VideoCompanionCredit.role] = the character.
  final List<VideoCompanionCredit> cast;

  /// Directors / writers; [VideoCompanionCredit.role] = the job.
  final List<VideoCompanionCredit> staff;

  bool get isEmpty => toJson().isEmpty;

  /// JSON for the snapshot; missing / blank / non-positive values left out,
  /// lists capped ([VideoCompanionKeys.maxCast] / `maxStaff` / `maxTerms`).
  Map<String, Object?> toJson() {
    final String? work = _infoText(workTitle);
    final String? about = _infoText(overview);
    final String? epTitle = _infoText(episodeTitle);
    final String? epAbout = _infoText(episodeOverview);
    final double? score = rating;
    final int? count = votes;
    final int? number = episodeNumber;
    final int? released = year;
    List<String> terms(List<String> values) => <String>[
      for (final String v in values)
        if (_infoText(v) case final String name) name,
    ].take(VideoCompanionKeys.maxTerms).toList();
    final List<String> studioNames = terms(studios);
    final List<String> genreNames = terms(genres);
    final List<Map<String, Object?>> castJson = <Map<String, Object?>>[
      for (final VideoCompanionCredit c in cast)
        if (_infoText(c.name) case final String name)
          <String, Object?>{
            VideoCompanionKeys.personName: name,
            VideoCompanionKeys.personRole: ?_infoText(c.role),
          },
    ].take(VideoCompanionKeys.maxCast).toList();
    final List<Map<String, Object?>> staffJson = <Map<String, Object?>>[
      for (final VideoCompanionCredit c in staff)
        if (_infoText(c.name) case final String name)
          <String, Object?>{
            VideoCompanionKeys.personName: name,
            VideoCompanionKeys.staffKind: ?_infoText(c.kind),
            VideoCompanionKeys.staffJob: ?_infoText(c.role),
          },
    ].take(VideoCompanionKeys.maxStaff).toList();
    return <String, Object?>{
      VideoCompanionKeys.workTitle: ?work,
      if (score != null && score > 0) VideoCompanionKeys.rating: score,
      if (count != null && count > 0) VideoCompanionKeys.votes: count,
      VideoCompanionKeys.overview: ?about,
      if (number != null && number > 0)
        VideoCompanionKeys.episodeNumber: number,
      VideoCompanionKeys.episodeTitle: ?epTitle,
      VideoCompanionKeys.episodeOverview: ?epAbout,
      if (released != null && released > 0) VideoCompanionKeys.year: released,
      if (studioNames.isNotEmpty) VideoCompanionKeys.studios: studioNames,
      if (genreNames.isNotEmpty) VideoCompanionKeys.genres: genreNames,
      if (castJson.isNotEmpty) VideoCompanionKeys.cast: castJson,
      if (staffJson.isNotEmpty) VideoCompanionKeys.staff: staffJson,
    };
  }
}

/// Cached credit kinds shown as cast.
const Set<String> _castKinds = <String>{'actor', 'voice_actor'};

/// Cached credit kinds shown as staff.
const Set<String> _staffKinds = <String>{'director', 'writer'};

/// Cast and staff of the work [workId] from the cached credits (each person
/// read once). No network.
Future<({List<VideoCompanionCredit> cast, List<VideoCompanionCredit> staff})>
_loadVideoCompanionCredits(FushiDatabase db, int workId) async {
  final List<VideoCompanionCredit> cast = <VideoCompanionCredit>[];
  final List<VideoCompanionCredit> staff = <VideoCompanionCredit>[];
  final Map<String, String?> names = <String, String?>{};
  for (final VideoMetadataCreditRow c in await db.getVideoMetadataCredits(
    workId: workId,
  )) {
    final bool isCast = _castKinds.contains(c.creditKind);
    if (!isCast && !_staffKinds.contains(c.creditKind)) continue;
    if (isCast && cast.length >= VideoCompanionKeys.maxCast) continue;
    if (!isCast && staff.length >= VideoCompanionKeys.maxStaff) continue;
    if (!names.containsKey(c.personKey)) {
      names[c.personKey] = _infoText(
        (await db.getVideoMetadataPerson(c.personKey))?.name,
      );
    }
    final String? name = names[c.personKey];
    if (name == null) continue;
    if (isCast) {
      final String? characterKey = c.characterKey;
      final String? character = characterKey == null
          ? null
          : _infoText((await db.getVideoMetadataCharacter(characterKey))?.name);
      cast.add(
        VideoCompanionCredit(
          name: name,
          role: character ?? _infoText(c.roleName),
          kind: c.creditKind,
        ),
      );
    } else {
      staff.add(
        VideoCompanionCredit(
          name: name,
          role: _infoText(c.job),
          kind: c.creditKind,
        ),
      );
    }
    if (cast.length >= VideoCompanionKeys.maxCast &&
        staff.length >= VideoCompanionKeys.maxStaff) {
      break;
    }
  }
  return (cast: cast, staff: staff);
}

/// Reads the cached metadata of the video [bookUid] (opened from the
/// playlist [collectionId], if any) from the local database. No network.
/// The work comes from the playlist's work, else the video's own work (a
/// movie), else the work of the season the video's episode row belongs to.
/// Null when nothing is cached.
Future<VideoCompanionInfo?> loadVideoCompanionInfo(
  FushiDatabase db, {
  required String bookUid,
  int? collectionId,
}) async {
  final List<VideoMetadataEpisodeRow> episodes = await db
      .getVideoMetadataEpisodesByBook(bookUid);
  final VideoMetadataEpisodeRow? episode = episodes.isEmpty
      ? null
      : episodes.first;
  VideoMetadataWorkRow? work = collectionId != null
      ? await db.resolveVideoMetadataWorkForCollection(collectionId)
      : null;
  work ??= await db.getVideoMetadataWorkByBook(bookUid);
  if (work == null && episode != null) {
    final VideoMetadataSeasonRow? season =
        await (db.select(db.videoMetadataSeasons)..where(
              ($VideoMetadataSeasonsTable t) => t.id.equals(episode.seasonId),
            ))
            .getSingleOrNull();
    if (season != null) work = await db.getVideoMetadataWorkById(season.workId);
  }
  if (work == null && episode == null) return null;
  final List<String> studios = <String>[];
  final List<String> genres = <String>[];
  List<VideoCompanionCredit> cast = const <VideoCompanionCredit>[];
  List<VideoCompanionCredit> staff = const <VideoCompanionCredit>[];
  if (work != null) {
    for (final VideoMetadataTermRow term
        in await db.getVideoMetadataTermsForWork(work.id)) {
      switch (term.kind) {
        case 'studio':
          studios.add(term.name);
        case 'genre':
          genres.add(term.name);
      }
    }
    final ({List<VideoCompanionCredit> cast, List<VideoCompanionCredit> staff})
    credits = await _loadVideoCompanionCredits(db, work.id);
    cast = credits.cast;
    staff = credits.staff;
  }
  final VideoCompanionInfo info = VideoCompanionInfo(
    workTitle: work?.title,
    rating: work?.rating,
    votes: work?.ratingCount,
    overview: work?.overview,
    episodeNumber: episode?.episodeNumber,
    episodeTitle: episode?.title,
    episodeOverview: episode?.overview,
    year: work?.year ?? episode?.year,
    studios: studios,
    genres: genres,
    cast: cast,
    staff: staff,
  );
  return info.isEmpty ? null : info;
}

/// The video page's state at one moment, as the companion needs it. Built by
/// the page on each snapshot tick (only while the companion is up).
@immutable
class VideoCompanionFrame {
  const VideoCompanionFrame({
    required this.bookUid,
    required this.title,
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    required this.speed,
    required this.cues,
    required this.currentCueIndex,
    required this.audioTracks,
    required this.subtitleSource,
    this.subtitleLoading = false,
    this.collectionId,
    this.series,
    this.coverPath,
    this.episodeIndex = -1,
    this.episodeCount = 0,
    this.autoPause = false,
    this.loopOn = false,
    this.loopTimes,
    this.loopRemaining,
    this.abAMs,
    this.abBMs,
  });

  /// Identity of what plays (metadata / subtitle track lists reload when it
  /// changes).
  final String bookUid;
  final int? collectionId;
  final String title;
  final String? series;
  final String? coverPath;
  final int episodeIndex;
  final int episodeCount;
  final bool playing;
  final int positionMs;
  final int durationMs;
  final double speed;

  /// The primary subtitle stream (the page's list, not copied).
  final List<AudioCue> cues;
  final int currentCueIndex;
  final List<VideoCompanionTrack> audioTracks;

  /// The primary subtitle source's persisted value (null / `off:` = off).
  final String? subtitleSource;

  /// A subtitle source is being extracted / loaded (the page's single loading
  /// state; its subtitle rows are disabled meanwhile).
  final bool subtitleLoading;

  /// Line study: pause after each line.
  final bool autoPause;

  /// Line study: the player's "loop current line" mode; [loopTimes] = the N
  /// of a finite loop, [loopRemaining] = rewinds still to come (both null =
  /// forever).
  final bool loopOn;
  final int? loopTimes;
  final int? loopRemaining;

  /// Line study: A-B loop points (player position ms; null = not set).
  final int? abAMs;
  final int? abBMs;
}

/// What one A-B loop command does ([VideoCompanionAbSteps] on the wire).
enum VideoCompanionAbStep {
  setA(VideoCompanionAbSteps.a),
  setB(VideoCompanionAbSteps.b),
  clear(VideoCompanionAbSteps.clear),
  toggle(VideoCompanionAbSteps.toggle);

  const VideoCompanionAbStep(this.wire);

  final String wire;

  /// The step for a wire value; null for unknown values.
  static VideoCompanionAbStep? fromWire(String? wire) {
    for (final VideoCompanionAbStep step in values) {
      if (step.wire == wire) return step;
    }
    return null;
  }
}

/// Index of the cue to centre the window on: the current one, else the last
/// one that started at or before [positionMs] (0 when none did).
int videoCompanionAnchorCue(
  List<AudioCue> cues,
  int currentIndex,
  int positionMs,
) {
  if (currentIndex >= 0 && currentIndex < cues.length) return currentIndex;
  int lo = 0;
  int hi = cues.length - 1;
  int best = 0;
  while (lo <= hi) {
    final int mid = (lo + hi) >> 1;
    if (cues[mid].startMs <= positionMs) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return best;
}

/// The companion lookup's `charIndex` (UTF-16) for the [graphemeIndex]-th
/// character of a subtitle [sentence] (the page counts user-perceived
/// characters; emoji / combining marks span several UTF-16 units).
int videoCompanionCharIndex(String sentence, int graphemeIndex) {
  if (graphemeIndex <= 0) return 0;
  return sentence.characters.take(graphemeIndex).string.length;
}

/// The module snapshot for [frame] (JSON-safe, at most
/// [VideoCompanionKeys.maxCues] cues around the current one).
Map<String, Object?> buildVideoCompanionSnapshot(
  VideoCompanionFrame frame, {
  VideoCompanionInfo? info,
  List<VideoCompanionTrack> subtitleTracks = const <VideoCompanionTrack>[],
  int maxCues = VideoCompanionKeys.maxCues,
}) {
  final List<AudioCue> cues = frame.cues;
  final int current =
      frame.currentCueIndex >= 0 && frame.currentCueIndex < cues.length
      ? frame.currentCueIndex
      : -1;
  int from = 0;
  int to = 0;
  if (cues.isNotEmpty) {
    final int anchor = videoCompanionAnchorCue(cues, current, frame.positionMs);
    from = (anchor - maxCues ~/ 2).clamp(0, cues.length);
    to = (from + maxCues).clamp(0, cues.length);
    from = (to - maxCues).clamp(0, cues.length);
  }
  final String? source = frame.subtitleSource;
  final Map<String, Object?> infoJson =
      info?.toJson() ?? const <String, Object?>{};
  final String? series = frame.series?.trim();
  final String? cover = frame.coverPath;
  final String? cueText = current >= 0 ? cues[current].text : null;
  final int? loopTimes = frame.loopTimes;
  final int? loopRemaining = frame.loopRemaining;
  final int? abA = frame.abAMs;
  final int? abB = frame.abBMs;
  return <String, Object?>{
    VideoCompanionKeys.title: frame.title,
    if (series != null && series.isNotEmpty) VideoCompanionKeys.series: series,
    if (cover != null && cover.isNotEmpty) VideoCompanionKeys.cover: cover,
    VideoCompanionKeys.episodeIndex: frame.episodeIndex,
    VideoCompanionKeys.episodeCount: frame.episodeCount,
    VideoCompanionKeys.playing: frame.playing,
    VideoCompanionKeys.positionMs: frame.positionMs < 0 ? 0 : frame.positionMs,
    VideoCompanionKeys.durationMs: frame.durationMs < 0 ? 0 : frame.durationMs,
    VideoCompanionKeys.speed: frame.speed,
    if (cueText != null && cueText.isNotEmpty) VideoCompanionKeys.cue: cueText,
    VideoCompanionKeys.cueStart: current >= 0 ? cues[current].startMs : -1,
    VideoCompanionKeys.cues: <Map<String, Object?>>[
      for (int i = from; i < to; i++)
        <String, Object?>{
          VideoCompanionKeys.start: cues[i].startMs,
          VideoCompanionKeys.end: cues[i].endMs,
          VideoCompanionKeys.text: cues[i].text,
        },
    ],
    VideoCompanionKeys.audioTracks: <Map<String, Object?>>[
      for (final VideoCompanionTrack t in frame.audioTracks)
        <String, Object?>{
          VideoCompanionKeys.id: t.id,
          VideoCompanionKeys.label: t.label,
          VideoCompanionKeys.selected: t.selected,
        },
    ],
    VideoCompanionKeys.subtitleTracks: <Map<String, Object?>>[
      for (final VideoCompanionTrack t in subtitleTracks)
        <String, Object?>{
          VideoCompanionKeys.source: t.id,
          VideoCompanionKeys.label: t.label,
          VideoCompanionKeys.selected: t.selected,
        },
    ],
    VideoCompanionKeys.subtitlesOff:
        source == null || source.isEmpty || SubtitleSource.isOff(source),
    VideoCompanionKeys.subtitleLoading: frame.subtitleLoading,
    if (infoJson.isNotEmpty) VideoCompanionKeys.info: infoJson,
    VideoCompanionKeys.autoPause: frame.autoPause,
    VideoCompanionKeys.loop: <String, Object?>{
      VideoCompanionKeys.on: frame.loopOn,
      if (frame.loopOn && loopTimes != null)
        VideoCompanionKeys.times: loopTimes,
      if (frame.loopOn && loopRemaining != null)
        VideoCompanionKeys.remaining: loopRemaining,
    },
    VideoCompanionKeys.abA: ?abA,
    VideoCompanionKeys.abB: ?abB,
  };
}

/// What the video page offers the companion: its state ([frame]) and the
/// executors behind the panel's controls. Implemented by the page with the
/// same paths as its own buttons / remote control.
abstract interface class VideoCompanionPage {
  /// The title on show (null before the video is loaded).
  String? get title;

  /// The player is playing (cheap; false while it is not ready).
  bool get playing;

  /// The page state now; null while the player is not ready.
  VideoCompanionFrame? frame();

  /// The primary subtitle tracks that can be selected (enumerates once per
  /// video, like opening the page's subtitle menu).
  Future<List<VideoCompanionTrack>> subtitleTracks();

  /// Cached scrape metadata; null when nothing is cached.
  Future<VideoCompanionInfo?> loadInfo(String bookUid, int? collectionId);

  Future<void> toggle();
  Future<void> previousCue();
  Future<void> nextCue();
  Future<void> seekToMs(int positionMs);
  Future<void> seekByMs(int deltaMs);

  /// Jumps to the cue starting at [startMs] (text to tell equal starts
  /// apart), as tapping it in the page's subtitle list does.
  Future<void> jumpToCue(int startMs, String text);
  Future<void> selectAudioTrack(String id);
  Future<void> selectSubtitle(String source);
  Future<void> subtitleOff();

  /// Mines the current subtitle line.
  Future<void> mineLine();

  /// Line study: replays the current line (the last one before the playhead
  /// between lines) and pauses at its end.
  Future<void> replayLineThenPause();

  /// Line study: pause after each line on / off.
  Future<void> setAutoPause(bool on);

  /// Line study: loop the current line [times] more times (0 = forever,
  /// negative = stop looping).
  Future<void> loopLine(int times);

  /// Line study: one A-B loop step.
  Future<void> abLoop(VideoCompanionAbStep step);

  /// Counts one lookup made on the companion for this video, with the
  /// page's own lookup counter (the one its in-page popup uses).
  void countLookup();

  /// The companion shows a lookup for this video: the page's pause on lookup
  /// (as when its in-page popup opens).
  void lookupOpened();

  /// That lookup closed ([resume]: by the user) or went away with the
  /// companion: the page's popup-close resume.
  void lookupClosed({required bool resume});
}

/// The video page's end of the companion: claims the video context, publishes
/// the module snapshot (~1/s, only while the companion is up and the page is
/// on top), loads the cached metadata and the subtitle track list once per
/// video (async, outside the snapshot tick), answers the panel's commands
/// and keeps the now-playing bar informed.
class VideoCompanionHook {
  VideoCompanionHook(
    this._page, {
    CompanionContextRegistry? registry,
    CompanionVideoPlaybackRegistry? nowPlaying,
    Duration period = const Duration(seconds: 1),
  }) : _link = CompanionPageLink(registry: registry, period: period),
       _nowPlaying = nowPlaying ?? companionVideoPlayback;

  final VideoCompanionPage _page;
  final CompanionPageLink _link;
  final CompanionVideoPlaybackRegistry _nowPlaying;

  Route<Object?>? _pageRoute;
  Route<Object?>? _fullscreenRoute;
  String? _claimedTitle;
  bool _started = false;
  bool _disposed = false;

  String? _infoKey;
  VideoCompanionInfo? _info;

  String? _subsKey;
  bool _subsLoading = false;
  List<VideoCompanionTrack> _subs = const <VideoCompanionTrack>[];

  String? _sentTitle;
  bool? _sentPlaying;

  /// The companion is up (one synchronous check).
  bool get isActive => _link.isActive;

  /// A lookup the companion shows is open for this video.
  bool get lookupOpen => _link.lookupOpen;

  /// Claims the video context for the page in [pageRoute] and starts
  /// publishing (call from `didChangeDependencies`).
  void attach(Route<Object?>? pageRoute) {
    if (_disposed) return;
    _pageRoute = pageRoute;
    _claim();
    if (_started) return;
    _started = true;
    _nowPlaying.register(
      this,
      CompanionVideoPlayback(
        title: () => _page.title ?? '',
        playing: () => _page.playing,
        toggle: () => _run(_page.toggle),
      ),
    );
    _link.startSnapshots(buildSnapshot);
  }

  /// The video moved into its own fullscreen route ([route]) or back to the
  /// page (null): the claim counts while the route showing the video is on
  /// top.
  void setFullscreenRoute(Route<Object?>? route) {
    if (_disposed || identical(route, _fullscreenRoute)) return;
    _fullscreenRoute = route;
    if (_started) _claim();
  }

  void _claim() {
    _claimedTitle = _page.title;
    _link.claim(
      CompanionContext(CompanionContextKind.video, title: _claimedTitle),
      route: _fullscreenRoute ?? _pageRoute,
      onCommand: (String action, Map<String, Object?> args) =>
          unawaited(handleCommand(action, args)),
      onLookupCounted: _page.countLookup,
      onLookupOpened: _page.lookupOpened,
      onLookupClosed: _page.lookupClosed,
    );
  }

  /// The snapshot builder (runs on the link's tick while active and on top).
  Map<String, Object?>? buildSnapshot() {
    if (_disposed) return null;
    if (_page.title != _claimedTitle) _claim();
    final VideoCompanionFrame? frame = _page.frame();
    if (frame == null) return null;
    _syncNowPlaying(frame);
    _ensureInfo(frame);
    _ensureSubtitleTracks(frame);
    return buildVideoCompanionSnapshot(
      frame,
      info: _info,
      subtitleTracks: _subs,
    );
  }

  void _syncNowPlaying(VideoCompanionFrame frame) {
    if (frame.title == _sentTitle && frame.playing == _sentPlaying) return;
    _sentTitle = frame.title;
    _sentPlaying = frame.playing;
    _nowPlaying.changed();
  }

  void _ensureInfo(VideoCompanionFrame frame) {
    final String key = '${frame.bookUid}|${frame.collectionId}';
    if (key == _infoKey) return;
    _infoKey = key;
    _info = null;
    unawaited(_loadInfo(key, frame.bookUid, frame.collectionId));
  }

  Future<void> _loadInfo(String key, String bookUid, int? collectionId) async {
    final VideoCompanionInfo? info = await _page.loadInfo(
      bookUid,
      collectionId,
    );
    if (_disposed || key != _infoKey) return;
    _info = info;
    _link.publishNow();
  }

  void _ensureSubtitleTracks(VideoCompanionFrame frame) {
    final String key = '${frame.bookUid}|${frame.subtitleSource}';
    if (key == _subsKey || _subsLoading) return;
    _subsKey = key;
    unawaited(_loadSubtitleTracks(key));
  }

  Future<void> _loadSubtitleTracks(String key) async {
    _subsLoading = true;
    final List<VideoCompanionTrack> tracks;
    try {
      tracks = await _page.subtitleTracks();
    } finally {
      _subsLoading = false;
    }
    if (_disposed) return;
    // Loaded for [key]; when the page moved on meanwhile (another video or
    // source), the next tick sees a different key and loads again.
    _subs = tracks;
    _link.publishNow();
  }

  Future<void> _run(Future<void> Function() action) async {
    await action();
    if (_disposed) return;
    _link.publishNow();
  }

  /// A control from the panel.
  Future<void> handleCommand(String action, Map<String, Object?> args) async {
    if (_disposed) return;
    switch (action) {
      case VideoCompanionActions.playPause:
        await _run(_page.toggle);
      case VideoCompanionActions.previousCue:
        await _run(_page.previousCue);
      case VideoCompanionActions.nextCue:
        await _run(_page.nextCue);
      case VideoCompanionActions.seekTo:
        final int? ms = args.intOrNull(VideoCompanionKeys.ms);
        if (ms != null) await _run(() => _page.seekToMs(ms < 0 ? 0 : ms));
      case VideoCompanionActions.seekBy:
        final int? ms = args.intOrNull(VideoCompanionKeys.ms);
        if (ms != null && ms != 0) await _run(() => _page.seekByMs(ms));
      case VideoCompanionActions.jumpToCue:
        final int? start = args.intOrNull(VideoCompanionKeys.start);
        if (start != null) {
          await _run(
            () => _page.jumpToCue(start, args.str(VideoCompanionKeys.text)),
          );
        }
      case VideoCompanionActions.selectAudio:
        final String? id = args.strOrNull(VideoCompanionKeys.id);
        if (id != null) await _run(() => _page.selectAudioTrack(id));
      case VideoCompanionActions.selectSubtitle:
        final String? source = args.strOrNull(VideoCompanionKeys.source);
        if (source != null) await _run(() => _page.selectSubtitle(source));
      case VideoCompanionActions.subtitleOff:
        await _run(_page.subtitleOff);
      case VideoCompanionActions.mineLine:
        await _run(_page.mineLine);
      case VideoCompanionActions.replayLineThenPause:
        await _run(_page.replayLineThenPause);
      case VideoCompanionActions.setAutoPause:
        final Object? on = args[VideoCompanionKeys.on];
        if (on is bool) await _run(() => _page.setAutoPause(on));
      case VideoCompanionActions.loopLine:
        final int? times = args.intOrNull(VideoCompanionKeys.times);
        if (times != null) await _run(() => _page.loopLine(times));
      case VideoCompanionActions.abLoop:
        final VideoCompanionAbStep? step = VideoCompanionAbStep.fromWire(
          args.strOrNull(VideoCompanionKeys.step),
        );
        if (step != null) await _run(() => _page.abLoop(step));
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _nowPlaying.unregister(this);
    _link.dispose();
  }
}
