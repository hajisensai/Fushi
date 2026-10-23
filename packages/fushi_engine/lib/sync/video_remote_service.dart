/// Application-owned video player adapter. The engine has no player dependency.
abstract interface class VideoRemoteService {
  Future<Map<String, Object?>> handle(
    String operation,
    Map<String, dynamic> body,
    String peerId,
  );
}

final class VideoRemoteException implements Exception {
  const VideoRemoteException(this.status, this.code);

  final int status;
  final String code;

  @override
  String toString() => 'VideoRemoteException($status, $code)';
}

/// Error code returned (HTTP 500) when the adapter fails with an unexpected
/// exception. Expected failures carry their own [VideoRemoteException.code].
const String videoRemoteInternalError = 'internal_error';

const Set<String> videoRemoteOperations = <String>{
  'snapshot',
  'events',
  'subtitles',
  'command',
  // `{sessionId, subtitleVersion, cueId, requestId, replaceContextId?}`.
  // `replaceContextId` names the open lookup this one replaces (the phone
  // switched rows with the dialog open): the host hands that lookup's pause
  // over instead of resuming and pausing again. Hosts that predate the field
  // ignore it and end the open lookup first, which is the old behaviour.
  'lookupBegin',
  'lookupEnd',
  // Sentence context of the open lookup (the desktop video page's "adjust
  // context" draft): body `{contextId, requestId, action, ...}`, see
  // [videoRemoteLookupContextActions].
  'lookupContext',
  'mine',
  'mineStatus',
  'favorites',
  'favoriteSet',
  'favoritesRemove',
  'openFavorite',
  // Read-only lists behind the episode / subtitle-track pickers:
  // `{sessionId, subtitleVersion}` -> `{episodes: [{index, title,
  // current}], subtitleTracks: [{id, label, kind, selected, selectable}],
  // subtitleOff: bool}`. Only hosts that advertise
  // [videoRemoteCapabilityEpisodes] / [videoRemoteCapabilitySubtitleTracks]
  // answer it; older hosts reject the path as an unknown operation.
  'playbackOptions',
  // On-demand playback ([videoRemoteCapabilityOpenVideo]): pick a video from
  // the computer's library on the phone and have the computer play it, with
  // or without a video page already open.
  //
  // * `library` — `{query?, offset?, limit?}` -> `{total, offset, items:
  //   [{bookUid, title, collection?, positionMs, lastPlayedAt?,
  //   coverVersion?}], currentBookUid}`. Read only; `query` filters by title
  //   / collection. `coverVersion` (cover file mtime) is present only when
  //   the video has a cover, served by the interconnect library's
  //   `GET /api/library/videos/<bookUid>/cover`.
  // * `openVideo` — `{bookUid, requestId}`: closes the open video page (its
  //   normal exit, position saved) and opens [bookUid]. Answers before the
  //   new page is playing; its session reaches the phone through the state
  //   journal. Errors: `404 video_missing`, `409 host_busy` (the computer is
  //   showing something that cannot be closed from the phone, e.g. a dialog).
  'library',
  'openVideo',
  // Online subtitle search for the playing video
  // ([videoRemoteCapabilitySubtitleSearch]), read only:
  // `{sessionId, subtitleVersion, query?, episode?}` -> `{query, episode?,
  // candidates: [{id, fileName, provider, language?, episode?, aiTranslated,
  // hearingImpaired}]}`. Without `query` the computer searches with what it
  // derives from the video (title / scraped identity, episode) and reports it
  // back so the phone can prefill. `id` is opaque and only valid until the
  // next search; the `subtitleDownload` command fetches and applies one.
  // Errors: `409 subtitle_source_missing` (no source configured),
  // `502 subtitle_search_failed` (no result and a source failed).
  'subtitleSearch',
  'disconnect',
};

