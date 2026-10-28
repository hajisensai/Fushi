import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/sync/video_remote_cover.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/sync/video_remote_service.dart';
import 'package:fushi_engine/sync/video_remote_session_core.dart';

/// A normalized list sentence, retaining its own subtitle clock.
final class VideoRemoteCue {
  const VideoRemoteCue({
    required this.id,
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.delayMs,
    required this.track,
  });
  final String id;
  final String text;
  final int startMs;
  final int endMs;
  final int delayMs;
  final String track;
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'text': text,
    'startMs': startMs,
    'endMs': endMs,
    'delayMs': delayMs,
    'track': track,
  };
}

/// What a remote card is cut from, frozen when the host accepts `mine`.
///
/// Composed from the lookup's sentence-context draft exactly like the desktop
/// video page composes its own (`MiningSentenceDraft.composeText` /
/// `composeAudioRange`): [sentence] is the merged card text, [startMs] /
/// [endMs] the unpadded first-to-last span on the anchor row's subtitle clock
/// (the page pads and shifts it). Without any context both collapse to the
/// looked-up row.
final class VideoRemoteMineSelection {
  const VideoRemoteMineSelection({
    required this.sentence,
    required this.cueSentence,
    required this.startMs,
    required this.endMs,
    required this.adjusted,
  });
  final String sentence;
  final String cueSentence;
  final int startMs;
  final int endMs;

  /// Whether the phone adjusted the context (added rows or edited text). Only
  /// then does [sentence] win over a sentence the phone sent with the fields.
  final bool adjusted;
}

/// One episode of the playing work, as the phone's episode picker lists it.
final class VideoRemoteEpisode {
  const VideoRemoteEpisode({
    required this.index,
    required this.title,
    required this.current,
    this.hasCover = false,
  });

  /// Position in the player's episode list (what `episode` commands name).
  final int index;
  final String title;
  final bool current;

  /// Whether `episodeCover` can answer for this episode (the phone only asks
  /// then).
  final bool hasCover;
  Map<String, Object?> toJson() => <String, Object?>{
    'index': index,
    'title': title,
    'current': current,
    if (hasCover) 'hasCover': true,
  };
}

/// One primary-subtitle choice of the playing video. [id] is opaque to the
/// phone: the player derives it from its own track source, which can be a
/// local file path that must not leave the computer.
final class VideoRemoteSubtitleOption {
  const VideoRemoteSubtitleOption({
    required this.id,
    required this.label,
    required this.kind,
    required this.selected,
    required this.selectable,
  });
  final String id;
  final String label;

  /// `embedded` / `graphic` / `external` / `host` / `youtube`.
  final String kind;
  final bool selected;
  final bool selectable;
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    'kind': kind,
    'selected': selected,
    'selectable': selectable,
  };
}

/// One online subtitle the computer found for the playing video. [id] is
/// opaque and only valid until the next search.
final class VideoRemoteOnlineSubtitle {
  const VideoRemoteOnlineSubtitle({
    required this.id,
    required this.fileName,
    required this.provider,
    this.language,
    this.episode,
    this.aiTranslated = false,
    this.hearingImpaired = false,
  });
  final String id;
  final String fileName;
  final String provider;
  final String? language;
  final int? episode;
  final bool aiTranslated;
  final bool hearingImpaired;
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'fileName': fileName,
    'provider': provider,
    if (language != null) 'language': language,
    if (episode != null) 'episode': episode,
    'aiTranslated': aiTranslated,
    'hearingImpaired': hearingImpaired,
  };
}

/// Result of a `subtitleSearch`: the query / episode the computer actually
/// searched with (its own defaults when the phone sent none) and the hits.
final class VideoRemoteOnlineSubtitleSearch {
  const VideoRemoteOnlineSubtitleSearch({
    required this.query,
    required this.candidates,
    this.episode,
  });
  final String query;
  final int? episode;
  final List<VideoRemoteOnlineSubtitle> candidates;
  Map<String, Object?> toJson() => <String, Object?>{
    'query': query,
    if (episode != null) 'episode': episode,
    'candidates': <Map<String, Object?>>[
      for (final VideoRemoteOnlineSubtitle candidate in candidates)
        candidate.toJson(),
    ],
  };
}

/// One video of the computer's library, as the phone's on-demand picker lists
/// it. Library identity and display text only, never media paths.
final class VideoRemoteLibraryItem {
  const VideoRemoteLibraryItem({
    required this.bookUid,
    required this.title,
    this.collection,
    this.positionMs = 0,
    this.lastPlayedAt,
    this.coverPath,
  });
  final String bookUid;
  final String title;

  /// Title of the collection the video plays in (its episode list), if any.
  final String? collection;
  final int positionMs;
  final int? lastPlayedAt;

  /// The cover file on this computer. Never sent: only its modification time
  /// goes out as `coverVersion` ([videoRemoteCoverVersion]), computed for the
  /// requested page only.
  final String? coverPath;

  Map<String, Object?> toJson({int? coverVersion}) => <String, Object?>{
    'bookUid': bookUid,
    'title': title,
    if (collection != null) 'collection': collection,
    'positionMs': positionMs,
    if (lastPlayedAt != null) 'lastPlayedAt': lastPlayedAt,
    if (coverVersion != null) 'coverVersion': coverVersion,
  };
}

/// Modification time (ms) of a cover file as its version; null without a
/// cover or when the file is gone. The phone fetches a cover (from the
/// interconnect library's cover endpoint, same `coverPath`) only when this is
/// set and keys its cache by it, so a re-scraped cover is fetched again.
Future<int?> videoRemoteCoverVersion(String? coverPath) async {
  if (coverPath == null || coverPath.isEmpty) return null;
  final FileStat stat = await FileStat.stat(coverPath);
  if (stat.type != FileSystemEntityType.file) return null;
  return stat.modified.millisecondsSinceEpoch;
}

/// App-owned access to the computer's video library for on-demand playback
/// (`library` / `openVideo`). Unlike [VideoRemotePlaybackBinding] it does not
/// depend on a video page being open: the phone uses it to start one.
final class VideoRemoteLibrary {
  const VideoRemoteLibrary({
    required this.list,
    required this.open,
    this.openDisc,
  });

  /// The library in display order (most recently played first).
  final Future<List<VideoRemoteLibraryItem>> Function() list;

  /// Closes the open video page through its normal exit and opens [bookUid].
  /// Fails with a [VideoRemoteException] (`video_missing` / `host_busy`).
  final Future<void> Function(String bookUid) open;

  /// Like [open], but enters the disc session of the original disc [bookUid]
  /// is a title of (`openVideo` with `discMenu: true`). Null = this host
  /// cannot (`openDiscMenu` is not advertised).
  final Future<void> Function(String bookUid)? openDisc;
}

/// App-owned callbacks; the HTTP layer never sees media paths or widget state.
/// Applies a subtitle [VideoRemotePlaybackBinding.downloadSubtitle] fetched.
typedef VideoRemoteSubtitleApply = Future<void> Function();

