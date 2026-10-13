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
  'disconnect',
};

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
