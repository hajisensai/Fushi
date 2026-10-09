import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// One atomic libbluray snapshot. Playlist numbers come from libbluray itself,
/// never from mpv's edition index (which also includes a synthetic menu entry).
class VideoDiscNavigationState {
  const VideoDiscNavigationState({
    required this.navigationActive,
    required this.menuActive,
    required this.menuDomain,
    required this.title,
    required this.playlist,
    required this.positionSeconds,
    required this.generation,
    required this.stable,
    required this.bdjDetected,
    required this.bdjHandled,
    required this.angle,
    required this.menuCallAllowed,
  });

  final bool navigationActive;
  final bool menuActive;
  final bool menuDomain;
  final int title;
  final int? playlist;
  final double positionSeconds;
  final int generation;
  final bool stable;
  final bool bdjDetected;
  final bool bdjHandled;

  /// libbluray angle, zero-based; -1 means no authoritative value yet.
  final int angle;
  final bool menuCallAllowed;

  bool get isTitle =>
      navigationActive &&
      stable &&
      positionSeconds.isFinite &&
      positionSeconds >= 0 &&
      !menuDomain &&
      playlist != null &&
      title > 0 &&
      title < 65535 &&
      (!bdjDetected || bdjHandled);
  bool get allowsStudy => isTitle && !menuActive;

  String? get playlistFileName =>
      isTitle ? '${playlist.toString().padLeft(5, '0')}.mpls' : null;

  static VideoDiscNavigationState? parse(String value) {
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final Object? active = decoded['nav-active'];
    final Object? menu = decoded['menu-active'];
    final Object? domain = decoded['menu-domain'];
    final Object? title = decoded['title'];
    final Object? playlist = decoded['playlist'];
    final Object? position = decoded['position'];
    final Object? generation = decoded['generation'];
    final Object? stable = decoded['stable'];
    final Object? bdjDetected = decoded['bdj-detected'];
    final Object? bdjHandled = decoded['bdj-handled'];
    final Object? angle = decoded['angle'];
    final Object? menuCallAllowed = decoded['menu-call-allowed'];
    if (active is! bool ||
        menu is! bool ||
        domain is! bool ||
        decoded['version'] != 1 ||
        generation is! int ||
        generation < 0 ||
        stable is! bool ||
        bdjDetected is! bool ||
        bdjHandled is! bool ||
        angle is! int ||
        angle < -1 ||
        menuCallAllowed is! bool ||
        title is! int ||
        playlist is! int ||
        position is! num ||
        !position.isFinite ||
        (stable && position < 0) ||
        playlist < -1 ||
        playlist > 99999) {
      return null;
    }
    return VideoDiscNavigationState(
      navigationActive: active,
      menuActive: menu,
      menuDomain: domain,
      title: title,
      playlist: playlist < 0 ? null : playlist,
      positionSeconds: position.toDouble(),
      generation: generation,
      stable: stable,
      bdjDetected: bdjDetected,
      bdjHandled: bdjHandled,
      angle: angle,
      menuCallAllowed: menuCallAllowed,
    );
  }
}

enum VideoDiscMenuEntryAction { wait, requestTopMenu, complete }

enum VideoDiscTrackOwner { disc, fushi }

/// current-tracks/*/id contains a resolved user_tid, unlike sid/aid whose value
/// can legitimately remain "auto". Unavailable means no selected track only
/// after a stable native title snapshot has established a loaded demuxer.
String? resolvedVideoDiscTrackId(String raw, {required bool stable}) {
  if (!stable) return null;
  final String value = raw.trim();
  if (value.isEmpty) return 'no';
  final int? id = int.tryParse(value);
  return id != null && id > 0 ? id.toString() : null;
}

/// Convert the resolved physical user_tid to the type-relative extraction index.
/// A logical auto/no value, missing ID or unknown physical track never means 0.
int? videoDiscResolvedTrackOrdinal(String? id, Iterable<String> trackIds) {
  if (id == null || id == 'auto' || id == 'no') return null;
  final List<String> physical = trackIds
      .where((String item) => item != 'auto' && item != 'no')
      .toList(growable: false);
  final int index = physical.indexOf(id);
  return index < 0 ? null : index;
}

class VideoDiscResolvedTracks {
  VideoDiscResolvedTracks.fromMpv({
    required String audioId,
    required String subtitleId,
    required String subtitleCodec,
    required bool stable,
  }) : audioId = resolvedVideoDiscTrackId(audioId, stable: stable),
       subtitleId = resolvedVideoDiscTrackId(subtitleId, stable: stable),
       subtitleCodec = stable && subtitleCodec.trim().isNotEmpty
           ? subtitleCodec.trim()
           : null;