final class VideoRemotePlaybackBinding {
  const VideoRemotePlaybackBinding({
    required this.identity,
    required this.title,
    required this.bookUid,
    required this.sectionIndex,
    required this.cues,
    required this.state,
    required this.command,
    required this.mine,
    required this.openFavorite,
    required this.addListener,
    required this.removeListener,
    this.favoritesChanged,
    this.previewAudio,
    this.stopAudio,
    this.setVolume,
    this.episodes,
    this.switchEpisode,
    this.subtitleTracks,
    this.selectSubtitleTrack,
    this.searchSubtitles,
    this.downloadSubtitle,
    this.caret,
    this.episodeCover,
    this.close,
  });
  final String Function() identity;
  final String Function() title;
  final String Function() bookUid;
  final int Function() sectionIndex;
  final List<VideoRemoteCue> Function() cues;
  final Map<String, Object?> Function() state;
  final Future<void> Function(String, Map<String, dynamic>) command;
  final Future<Map<String, Object?>> Function(
    VideoRemoteCue,
    Map<String, dynamic>,
    VideoRemoteMineSelection,
  )
  mine;
  final Future<void> Function(FavoriteSentence) openFavorite;
  final void Function(VoidCallback) addListener;
  final void Function(VoidCallback) removeListener;
  final Future<void> Function()? favoritesChanged;

  /// Plays the subtitle-clock span `[startMs, endMs]` of [anchor]'s track on
  /// the desktop player (the context dialog's audio preview). Returns false
  /// when there is nothing to play. Null: the preview is unavailable.
  final Future<bool> Function(VideoRemoteCue anchor, int startMs, int endMs)?
  previewAudio;

  /// Stops [previewAudio]. Null falls back to the `pause` command.
  final Future<void> Function()? stopAudio;

  /// Sets the desktop volume (0..100) the way its own volume slider does.
  /// Null: the `volume` action is unsupported.
  final Future<void> Function(int volume)? setVolume;

  /// The work's episodes (empty for a single video). Together with
  /// [switchEpisode] it enables the `episode` action.
  final List<VideoRemoteEpisode> Function()? episodes;

  /// Switches to episode [index] the way the desktop episode list does. May
  /// complete before the new episode is playing; the new session reaches the
  /// phone through the state journal.
  final Future<void> Function(int index)? switchEpisode;

  /// Primary-subtitle choices. Together with [selectSubtitleTrack] it enables
  /// the `subtitleTrack` action.
  final Future<List<VideoRemoteSubtitleOption>> Function()? subtitleTracks;

  /// Selects the primary subtitle [trackId] from [subtitleTracks], or turns
  /// it off when null. Fails with a [VideoRemoteException].
  final Future<void> Function(String? trackId)? selectSubtitleTrack;

  /// Searches online subtitles for the playing video; null [query] /
  /// [episode] use the computer's own defaults. Together with
  /// [downloadSubtitle] it enables `subtitleSearch` / `subtitleDownload`.
  final Future<VideoRemoteOnlineSubtitleSearch> Function(
    String? query,
    int? episode,
  )?
  searchSubtitles;

  /// Downloads hit [candidateId] of the last [searchSubtitles] and returns
  /// the step that applies it as the primary subtitle. Fails with a
  /// [VideoRemoteException].
  ///
  /// The download is slow and runs beside the command queue, so it must not
  /// touch the player: the host revalidates the session after it and only
  /// then runs the returned step inside the queue. The step itself must also
  /// refuse (409 `session_changed`) when the player it was downloaded for is
  /// no longer the one playing.
  final Future<VideoRemoteSubtitleApply> Function(String candidateId)?
  downloadSubtitle;

  /// Runs one step from [videoRemoteCaretActions] on the computer's subtitle
  /// word cursor and returns its surface afterwards (one of
  /// [videoRemoteCaretSurfaces]). The binding's `state` should report the
  /// same surface as `caret`. Null: the `caret` action is unsupported.
  final Future<String> Function(String action)? caret;

  /// The stored cover bytes of episode [index] (null: it has none); the host
  /// scales them down to a preview before they leave the computer. Null:
  /// `episodeCover` is unsupported.
  final Future<Uint8List?> Function(int index)? episodeCover;

  /// Closes this video page through its normal exit (position saved). Fails
  /// with a [VideoRemoteException] (`host_busy` when something the phone
  /// cannot close sits on top of it). Null: `closeVideo` is unsupported.
  final Future<void> Function()? close;

  /// Optional controls this player supports (snapshot `capabilities`).
  List<String> get capabilities => <String>[
    if (setVolume != null) videoRemoteCapabilityVolume,
    if (episodes != null && switchEpisode != null)
      videoRemoteCapabilityEpisodes,
    if (subtitleTracks != null && selectSubtitleTrack != null)
      videoRemoteCapabilitySubtitleTracks,
    if (searchSubtitles != null && downloadSubtitle != null)
      videoRemoteCapabilitySubtitleSearch,
    if (caret != null) videoRemoteCapabilityCaret,
    if (close != null) videoRemoteCapabilityCloseVideo,
  ];
}

/// One selected desktop player, one authenticated controller and fixed drafts.
final class VideoRemoteHost implements VideoRemoteService {
  VideoRemoteHost({
    required FavoriteSentenceRepository Function() favorites,
    Stream<String?> Function()? favoriteChanges,
    VideoRemoteLibrary? library,
    DateTime Function()? now,
  }) : _favorites = favorites,
       _favoriteChanges = favoriteChanges,
       _library = library,
       _now = now ?? DateTime.now {
    _core = VideoRemoteSessionCore(now: _now, onLeaseExpired: _expireLookup);
  }
  final FavoriteSentenceRepository Function() _favorites;
  final Stream<String?> Function()? _favoriteChanges;
  StreamSubscription<String?>? _favoriteSubscription;
  final VideoRemoteLibrary? _library;
  final DateTime Function() _now;
  late final VideoRemoteSessionCore _core;
  VideoRemotePlaybackBinding? _binding;
  String? _identity;
  String _sessionId = '';
  int _serial = 0;
  int _subtitleVersion = 0;
  int _favoriteVersion = 0;
  String? _playbackError;
  List<VideoRemoteCue> _cues = const <VideoRemoteCue>[];
  Map<String, VideoRemoteCue> _cueMap = <String, VideoRemoteCue>{};
  Map<String, Object?> _lastState = <String, Object?>{};
  DateTime? _lastPublish;
  _RemoteLookup? _lookup;
  final Map<String, _RemoteMineTask> _tasks = <String, _RemoteMineTask>{};
  Future<void> _mutationTail = Future<void>.value();

  /// Players still open, oldest first; the last one is [_binding]. A page
  /// opened over another player (the in-app browser over a native video page,
  /// or the reverse) takes the phone, and closing it hands the phone back to
  /// the one underneath instead of leaving it with no video (BUG-3874).
  final List<VideoRemotePlaybackBinding> _open = <VideoRemotePlaybackBinding>[];