/// Actions of the `command` operation (body `{sessionId, subtitleVersion,
/// requestId, action, ...}`).
///
/// * `play` / `pause`.
/// * `seek` — `{positionMs: int}`; `seekCue` — `{cueId}`.
/// * `volume` — `{volume: int 0..100}` ([videoRemoteCapabilityVolume]).
/// * `episode` — `{episodeIndex: int}` ([videoRemoteCapabilityEpisodes]).
/// * `subtitleTrack` — `{trackId: String?}`, null turns the primary subtitle
///   off ([videoRemoteCapabilitySubtitleTracks]).
/// * `subtitleDownload` — `{candidateId}` from the last `subtitleSearch`:
///   the computer downloads it into its subtitle folder and applies it as
///   the primary subtitle ([videoRemoteCapabilitySubtitleSearch]). Errors:
///   `404 subtitle_candidate_missing`, `502 subtitle_download_failed`.
/// * `caret` — `{caret: String}` from [videoRemoteCaretActions]: drives the
///   computer's own subtitle word cursor (the keyboard / gamepad one) so the
///   lookup card opens on the computer screen ([videoRemoteCapabilityCaret]).
///   Answers `{ok, caret}` with the cursor's surface afterwards (see
///   [videoRemoteCaretSurfaces]); the snapshot carries the same `caret`.
///
/// The last five are newer than the protocol itself: a host that predates
/// them answers `400 invalid_action`, a host whose player cannot do one
/// answers `409 action_unsupported`. Phones only offer an action when the
/// snapshot's `capabilities` list names it, so neither reaches a user.
const Set<String> videoRemoteCommandActions = <String>{
  'play',
  'pause',
  'seek',
  'seekCue',
  'volume',
  'episode',
  'subtitleTrack',
  'subtitleDownload',
  'caret',
};

/// Steps of the `caret` command. The computer routes each by where its cursor
/// is: on the subtitle `enter` starts it (pausing playback) on the first
/// visible character, `left` / `right` step one character back / forward in
/// reading order, `up` / `down` move a line, `activate` looks the character
/// up (the card opens and the cursor moves into it); inside the card the same
/// steps move through it, `activate` presses what the cursor is on (the ＋
/// button mines) and `longPress` is the card's long press. `back` closes the
/// top card, or leaves the cursor (resuming playback it paused).
const Set<String> videoRemoteCaretActions = <String>{
  'enter',
  'left',
  'right',
  'up',
  'down',
  'activate',
  'longPress',
  'back',
};

/// Where the computer's word cursor is (`caret` in the snapshot and in the
/// `caret` command's answer): `none` (off), `video` (on the subtitle) or
/// `popup` (inside a lookup card).
const Set<String> videoRemoteCaretSurfaces = <String>{'none', 'video', 'popup'};

/// Snapshot `capabilities` entries: optional controls this host's player
/// supports. A snapshot without the list (older hosts) supports none of them.
const String videoRemoteCapabilityVolume = 'volume';
const String videoRemoteCapabilityEpisodes = 'episodes';
const String videoRemoteCapabilitySubtitleTracks = 'subtitleTracks';
const String videoRemoteCapabilitySubtitleSearch = 'subtitleSearch';
const String videoRemoteCapabilityCaret = 'caret';

/// Host-level capability (present with or without an open video): the host
/// answers `library` / `openVideo`.
const String videoRemoteCapabilityOpenVideo = 'openVideo';

/// Error code for a known action the current player cannot perform.
const String videoRemoteActionUnsupported = 'action_unsupported';

/// Actions of the `lookupContext` operation. Every action answers with the
/// draft preview (`{prev, current, currentOffset, next, prevRemoved,
/// nextRemoved, total}`, the same map the desktop dialog renders); the audio
/// actions add `played`.
///
/// * `preview` — read only.
/// * `set` — `{prev: int, next: int}`: replace the context with the N rows
///   before / after the looked-up row on its own subtitle track.
/// * `edit` — `{slot: 'prev'|'current'|'next', index: int, text: String}`.
/// * `remove` — `{slot: 'prev'|'next', index: int, removed: bool}`.
/// * `clear` — drop the context and every edit.
/// * `previewAudio` / `stopAudio` — play / stop the span the card would get,
///   on the desktop player (the phone has no video audio).
const Set<String> videoRemoteLookupContextActions = <String>{
  'preview',
  'set',
  'edit',
  'remove',
  'clear',
  'previewAudio',
  'stopAudio',
};