  final String? audioId;
  final String? subtitleId;
  final String? subtitleCodec;
}

bool videoDiscTitleIdentityMatches(
  VideoDiscNavigationState expected,
  VideoDiscNavigationState? confirmed,
) =>
    confirmed != null &&
    confirmed.isTitle &&
    expected.isTitle &&
    confirmed.generation == expected.generation &&
    confirmed.playlist == expected.playlist &&
    confirmed.title == expected.title &&
    confirmed.angle == expected.angle;

/// Ownership changes on an actual interactive-menu entrance, not on every
/// title bind or a background-only menu frame. This also covers same-MPLS menus.
bool shouldReturnDiscTrackOwnership({
  required VideoDiscTrackOwner owner,
  required VideoDiscNavigationState? previous,
  required VideoDiscNavigationState next,
}) =>
    owner == VideoDiscTrackOwner.fushi &&
    next.menuActive &&
    next.menuDomain &&
    !(previous?.menuActive == true && previous?.menuDomain == true);

/// Entering a disc menu is an intent, not merely opening its first-play movie.
/// Respect authored UOPs and wait for their state to allow a single menu call.
VideoDiscMenuEntryAction videoDiscMenuEntryAction(
  VideoDiscNavigationState state, {
  required bool requested,
}) {
  if (!state.navigationActive || (state.bdjDetected && !state.bdjHandled)) {
    return VideoDiscMenuEntryAction.wait;
  }
  // A pure Java top menu can render IG without ever starting a playlist or
  // presenting a video timestamp. That is sufficient for menu interaction,
  // but never for isTitle, study, or extraction. A playlist-backed HDMV menu
  // still needs the existing presentation-stability proof.
  if (state.title == 0 &&
      state.menuDomain &&
      state.menuActive &&
      (state.stable || state.playlist == null)) {
    return VideoDiscMenuEntryAction.complete;
  }
  if (!state.stable) return VideoDiscMenuEntryAction.wait;
  if (!requested && state.menuCallAllowed) {
    return VideoDiscMenuEntryAction.requestTopMenu;
  }
  return VideoDiscMenuEntryAction.wait;
}

/// mpv accepts pointer coordinates in the video's normalized content rectangle.
/// Reject outside/invalid input rather than selecting an unrelated edge button.
List<String> videoDiscNavigationCommand(String action, {double? x, double? y}) {
  const Set<String> actions = <String>{
    'up',
    'down',
    'left',
    'right',
    'select',
    'menu',
    'title-menu',
    'popup',
    'prev',
    'mouse-move',
    'mouse-click',
  };
  if (!actions.contains(action)) {
    throw ArgumentError.value(action, 'action', 'Unknown Blu-ray menu action');
  }
  final bool pointer = action == 'mouse-move' || action == 'mouse-click';
  if (!pointer) return <String>['discnav', action];
  if (x == null ||
      y == null ||
      !x.isFinite ||
      !y.isFinite ||
      x < 0 ||
      x > 1 ||
      y < 0 ||
      y > 1) {
    throw ArgumentError('Disc pointer must be inside the video rectangle');
  }
  return <String>['discnav', action, x.toString(), y.toString()];
}

/// Whether an mpv log line means a disc that never opened.
///
/// libbluray reports its real reason (AACS, BD+, unreadable index) only under
/// the `bd` prefix; mpv then adds the generic `stream` "No protocol handler"
/// line and stays idle without a navigation snapshot.
bool isVideoDiscOpenFailureLog({
  required String prefix,
  required String level,
}) =>
    level.trim() == 'error' &&
    const <String>{'bd', 'stream'}.contains(prefix.trim());

class VideoDiscMenuException implements Exception {
  const VideoDiscMenuException(this.code);
  final String code;

  @override
  String toString() => 'Blu-ray menu: $code';
}

/// media_kit's public command() logs negative mpv results but completes normally.
/// Disc actions need the actual result so a rejected menu never looks successful.
/// The caller must await native initialization and check its load token first.
void runCheckedVideoDiscCommand(dynamic native, List<String> command) {
  final List<Pointer<Utf8>> strings = command
      .map((String argument) => argument.toNativeUtf8())
      .toList(growable: false);
  final Pointer<Pointer<Char>> arguments = calloc<Pointer<Char>>(
    strings.length + 1,
  );
  try {
    for (int i = 0; i < strings.length; i++) {
      arguments[i] = strings[i].cast<Char>();
    }
    final int result = native.mpv.mpv_command(native.ctx, arguments) as int;
    if (result < 0) throw VideoDiscMenuException('command-failed:$result');
  } finally {
    calloc.free(arguments);
    for (final Pointer<Utf8> string in strings) {
      calloc.free(string);
    }
  }
}