  void register(VideoRemotePlaybackBinding binding) {
    _open
      ..removeWhere((VideoRemotePlaybackBinding b) => identical(b, binding))
      ..add(binding);
    final VideoRemotePlaybackBinding? old = _binding;
    if (old != null) {
      old.removeListener(_changed);
    }
    _binding = binding;
    _identity = null;
    _playbackError = null;
    _lookup = null;
    binding.addListener(_changed);
    _refresh();
    _publish();
  }

  void unregister(VideoRemotePlaybackBinding binding) {
    _open.removeWhere((VideoRemotePlaybackBinding b) => identical(b, binding));
    if (!identical(binding, _binding)) {
      return;
    }
    binding.removeListener(_changed);
    _binding = null;
    _identity = null;
    _lookup = null;
    _cues = const <VideoRemoteCue>[];
    _cueMap.clear();
    _sessionId = '';
    final VideoRemotePlaybackBinding? underneath = _open.lastOrNull;
    if (underneath != null) {
      register(underneath);
      return;
    }
    _publish();
  }

  /// Reports an asynchronous failure the phone cannot get from a response,
  /// e.g. the page opened by `openFavorite` failing to load its source.
  ///
  /// The code rides on the `state` snapshot until the controller's next
  /// successful operation, a session (video identity) change or a new player
  /// registration; it never outlives the attempt it describes.
  void reportError(String code) {
    _playbackError = code;
    _publish();
  }

  void _refresh() {
    final VideoRemotePlaybackBinding? binding = _binding;
    if (binding == null) {
      return;
    }
    final String identity = binding.identity();
    final List<VideoRemoteCue> next = binding.cues();
    if (identity != _identity) {
      _identity = identity;
      _sessionId = '${_now().microsecondsSinceEpoch}_${++_serial}';
      _lookup = null;
      // A reported failure belongs to the session it was raised in.
      _playbackError = null;
      _subtitleVersion++;
      _cues = next;
      _cueMap = <String, VideoRemoteCue>{
        for (final VideoRemoteCue cue in next) cue.id: cue,
      };
    } else if (!identical(next, _cues)) {
      _subtitleVersion++;
      // Track/clock changes invalidate the draft and its resume permission.
      // Never schedule an asynchronous play that can overtake the next lookup.
      _lookup = null;
      _cues = next;
      _cueMap = <String, VideoRemoteCue>{
        for (final VideoRemoteCue cue in next) cue.id: cue,
      };
    }
  }

  void _changed() {
    // No phone subscribed: do not compute transcript views on every video tick.
    if (_core.owner == null) {
      return;
    }
    final String oldSession = _sessionId;
    final int oldVersion = _subtitleVersion;
    _refresh();
    final Map<String, Object?> state = _binding?.state() ?? <String, Object?>{};
    final bool immediate =
        oldSession != _sessionId ||
        oldVersion != _subtitleVersion ||
        state['playing'] != _lastState['playing'] ||
        state['speed'] != _lastState['speed'] ||
        // Volume has no periodic tick of its own: a paused player would
        // otherwise keep the phone's volume stale until the next change.
        state['volume'] != _lastState['volume'] ||
        // The word cursor moves with no player tick (see `caret`).
        state['caret'] != _lastState['caret'] ||
        state['controlRevision'] != _lastState['controlRevision'];
    if (immediate ||
        _lastPublish == null ||
        _now().difference(_lastPublish!) >= const Duration(seconds: 1)) {
      _publish();
    }
  }

  Map<String, Object?> _snapshot() => <String, Object?>{
    'available': _binding != null, 'revision': _core.revision,
    'sessionId': _sessionId, 'subtitleVersion': _subtitleVersion,
    'favoriteVersion': _favoriteVersion, 'title': _binding?.title() ?? '',
    if (_playbackError != null) 'error': _playbackError,
    // Public library identity only, never local paths or signed media URLs.
    'identity': _binding?.bookUid() ?? '', 'cueCount': _cues.length,
    'sectionIndex': _binding?.sectionIndex(),
    'capabilities': <String>[
      ...?_binding?.capabilities,
      if (_library != null) videoRemoteCapabilityOpenVideo,
      if (_library?.openDisc != null) videoRemoteCapabilityOpenDiscMenu,
    ],
    ...?_binding?.state(),
  };

  void _publish() {
    _lastState = _binding?.state() ?? <String, Object?>{};
    _lastPublish = _now();
    _core.publish('state', _snapshot());
  }

  VideoRemotePlaybackBinding _requireSession(Map<String, dynamic> body) {
    _refresh();
    final VideoRemotePlaybackBinding? binding = _binding;
    if (binding == null) {
      throw const VideoRemoteException(409, 'no_video');
    }
    if (body['sessionId'] != _sessionId) {
      throw const VideoRemoteException(409, 'session_changed');
    }
    if (body['subtitleVersion'] != _subtitleVersion) {
      throw const VideoRemoteException(409, 'subtitles_changed');
    }
    return binding;
  }

  VideoRemoteCue _requireCue(Map<String, dynamic> body) {
    final VideoRemoteCue? cue = _cueMap[body['cueId']];
    if (cue == null) {
      throw const VideoRemoteException(404, 'cue_missing');
    }
    return cue;
  }

  @override
  Future<Map<String, Object?>> handle(
    String operation,
    Map<String, dynamic> body,
    String peerId,
  ) async {
    if (operation == 'snapshot') {
      await _core.acquire(peerId);
      _favoriteSubscription ??= _favoriteChanges?.call().listen((String? _) {
        _favoriteVersion++;
        final Future<void> Function()? changed = _binding?.favoritesChanged;
        if (changed != null) {
          unawaited(
            changed().catchError((Object error, StackTrace stack) {
              debugPrint(
                'Video remote favorite cache refresh failed: $error\n$stack',
              );
            }),
          );
        }
        _publish();
      });
      _refresh();
      return _snapshot();
    }
    await _core.assertOwner(peerId);
    if (operation == 'events') {
      return _core.events(
        _integer(body, 'afterRevision', 0),
        waitMs: _integer(body, 'waitMs', 25000).clamp(0, 25000),
      );
    }
    if (operation == 'subtitles') {
      _requireSession(body);
      final int offset = _integer(body, 'offset', 0).clamp(0, _cues.length);
      final int limit = _integer(body, 'limit', 200).clamp(1, 200);
      final List<FavoriteSentence> favorites = await _favorites().getAll();
      _requireSession(body);
      return <String, Object?>{
        'offset': offset,
        'total': _cues.length,
        'subtitleVersion': _subtitleVersion,
        'cues': _cues
            .skip(offset)
            .take(limit)
            .map(
              (VideoRemoteCue cue) => <String, Object?>{
                ...cue.toJson(),
                'favorited': favorites.any(
                  (FavoriteSentence favorite) => _matches(favorite, cue),
                ),
              },
            )
            .toList(),
      };
    }
    if (operation == 'favorites') {
      return _listFavorites(body);
    }
    if (operation == 'playbackOptions') {
      return _playbackOptions(body);
    }
    if (operation == 'library') {
      return _listLibrary(body);
    }
    if (operation == 'subtitleSearch') {
      return _searchSubtitles(body);
    }
    if (operation == 'episodeCover') {
      return _episodeCover(body);
    }
    if (operation == 'mineStatus') {
      _RemoteMineTask? task = _tasks[body['taskId']];
      if (task == null && body['requestId'] is String) {
        for (final _RemoteMineTask candidate in _tasks.values) {
          if (candidate.peerId == peerId &&
              candidate.requestId == body['requestId']) {
            task = candidate;
            break;
          }
        }
      }
      if (task == null || task.peerId != peerId) {
        throw const VideoRemoteException(404, 'task_missing');
      }
      return task.toJson();
    }
    if (!videoRemoteOperations.contains(operation)) {
      throw const VideoRemoteException(404, 'unknown_operation');
    }
    final String requestId = body['requestId'] is String
        ? body['requestId'] as String
        : '';
    final String fingerprint = _fingerprint(operation, body);
    if (operation == 'mine') {
      // Mining outlives the generic request journal. Preserve retry identity
      // while the accepted task is still available to mineStatus.
      for (final _RemoteMineTask task in _tasks.values) {
        if (task.peerId == peerId && task.requestId == requestId) {
          if (task.fingerprint != fingerprint) {
            throw const VideoRemoteException(409, 'request_id_conflict');
          }
          return task.toJson();
        }
      }
    }
    Future<Map<String, Object?>> run() async {
      // Queued commands revalidate their owner/session at execution time.
      await _core.assertOwner(peerId);
      final Map<String, Object?> result = await _mutate(
        operation,
        body,
        peerId,
      );
      // A successful controller operation supersedes an earlier failure.
      if (_playbackError != null) {
        _playbackError = null;
        _publish();
      }
      return result;
    }

    // A subtitle download (network, archive, alignment against the embedded
    // track) can take longer than the phone's request timeout; queued behind
    // it, play / pause / seek would stall just as long. The download runs
    // beside the queue and a phone retry with the same request ID joins it
    // instead of downloading again; only the apply step re-enters the queue,
    // after revalidating the session (see the `subtitleDownload` branch).
    final bool beside =
        operation == 'command' && body['action'] == 'subtitleDownload';
    return _core.runIdempotent(
      peerId,
      requestId,
      () => beside ? run() : _serialize(run),
      fingerprint: fingerprint,
    );
  }

  Future<Map<String, Object?>> _serialize(
    Future<Map<String, Object?>> Function() action,
  ) {
    final Future<Map<String, Object?>> result = _mutationTail.then(
      (_) => action(),
    );
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<Map<String, Object?>> _mutate(
    String operation,
    Map<String, dynamic> body,
    String peerId,
  ) async {
    final int leaseGeneration = _core.leaseGeneration;
    if (operation == 'disconnect') {
      await _expireLookup(peerId);
      _core.release(peerId);
      return <String, Object?>{'ok': true};
    }
    if (operation == 'lookupEnd') {
      final _RemoteLookup? lookup = _lookup;
      if (lookup != null &&
          lookup.peerId == peerId &&
          body['contextId'] == lookup.id) {
        _lookup = null;
        await _resume(lookup);
      }
      return <String, Object?>{'ok': true};
    }
    if (operation == 'favoritesRemove') {
      final Object? ids = body['ids'];
      if (ids is! List ||
          ids.length > 200 ||
          ids.any((Object? id) => id is! String)) {
        throw const VideoRemoteException(400, 'invalid_favorites');
      }
      final FavoriteSentenceRepository repo = _favorites();
      final List<FavoriteSentence> all = await repo.getAll();
      for (final FavoriteSentence favorite in all) {
        if (favorite.source == kFavoriteSentenceSourceVideo &&
            ids.contains(favorite.id)) {
          await repo.removeById(favorite.id);
        }
      }
      _favoriteVersion++;
      _publish();
      return <String, Object?>{'ok': true, 'favoriteVersion': _favoriteVersion};
    }
    if (operation == 'openFavorite') {
      final List<FavoriteSentence> all = await _favorites().getAll();
      final FavoriteSentence favorite = all.firstWhere(
        (FavoriteSentence favorite) =>
            favorite.id == body['id'] &&
            favorite.source == kFavoriteSentenceSourceVideo,
        orElse: () => throw const VideoRemoteException(404, 'favorite_missing'),
      );
      final VideoRemotePlaybackBinding? binding = _binding;
      if (binding == null) {
        throw const VideoRemoteException(409, 'no_video');
      }
      _lookup = null;
      await binding.openFavorite(favorite);
      _refresh();
      _publish();
      return <String, Object?>{'ok': true};
    }
    if (operation == 'openVideo') {
      final VideoRemoteLibrary? library = _library;
      if (library == null) {
        throw const VideoRemoteException(409, videoRemoteActionUnsupported);
      }
      final Object? bookUid = body['bookUid'];
      if (bookUid is! String || bookUid.isEmpty) {
        throw const VideoRemoteException(400, 'invalid_argument');
      }
      final Future<void> Function(String bookUid)? openDisc = library.openDisc;
      if (body['discMenu'] == true && openDisc == null) {
        throw const VideoRemoteException(409, videoRemoteActionUnsupported);
      }
      // The outgoing page's lookup pause ends with the page; never resume it.
      _lookup = null;
      if (body['discMenu'] == true) {
        await openDisc!(bookUid);
      } else {
        await library.open(bookUid);
      }
      return <String, Object?>{'ok': true};
    }
    if (operation == 'closeVideo') {
      _refresh();
      final VideoRemotePlaybackBinding? binding = _binding;
      if (binding == null) throw const VideoRemoteException(409, 'no_video');
      // Only the video the phone is looking at; the subtitle version is not
      // checked, a reloaded subtitle does not make it another video.
      if (body['sessionId'] != _sessionId) {
        throw const VideoRemoteException(409, 'session_changed');
      }
      final Future<void> Function()? close = binding.close;
      if (close == null) {
        throw const VideoRemoteException(409, videoRemoteActionUnsupported);
      }
      // The closing page's lookup pause ends with the page; never resume it.
      _lookup = null;
      await close();
      return <String, Object?>{'ok': true};
    }
    if (operation == 'lookupContext') {
      return _lookupContext(_requireLookup(body, peerId), body);
    }
    if (operation == 'mine') {
      final String fingerprint = _fingerprint(operation, body);
      final _RemoteLookup lookup = _requireLookup(body, peerId);
      final Object? fields = body['fields'];
      if (fields is! Map<String, dynamic>) {
        throw const VideoRemoteException(400, 'invalid_fields');
      }
      if (_tasks.values.any(
        (_RemoteMineTask task) => task.status == 'running',
      )) {
        throw const VideoRemoteException(429, 'mining_busy');
      }
      if (_tasks.length >= 128) {
        _tasks.remove(_tasks.keys.first);
      }
      // The original peer/request can query this task after the draft closes.
      final String id = 'mine_${++_serial}';
      final _RemoteMineTask task = _RemoteMineTask(
        id,
        peerId,
        body['requestId'] as String,
        fingerprint,
      );
      _tasks[id] = task;
      final VideoRemotePlaybackBinding binding = lookup.binding;
      // Frozen now: later context edits must not change an accepted card.
      final VideoRemoteMineSelection selection = _selection(lookup);
      final Future<Map<String, Object?>> work =
          Future<Map<String, Object?>>.sync(
            () => binding.mine(lookup.cue, fields, selection),
          );
      unawaited(
        work.then<void>(
          (Map<String, Object?> result) {
            task.result = result;
            task.status = result['success'] == true ? 'succeeded' : 'failed';
            if (task.status == 'failed') {
              task.error = result['error']?.toString() ?? 'mining_failed';
            } else if (identical(_lookup, lookup)) {
              // Same as the desktop page: a landed card consumes the draft.
              lookup.draft.clear();
            }
            _core.publish('mine', task.toJson());
          },
          onError: (Object error, StackTrace stack) {
            task.status = 'failed';
            task.error = error is VideoRemoteException
                ? error.code
                : 'mining_failed';
            debugPrint('Video remote mining failed: $error\n$stack');
            _core.publish('mine', task.toJson());
          },
        ),
      );
      return task.toJson();
    }
    final VideoRemotePlaybackBinding binding = _requireSession(body);
    if (operation == 'command') {
      final String action = body['action']?.toString() ?? '';
      if (!videoRemoteCommandActions.contains(action)) {
        throw const VideoRemoteException(400, 'invalid_action');
      }
      if (action == 'volume') {
        // Not a playback intent: an open lookup keeps its pause.
        final Future<void> Function(int)? setVolume = binding.setVolume;
        if (setVolume == null) {
          throw const VideoRemoteException(409, videoRemoteActionUnsupported);
        }
        final Object? volume = body['volume'];
        if (volume is! int || volume < 0 || volume > 100) {
          throw const VideoRemoteException(400, 'invalid_number');
        }
        await setVolume(volume);
        _publish();
        return <String, Object?>{'ok': true};
      }
      if (action == 'episode') {
        final List<VideoRemoteEpisode> Function()? episodes = binding.episodes;
        final Future<void> Function(int)? switchEpisode = binding.switchEpisode;
        if (episodes == null || switchEpisode == null) {
          throw const VideoRemoteException(409, videoRemoteActionUnsupported);
        }
        final Object? index = body['episodeIndex'];
        if (index is! int) {
          throw const VideoRemoteException(400, 'invalid_number');
        }
        if (!episodes().any((VideoRemoteEpisode e) => e.index == index)) {
          throw const VideoRemoteException(404, 'episode_missing');
        }
        _lookup = null;
        await switchEpisode(index);
        _refresh();
        _publish();
        return <String, Object?>{'ok': true};
      }
      if (action == 'subtitleTrack') {
        final Future<void> Function(String?)? select =
            binding.selectSubtitleTrack;
        if (binding.subtitleTracks == null || select == null) {
          throw const VideoRemoteException(409, videoRemoteActionUnsupported);
        }
        final Object? trackId = body['trackId'];
        if (trackId != null && (trackId is! String || trackId.isEmpty)) {
          throw const VideoRemoteException(400, 'invalid_argument');
        }
        _lookup = null;
        await select(trackId as String?);
        _refresh();
        _publish();
        return <String, Object?>{'ok': true};
      }
      if (action == 'subtitleDownload') {
        final Future<VideoRemoteSubtitleApply> Function(String)? download =
            binding.downloadSubtitle;
        if (binding.searchSubtitles == null || download == null) {
          throw const VideoRemoteException(409, videoRemoteActionUnsupported);
        }
        final Object? candidateId = body['candidateId'];
        if (candidateId is! String || candidateId.isEmpty) {
          throw const VideoRemoteException(400, 'invalid_argument');
        }
        // The download runs beside the queue (see [handle]); the apply joins
        // it, so it is ordered after any episode switch / track change the
        // phone sent meanwhile, and is refused when the session it was
        // downloaded for is gone.
        final VideoRemoteSubtitleApply apply = await download(candidateId);
        return _serialize(() async {
          await _core.assertOwner(peerId);
          _refresh();
          if (!identical(binding, _binding) ||
              body['sessionId'] != _sessionId) {
            throw const VideoRemoteException(409, 'session_changed');
          }
          // Applying a subtitle replaces the cue list the lookup is bound to.
          _lookup = null;
          await apply();
          _refresh();
          _publish();
          return <String, Object?>{'ok': true};
        });
      }
      if (action == 'caret') {
        final Future<String> Function(String)? caret = binding.caret;
        if (caret == null) {
          throw const VideoRemoteException(409, videoRemoteActionUnsupported);
        }
        final Object? step = body['caret'];
        if (step is! String || !videoRemoteCaretActions.contains(step)) {
          throw const VideoRemoteException(400, 'invalid_argument');
        }
        final Object? count = body['count'] ?? 1;
        if (count is! int ||
            count < 1 ||
            count > videoRemoteCaretMaxCount ||
            (count > 1 && !videoRemoteCaretMoves.contains(step))) {
          throw const VideoRemoteException(400, 'invalid_number');
        }
        // The phone's own lookup (if any) is untouched: the cursor works on
        // the computer screen, the pause it takes is the page's own.
        String surface = await caret(step);
        for (int i = 1; i < count && surface != 'none'; i++) {
          surface = await caret(step);
        }
        _publish();
        return <String, Object?>{'ok': true, 'caret': surface};
      }
      _lookup = null; // Explicit playback intent supersedes automatic resume.
      final Map<String, dynamic> command = <String, dynamic>{};
      if (action == 'seekCue') {
        final VideoRemoteCue cue = _requireCue(body);
        command['positionMs'] = (cue.startMs + cue.delayMs).clamp(0, 1 << 30);
      } else if (action == 'seek') {
        command['positionMs'] = _integer(
          body,
          'positionMs',
          0,
        ).clamp(0, 1 << 30);
      }
      await binding.command(action, command);
      _publish();
      return <String, Object?>{'ok': true};
    }
    final VideoRemoteCue cue = _requireCue(body);
    if (operation == 'lookupBegin') {
      final _RemoteLookup? previous = _lookup;
      // Switching rows with the dialog open names the lookup it replaces: its
      // pause is handed over as is, never resumed and paused again (that gap
      // leaks a network round trip of audio and picture on the desktop).
      // Without the field (older phones) the previous lookup ends as before.
      _RemoteLookup? handedOver;
      if (previous != null) {
        _lookup = null;
        if (body['replaceContextId'] == previous.id &&
            previous.peerId == peerId) {
          if (await _reclaimPause(previous)) handedOver = previous;
        } else {
          await _resume(previous);
        }
        await _core.assertOwner(peerId);
        _requireLease(peerId, leaseGeneration);
        _requireSession(body);
      }
      final Map<String, Object?> before = binding.state();
      final bool wasPlaying = before['playing'] == true;
      final int beforeControl = _controlRevision(before);
      if (wasPlaying) {
        await binding.command('pause', <String, dynamic>{});
      }
      final int control = _controlRevision(binding.state());
      final _RemoteLookup lookup = _RemoteLookup(
        'lookup_${++_serial}',
        peerId,
        body['sessionId'] as String,
        body['subtitleVersion'] as int,
        binding,
        cue,
        handedOver?.resume ?? (wasPlaying && control == beforeControl + 1),
        control,
        handedOver != null
            ? handedOver.pausedAtMs
            : (before['positionMs'] as num?)?.toInt(),
      );
      try {
        await _core.assertOwner(peerId);
        _requireLease(peerId, leaseGeneration);
        _requireSession(body);
        if (!identical(binding, _binding)) {
          throw const VideoRemoteException(409, 'session_changed');
        }
      } catch (_) {
        // Expiry/host stop can clean up before an in-flight pause completes.
        // Undo only that pause, subject to the same local intent safeguards.
        await _resume(lookup);
        rethrow;
      }
      _lookup = lookup;
      _publish();
      return <String, Object?>{
        'contextId': lookup.id,
        'cue': cue.toJson(),
        'sentence': cue.text,
      };
    }
    if (operation == 'favoriteSet') {
      if (body['favorited'] is! bool) {
        throw const VideoRemoteException(400, 'invalid_favorite');
      }
      final FavoriteSentenceRepository repo = _favorites();
      final List<FavoriteSentence> all = await repo.getAll();
      await _core.assertOwner(peerId);
      _requireLease(peerId, leaseGeneration);
      _requireSession(body);
      if (!identical(binding, _binding)) {
        throw const VideoRemoteException(409, 'session_changed');
      }
      final List<FavoriteSentence> matches = all
          .where((FavoriteSentence favorite) => _matches(favorite, cue))
          .toList();
      if (body['favorited'] == true && matches.isEmpty) {
        await repo.add(
          FavoriteSentence(
            text: cue.text,
            bookTitle: binding.title(),
            createdAt: _now(),
            bookKey: binding.bookUid(),
            sectionIndex: binding.sectionIndex(),
            normCharOffset: cue.startMs,
            normCharLength: cue.endMs - cue.startMs,
            source: kFavoriteSentenceSourceVideo,
            // Same statistics-day key as every other favorite write
            // (`statTodayKey()`), honouring the configurable day reset.
            dateKey: FushiDatabase.statDateKeyOf(_now()),
          ),
        );
      } else if (body['favorited'] == false) {
        for (final FavoriteSentence favorite in matches) {
          await repo.removeById(favorite.id);
        }
      }
      _favoriteVersion++;
      _publish();
      return <String, Object?>{
        'favorited': body['favorited'],
        'favoriteVersion': _favoriteVersion,
      };
    }
    throw const VideoRemoteException(404, 'unknown_operation');
  }

  /// `playbackOptions`: the lists behind the phone's episode and subtitle-track
  /// pickers. Re-validated after the (possibly slow) track enumeration so a
  /// list never describes a session the phone no longer sees.
  Future<Map<String, Object?>> _playbackOptions(
    Map<String, dynamic> body,
  ) async {
    final VideoRemotePlaybackBinding binding = _requireSession(body);
    final List<VideoRemoteSubtitleOption> tracks =
        await binding.subtitleTracks?.call() ??
        const <VideoRemoteSubtitleOption>[];
    if (!identical(binding, _requireSession(body))) {
      throw const VideoRemoteException(409, 'session_changed');
    }
    final List<VideoRemoteEpisode> episodes =
        binding.episodes?.call() ?? const <VideoRemoteEpisode>[];
    return <String, Object?>{
      'episodes': <Map<String, Object?>>[
        for (final VideoRemoteEpisode episode in episodes) episode.toJson(),
      ],
      'subtitleTracks': <Map<String, Object?>>[
        for (final VideoRemoteSubtitleOption track in tracks) track.toJson(),
      ],
      'subtitleOff': !tracks.any(
        (VideoRemoteSubtitleOption track) => track.selected,
      ),
    };
  }

  /// `subtitleSearch`: online subtitles for the playing video. Re-validated
  /// after the (slow, networked) search like [_playbackOptions].
  Future<Map<String, Object?>> _searchSubtitles(
    Map<String, dynamic> body,
  ) async {
    final VideoRemotePlaybackBinding binding = _requireSession(body);
    final Future<VideoRemoteOnlineSubtitleSearch> Function(String?, int?)?
    search = binding.searchSubtitles;
    if (search == null || binding.downloadSubtitle == null) {
      throw const VideoRemoteException(409, videoRemoteActionUnsupported);
    }
    final Object? query = body['query'];
    if (query != null && (query is! String || query.length > 200)) {
      throw const VideoRemoteException(400, 'invalid_argument');
    }
    final Object? episode = body['episode'];
    if (episode != null && (episode is! int || episode < 0)) {
      throw const VideoRemoteException(400, 'invalid_number');
    }
    final VideoRemoteOnlineSubtitleSearch result = await search(
      query as String?,
      episode as int?,
    );
    if (!identical(binding, _requireSession(body))) {
      throw const VideoRemoteException(409, 'session_changed');
    }
    return result.toJson();
  }

  /// `episodeCover`: a small preview of one episode's cover for the phone's
  /// episode picker. Re-validated after the (possibly networked) fetch like
  /// [_playbackOptions].
  Future<Map<String, Object?>> _episodeCover(Map<String, dynamic> body) async {
    final VideoRemotePlaybackBinding binding = _requireSession(body);
    final Future<Uint8List?> Function(int)? cover = binding.episodeCover;
    if (cover == null) {
      throw const VideoRemoteException(409, videoRemoteActionUnsupported);
    }
    final Object? index = body['episodeIndex'];
    if (index is! int || index < 0) {
      throw const VideoRemoteException(400, 'invalid_number');
    }
    final Uint8List? bytes = await cover(index);
    if (!identical(binding, _requireSession(body))) {
      throw const VideoRemoteException(409, 'session_changed');
    }
    final VideoRemoteCoverPreview? preview = bytes == null
        ? null
        : await videoRemoteCoverPreview(bytes);
    if (preview == null) {
      throw const VideoRemoteException(404, 'cover_missing');
    }
    return <String, Object?>{
      'mime': preview.mime,
      'data': base64Encode(preview.bytes),
    };
  }

  /// The open lookup [body] names, still bound to the current session and
  /// subtitle version; anything else is `lookup_expired`.
  _RemoteLookup _requireLookup(Map<String, dynamic> body, String peerId) {
    final _RemoteLookup? lookup = _lookup;
    _refresh();
    if (lookup == null ||
        lookup != _lookup ||
        lookup.peerId != peerId ||
        lookup.id != body['contextId'] ||
        lookup.sessionId != _sessionId ||
        lookup.subtitleVersion != _subtitleVersion) {
      throw const VideoRemoteException(409, 'lookup_expired');
    }
    return lookup;
  }

  /// `lookupContext`: the desktop page's "adjust context" draft, kept per
  /// lookup so it dies with the lookup (session / subtitle change, lookupEnd).
  Future<Map<String, Object?>> _lookupContext(
    _RemoteLookup lookup,
    Map<String, dynamic> body,
  ) async {
    final Object? action = body['action'];
    if (action is! String ||
        !videoRemoteLookupContextActions.contains(action)) {
      throw const VideoRemoteException(400, 'invalid_action');
    }
    final MiningSentenceDraft draft = lookup.draft;
    bool? played;
    switch (action) {
      case 'set':
        _setContext(
          lookup,
          math.max(0, _integer(body, 'prev', 0)),
          math.max(0, _integer(body, 'next', 0)),
        );
      case 'edit':
        final Object? text = body['text'];
        if (text is! String ||
            !draft.editSentence(
              slot: _slot(body, allowCurrent: true),
              index: _integer(body, 'index', 0),
              text: text,
            )) {
          throw const VideoRemoteException(400, 'invalid_argument');
        }
      case 'remove':
        final Object? removed = body['removed'];
        if (removed is! bool ||
            !draft.setSentenceRemoved(
              slot: _slot(body, allowCurrent: false),
              index: _integer(body, 'index', 0),
              removed: removed,
            )) {
          throw const VideoRemoteException(400, 'invalid_argument');
        }
      case 'clear':
        draft.clear();
      case 'previewAudio':
        lookup.previewed = true;
        final VideoRemoteMineSelection selection = _selection(lookup);
        final Future<bool> Function(VideoRemoteCue, int, int)? preview =
            lookup.binding.previewAudio;
        try {
          played =
              preview != null &&
              selection.endMs > selection.startMs &&
              await preview(lookup.cue, selection.startMs, selection.endMs);
        } finally {
          _adoptAudition(lookup);
        }
      case 'stopAudio':
        lookup.previewed = true;
        final Future<void> Function()? stop = lookup.binding.stopAudio;
        try {
          if (stop != null) {
            await stop();
          } else {
            await lookup.binding.command('pause', <String, dynamic>{});
          }
        } finally {
          _adoptAudition(lookup);
        }
        played = false;
    }
    return <String, Object?>{
      ...buildSentenceContextPreview(draft: draft, current: lookup.cue.text),
      if (played != null) 'played': played,
    };
  }

  /// The desktop page's "N rows before / after" rule
  /// (`_setSentenceContextToDraft`) over the rows the phone lists: the
  /// anchor's own track in time order, replacing the previous selection.
  void _setContext(_RemoteLookup lookup, int prevCount, int nextCount) {
    final List<VideoRemoteCue> rows = _cues
        .where((VideoRemoteCue cue) => cue.track == lookup.cue.track)
        .toList();
    final int idx = rows.indexWhere(
      (VideoRemoteCue cue) => cue.id == lookup.cue.id,
    );
    if (idx < 0) {
      lookup.draft.setContext();
      return;
    }
    MiningDraftSentence entry(VideoRemoteCue cue) => MiningDraftSentence(
      sentence: cue.text,
      audioRange: AudioPlaybackRange(
        audioFileIndex: 0,
        startMs: cue.startMs,
        endMs: cue.endMs,
      ),
    );
    final int prevStart = math.max(0, idx - prevCount);
    final int nextEnd = math.min(rows.length, idx + 1 + nextCount);
    lookup.draft.setContext(
      prev: <MiningDraftSentence>[
        for (int i = prevStart; i < idx; i++) entry(rows[i]),
      ],
      next: <MiningDraftSentence>[
        for (int i = idx + 1; i < nextEnd; i++) entry(rows[i]),
      ],
    );
  }

  /// Card text and span from the draft, composed like the desktop page's
  /// `_resolveVideoMiningRange`.
  VideoRemoteMineSelection _selection(_RemoteLookup lookup) {
    final VideoRemoteCue cue = lookup.cue;
    final MiningSentenceDraft draft = lookup.draft;
    final AudioPlaybackRange? range = draft.composeAudioRange(
      AudioPlaybackRange(
        audioFileIndex: 0,
        startMs: cue.startMs,
        endMs: cue.endMs,
      ),
    );
    final bool adjusted = !draft.isEmpty || draft.currentSentenceEdit != null;
    final String merged = draft.composeText(cue.text);
    return VideoRemoteMineSelection(
      sentence: adjusted ? merged : cue.text,
      cueSentence: draft.isEmpty ? cue.text : merged,
      startMs: range?.startMs ?? cue.startMs,
      endMs: range?.endMs ?? cue.endMs,
      adjusted: adjusted,
    );
  }

  void _requireLease(String peerId, int leaseGeneration) {
    if (_core.owner != peerId || _core.leaseGeneration != leaseGeneration) {
      throw const VideoRemoteException(409, 'controller_lease_lost');
    }
  }

  bool _matches(FavoriteSentence favorite, VideoRemoteCue cue) =>
      favorite.source == kFavoriteSentenceSourceVideo &&
      favorite.bookKey == _binding?.bookUid() &&
      favorite.text == cue.text &&
      (favorite.sectionIndex == null ||
          favorite.sectionIndex == _binding?.sectionIndex()) &&
      (favorite.normCharOffset == null ||
          favorite.normCharOffset == cue.startMs);

  Future<Map<String, Object?>> _listLibrary(Map<String, dynamic> body) async {
    final VideoRemoteLibrary? library = _library;
    if (library == null) {
      throw const VideoRemoteException(409, videoRemoteActionUnsupported);
    }
    final String query = body['query']?.toString() ?? '';
    final List<VideoRemoteLibraryItem> all = filterByMediaSearch(
      await library.list(),
      query,
      (VideoRemoteLibraryItem item) => <String>[
        item.title,
        if (item.collection != null) item.collection!,
      ],
    );
    final int offset = _integer(body, 'offset', 0).clamp(0, all.length);
    final int limit = _integer(body, 'limit', 100).clamp(1, 200);
    return <String, Object?>{
      'total': all.length,
      'offset': offset,
      'currentBookUid': _binding?.bookUid(),
      // Cover versions only for the page being sent: a stat per row of the
      // whole library on every search keystroke is slow on network drives.
      'items': await Future.wait(
        all
            .skip(offset)
            .take(limit)
            .map(
              (VideoRemoteLibraryItem item) async => item.toJson(
                coverVersion: await videoRemoteCoverVersion(item.coverPath),
              ),
            ),
      ),
    };
  }

  Future<Map<String, Object?>> _listFavorites(Map<String, dynamic> body) async {
    final String query = (body['query']?.toString() ?? '').toLowerCase();
    final List<FavoriteSentence> all = (await _favorites().getAll())
        .where(
          (FavoriteSentence favorite) =>
              favorite.source == kFavoriteSentenceSourceVideo &&
              (body['currentOnly'] != true ||
                  (favorite.bookKey == _binding?.bookUid() &&
                      (favorite.sectionIndex == null ||
                          favorite.sectionIndex ==
                              _binding?.sectionIndex()))) &&
              (query.isEmpty ||
                  favorite.text.toLowerCase().contains(query) ||
                  favorite.bookTitle.toLowerCase().contains(query)),
        )
        .toList();
    final int offset = _integer(body, 'offset', 0).clamp(0, all.length);
    final int limit = _integer(body, 'limit', 200).clamp(1, 200);
    return <String, Object?>{
      'total': all.length,
      'favoriteVersion': _favoriteVersion,
      'items': all
          .skip(offset)
          .take(limit)
          .map(
            (FavoriteSentence favorite) => <String, Object?>{
              'id': favorite.id,
              'text': favorite.text,
              'title': favorite.bookTitle,
              'bookUid': favorite.bookKey,
              'sectionIndex': favorite.sectionIndex,
              'startMs': favorite.normCharOffset,
            },
          )
          .toList(),
    };
  }

  Future<void> _expireLookup(String peerId) async {
    await _favoriteSubscription?.cancel();
    _favoriteSubscription = null;
    final _RemoteLookup? lookup = _lookup;
    if (lookup == null || lookup.peerId != peerId) {
      return;
    }
    _lookup = null;
    await _resume(lookup);
  }

  /// Ends [lookup]: resumes the playback it paused, but only while that pause
  /// is still its own ([_reclaimPause]).
  Future<void> _resume(_RemoteLookup lookup) async {
    if (!await _reclaimPause(lookup) || !lookup.resume) return;
    final VideoRemotePlaybackBinding binding = lookup.binding;
    // An audition was stopped and rewound by [_reclaimPause]; otherwise the
    // desktop must still be paused exactly as the lookup left it.
    if (lookup.previewed || binding.state()['playing'] == false) {
      await binding.command('play', <String, dynamic>{});
      _publish();
    }
  }

  /// Whether the desktop is still the way [lookup] left it: same session and
  /// no local playback intent since (`controlRevision` equals the lookup's
  /// baseline, see [_RemoteLookup.controlRevision]). Anything else (someone at
  /// the desktop dragged, played or paused) belongs to that person and is
  /// left alone. While it is still owned and the phone auditioned audio, the
  /// audition is undone: a still-running one is stopped and the playhead goes
  /// back to where the lookup paused it.
  Future<bool> _reclaimPause(_RemoteLookup lookup) async {
    _refresh();
    if (!identical(lookup.binding, _binding) ||
        lookup.sessionId != _sessionId ||
        lookup.subtitleVersion != _subtitleVersion ||
        lookup.binding.identity() != _identity) {
      return false;
    }
    final VideoRemotePlaybackBinding binding = lookup.binding;
    if (_controlRevision(binding.state()) != lookup.controlRevision) {
      return false;
    }
    if (!lookup.previewed) return true;
    if (binding.state()['playing'] == true) {
      final Future<void> Function()? stop = binding.stopAudio;
      if (stop != null) {
        await stop();
      } else {
        await binding.command('pause', <String, dynamic>{});
      }
    }
    final int? pausedAt = lookup.pausedAtMs;
    if (pausedAt != null) {
      await binding.command('seek', <String, dynamic>{'positionMs': pausedAt});
    }
    _publish();
    return true;
  }

  /// The audition's own seek / play / stop are the lookup's, not a local
  /// intent: move the lookup's baseline past them. The span-end stop that
  /// follows later is automatic and does not move the revision (see
  /// `VideoPlayerController.remoteControlRevision`), so any change after this
  /// point is someone at the desktop.
  void _adoptAudition(_RemoteLookup lookup) {
    lookup.controlRevision = _controlRevision(lookup.binding.state());
  }

  Future<void> dispose() async {
    await releaseController();
    _binding?.removeListener(_changed);
    _binding = null;
    _core.dispose();
  }

  /// Hosting can be stopped and restarted while the local player stays open.
  Future<void> releaseController() async {
    final String? owner = _core.owner;
    if (owner == null) {
      return;
    }
    await _expireLookup(owner);
    _core.release(owner);
  }
}

SentenceContextSlot _slot(
  Map<String, dynamic> body, {
  required bool allowCurrent,
}) {
  switch (body['slot']) {
    case 'prev':
      return SentenceContextSlot.prev;
    case 'next':
      return SentenceContextSlot.next;
    case 'current' when allowCurrent:
      return SentenceContextSlot.current;
  }
  throw const VideoRemoteException(400, 'invalid_argument');
}

int _controlRevision(Map<String, Object?> state) =>
    (state['controlRevision'] as num?)?.toInt() ?? 0;

int _integer(Map<String, dynamic> body, String key, int fallback) {
  final Object? value = body[key];
  if (value == null) {
    return fallback;
  }
  if (value is! int) {
    throw const VideoRemoteException(400, 'invalid_number');
  }
  return value;
}

Object? _canonical(Object? value) {
  if (value is Map<String, dynamic>) {
    final List<String> keys = value.keys.toList()..sort();
    return <String, Object?>{
      for (final String key in keys) key: _canonical(value[key]),
    };
  }
  if (value is List) {
    return value.map(_canonical).toList();
  }
  return value;
}

String _fingerprint(String operation, Map<String, dynamic> body) => sha256
    .convert(utf8.encode(jsonEncode(<Object?>[operation, _canonical(body)])))
    .toString();

final class _RemoteLookup {
  _RemoteLookup(
    this.id,
    this.peerId,
    this.sessionId,
    this.subtitleVersion,
    this.binding,
    this.cue,
    this.resume,
    this.controlRevision,
    this.pausedAtMs,
  );
  final String id, peerId, sessionId;
  final int subtitleVersion;
  final VideoRemotePlaybackBinding binding;
  final VideoRemoteCue cue;
  final bool resume;

  /// The desktop's `controlRevision` as this lookup last left it: right after
  /// its own pause, then after each audition action
  /// ([VideoRemoteHost._adoptAudition]). A different revision at close means a
  /// local playback intent, which cancels both resuming and the post-audition
  /// restore.
  int controlRevision;

  /// Desktop playhead before the lookup chain paused it (null if the binding
  /// reports none). A handed-over lookup keeps its predecessor's value.
  final int? pausedAtMs;

  /// Set once the phone auditions audio (`previewAudio` / `stopAudio`). Those
  /// seeks and plays move the playhead, so closing puts back the pre-lookup
  /// playhead ([VideoRemoteHost._reclaimPause]) instead of leaving it at the
  /// span end.
  bool previewed = false;

  /// This lookup's sentence-context draft (`lookupContext`).
  final MiningSentenceDraft draft = MiningSentenceDraft();
}

final class _RemoteMineTask {
  _RemoteMineTask(this.id, this.peerId, this.requestId, this.fingerprint);
  final String id, peerId, requestId, fingerprint;
  String status = 'running';
  Map<String, Object?>? result;
  String? error;
  Map<String, Object?> toJson() => <String, Object?>{
    'taskId': id,
    'status': status,
    if (result != null) 'result': result,
    if (error != null) 'error': error,
  };
}
