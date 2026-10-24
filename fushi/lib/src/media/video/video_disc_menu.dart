import 'dart:convert';

/// Which navigation library produced a `disc-navigation-state` snapshot.
enum VideoDiscType { bluray, dvd }

/// DVD-Video VM domain (libdvdnav): first play, video manager menu (the disc's
/// title menu), title set menu (root / chapter / audio ... menus) and title.
enum VideoDvdDomain { firstPlay, videoManagerMenu, titleSetMenu, title }

const Map<String, VideoDvdDomain> _dvdDomains = <String, VideoDvdDomain>{
  'FP': VideoDvdDomain.firstPlay,
  'VMGM': VideoDvdDomain.videoManagerMenu,
  'VTSM': VideoDvdDomain.titleSetMenu,
  'VTS': VideoDvdDomain.title,
};

/// The focused DVD button: its rectangle in source pixels (the space of
/// `src-width` / `src-height`, e.g. 720x480) and the four select-state colours
/// libdvdnav resolved from the SPU CLUT, each 0xAARRGGBB.
class VideoDvdHighlight {
  const VideoDvdHighlight({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.palette,
  });

  final int x0;
  final int y0;
  final int x1;
  final int y1;
  final List<int> palette;

  int get width => x1 - x0;
  int get height => y1 - y0;

  static VideoDvdHighlight? _parse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final Object? x0 = value['x0'];
    final Object? y0 = value['y0'];
    final Object? x1 = value['x1'];
    final Object? y1 = value['y1'];
    final Object? palette = value['palette'];
    if (x0 is! int ||
        y0 is! int ||
        x1 is! int ||
        y1 is! int ||
        x0 < 0 ||
        y0 < 0 ||
        x1 <= x0 ||
        y1 <= y0 ||
        palette is! List<dynamic> ||
        palette.length != 4 ||
        palette.any(
          (Object? colour) =>
              colour is! int || colour < 0 || colour > 0xFFFFFFFF,
        )) {
      return null;
    }
    return VideoDvdHighlight(
      x0: x0,
      y0: y0,
      x1: x1,
      y1: y1,
      palette: List<int>.unmodifiable(palette.cast<int>()),
    );
  }
}

/// The `dvd-state` branch of a v2 snapshot: where the DVD VM is, whether it is
/// holding a still, and the live button highlight.
class VideoDvdNavigationState {
  const VideoDvdNavigationState({
    required this.domain,
    required this.titleSet,
    required this.title,
    required this.part,
    required this.programChain,
    required this.program,
    required this.cell,
    required this.still,
    required this.button,
    required this.buttonCount,
    required this.titleMenuAllowed,
    required this.rootMenuAllowed,
    required this.highlight,
  });

  final VideoDvdDomain domain;

  /// VTS number; 0 before the VM entered any title set.
  final int titleSet;

  /// Global title number (1-99) inside [VideoDvdDomain.title]; 0 in menus.
  final int title;

  /// Chapter (PTT) of [title]; 0 in menus.
  final int part;
  final int programChain;
  final int program;
  final int cell;

  /// An indefinite still (menu background or still-frame title) is on screen.
  final bool still;

  /// Focused button, 0 when no highlight is live.
  final int button;
  final int buttonCount;

  /// The disc's user-operation mask allows `title-menu` (DVD_MENU_Title).
  final bool titleMenuAllowed;

  /// The disc's user-operation mask allows `menu` (DVD_MENU_Root).
  final bool rootMenuAllowed;
  final VideoDvdHighlight? highlight;

  bool get inMenu => domain != VideoDvdDomain.title;

  static VideoDvdNavigationState? _parse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final VideoDvdDomain? domain = _dvdDomains[value['domain']];
    final Object? vts = value['vts'];
    final Object? title = value['title'];
    final Object? part = value['part'];
    final Object? pgc = value['pgc'];
    final Object? pg = value['pg'];
    final Object? cell = value['cell'];
    final Object? still = value['still'];
    final Object? button = value['button'];
    final Object? buttonCount = value['button-count'];
    final Object? titleMenu = value['title-menu-allowed'];
    final Object? rootMenu = value['root-menu-allowed'];
    final Object? highlightValue = value['highlight'];
    if (domain == null ||
        vts is! int ||
        vts < 0 ||
        vts > 99 ||
        title is! int ||
        title < 0 ||
        title > 99 ||
        // A title number only exists in the title domain.
        (title > 0) != (domain == VideoDvdDomain.title) ||
        part is! int ||
        part < 0 ||
        part > 999 ||
        pgc is! int ||
        pgc < 0 ||
        pg is! int ||
        pg < 0 ||
        cell is! int ||
        cell < 0 ||
        still is! bool ||
        button is! int ||
        buttonCount is! int ||
        buttonCount < 0 ||
        buttonCount > 36 ||
        button < 0 ||
        button > buttonCount ||
        titleMenu is! bool ||
        rootMenu is! bool) {
      return null;
    }
    final VideoDvdHighlight? highlight = VideoDvdHighlight._parse(
      highlightValue,
    );
    // A focused button always carries its rectangle and palette; a highlight
    // without a focused button is a malformed snapshot.
    if ((button > 0) != (highlight != null) ||
        (highlightValue != null && highlight == null)) {
      return null;
    }
    return VideoDvdNavigationState(
      domain: domain,
      titleSet: vts,
      title: title,
      part: part,
      programChain: pgc,
      program: pg,
      cell: cell,
      still: still,
      button: button,
      buttonCount: buttonCount,
      titleMenuAllowed: titleMenu,
      rootMenuAllowed: rootMenu,
      highlight: highlight,
    );
  }
}

/// One atomic native snapshot. Blu-ray playlist numbers come from libbluray
/// itself, never from mpv's edition index (which also includes a synthetic
/// menu entry); a DVD title comes from the libdvdnav VM (v2 `dvd-state`).
///
/// Wire versions: v1 is Blu-ray only; v2 adds `disc-type` and the `dvd-state`
/// branch while keeping every v1 field. Both are accepted, so a v1 runtime
/// still drives Blu-ray menus.
class VideoDiscNavigationState {
  const VideoDiscNavigationState({
    this.discType = VideoDiscType.bluray,
    this.dvd,
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

  final VideoDiscType discType;

  /// The DVD branch; non-null exactly when [discType] is [VideoDiscType.dvd].
  final VideoDvdNavigationState? dvd;
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
      switch (discType) {
        VideoDiscType.bluray =>
          playlist != null &&
              title > 0 &&
              title < 65535 &&
              (!bdjDetected || bdjHandled),
        VideoDiscType.dvd =>
          dvd != null &&
              dvd!.domain == VideoDvdDomain.title &&
              title > 0 &&
              title == dvd!.title,
      };
  bool get allowsStudy => isTitle && !menuActive;

  /// Blu-ray only: the MPLS file of the confirmed title.
  String? get playlistFileName => isTitle && discType == VideoDiscType.bluray
      ? '${playlist.toString().padLeft(5, '0')}.mpls'
      : null;

  /// DVD only: the confirmed title number (1-99). Together with the disc
  /// identity (libdvdread DVDDiscID + volume label) it is the library key, the
  /// DVD counterpart of a disc root + MPLS.
  int? get dvdTitleNumber =>
      isTitle && discType == VideoDiscType.dvd ? dvd!.title : null;

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
    final VideoDiscType? discType = switch (decoded['version']) {
      1 => VideoDiscType.bluray,
      2 => switch (decoded['disc-type']) {
        'bluray' => VideoDiscType.bluray,
        'dvd' => VideoDiscType.dvd,
        _ => null,
      },
      _ => null,
    };
    final VideoDvdNavigationState? dvd = discType == VideoDiscType.dvd
        ? VideoDvdNavigationState._parse(decoded['dvd-state'])
        : null;
    if (discType == null ||
        (discType == VideoDiscType.dvd) != (dvd != null) ||
        (discType == VideoDiscType.dvd &&
            (playlist != -1 || title != dvd!.title)) ||
        active is! bool ||
        menu is! bool ||
        domain is! bool ||
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
      discType: discType,
      dvd: dvd,
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
    confirmed.discType == expected.discType &&
    confirmed.playlist == expected.playlist &&
    confirmed.title == expected.title &&
    confirmed.dvd?.programChain == expected.dvd?.programChain &&
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
///
/// Only clicks reach the disc. mpv's `mouse-move` is `bd_mouse_select`, which
/// libbluray treats as *selecting* the button under the pointer — and authored
/// auto-action buttons run their navigation commands on selection. Sweeping the
/// mouse off an expanded submenu therefore re-selected a tab/parent button and
/// collapsed the menu. Hover is not part of a remote-driven disc menu.
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
    'mouse-click',
  };
  if (!actions.contains(action)) {
    throw ArgumentError.value(action, 'action', 'Unknown Blu-ray menu action');
  }
  if (action != 'mouse-click') return <String>['discnav', action];
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

/// Remote-control keys of a disc menu, independent of the disc type.
enum VideoDiscMenuKey {
  up,
  down,
  left,
  right,
  select,

  /// Back / Return: BD toggles the popup, DVD resumes the title it left (or
  /// opens the root menu when there is nothing to resume).
  back,

  /// BD Top Menu; DVD root menu of the current title set (`DVD_MENU_Root`).
  topMenu,

  /// DVD title menu of the video manager (`DVD_MENU_Title`); libbluray has no
  /// separate title menu and treats it as Top Menu.
  titleMenu,

  /// BD popup menu; DVD chapter (Part) menu (`DVD_MENU_Part`).
  popupMenu,
}

/// The `discnav` action each key sends to mpv. mpv shares one `discnav`
/// command between libbluray and libdvdnav; what each action does per disc
/// type (patch `disc-navigation-state`, snapshot v2 for DVD):
///
/// | key       | action      | Blu-ray (libbluray)         | DVD (libdvdnav)                  |
/// |-----------|-------------|-----------------------------|----------------------------------|
/// | arrows    | up/down/... | `bd_user_input` VK_UP/...   | `dvdnav_button_select` neighbour |
/// | select    | select      | VK_ENTER                    | `dvdnav_button_activate`         |
/// | back      | prev        | VK_POPUP                    | `DVD_MENU_Escape` (resume/root)  |
/// | topMenu   | menu        | `bd_menu_call` top menu     | `DVD_MENU_Root` (VTSM)           |
/// | titleMenu | title-menu  | `bd_menu_call` top menu     | `DVD_MENU_Title` (VMGM)          |
/// | popupMenu | popup       | VK_POPUP                    | `DVD_MENU_Part` (chapter menu)   |
/// | pointer   | mouse-click | `bd_mouse_select` + ACTIVATE| `dvdnav_mouse_activate`          |
///
/// Both native sides report an unconsumed key or a refused menu call (the
/// disc's user-operation mask, or no such menu) as a failed command.
const Map<VideoDiscType, Map<VideoDiscMenuKey, String>>
videoDiscMenuKeyActions = <VideoDiscType, Map<VideoDiscMenuKey, String>>{
  VideoDiscType.bluray: <VideoDiscMenuKey, String>{
    VideoDiscMenuKey.up: 'up',
    VideoDiscMenuKey.down: 'down',
    VideoDiscMenuKey.left: 'left',
    VideoDiscMenuKey.right: 'right',
    VideoDiscMenuKey.select: 'select',
    VideoDiscMenuKey.back: 'prev',
    VideoDiscMenuKey.topMenu: 'menu',
    VideoDiscMenuKey.titleMenu: 'title-menu',
    VideoDiscMenuKey.popupMenu: 'popup',
  },
  VideoDiscType.dvd: <VideoDiscMenuKey, String>{
    VideoDiscMenuKey.up: 'up',
    VideoDiscMenuKey.down: 'down',
    VideoDiscMenuKey.left: 'left',
    VideoDiscMenuKey.right: 'right',
    VideoDiscMenuKey.select: 'select',
    VideoDiscMenuKey.back: 'prev',
    VideoDiscMenuKey.topMenu: 'menu',
    VideoDiscMenuKey.titleMenu: 'title-menu',
    VideoDiscMenuKey.popupMenu: 'popup',
  },
};

/// The remote key a Blu-ray `discnav` action string stands for (the vocabulary
/// the menu UI and its key bindings were written in); null for pointer and
/// unknown actions. The session then sends it through the table of its own
/// disc type ([videoDiscMenuKeyCommand]).
VideoDiscMenuKey? videoDiscMenuKeyForAction(String action) {
  for (final MapEntry<VideoDiscMenuKey, String> entry
      in videoDiscMenuKeyActions[VideoDiscType.bluray]!.entries) {
    if (entry.value == action) return entry.key;
  }
  return null;
}

/// The mpv command for [key] on a disc of [type].
List<String> videoDiscMenuKeyCommand(
  VideoDiscType type,
  VideoDiscMenuKey key,
) => videoDiscNavigationCommand(videoDiscMenuKeyActions[type]![key]!);

/// Whether the disc's own rules currently allow the menu call [key] makes.
/// Blu-ray exposes one UO_MENU_CALL bit; DVD has separate title / root UOPs.
/// Other keys are always offered: the disc decides whether it consumes them.
bool videoDiscMenuKeyAllowed(
  VideoDiscNavigationState state,
  VideoDiscMenuKey key,
) {
  final VideoDvdNavigationState? dvd = state.dvd;
  return switch (key) {
    VideoDiscMenuKey.topMenu =>
      dvd != null ? dvd.rootMenuAllowed : state.menuCallAllowed,
    VideoDiscMenuKey.titleMenu =>
      dvd != null ? dvd.titleMenuAllowed : state.menuCallAllowed,
    _ => true,
  };
}

/// Whether an mpv log line means a disc that never opened.
///
/// libbluray reports its real reason (AACS, BD+, unreadable index) only under
/// the `bd` prefix, and mpv's DVD stream reports "Couldn't open DVD device"
/// under `dvdnav`; mpv then adds the generic `stream` "No protocol handler"
/// line and stays idle without a navigation snapshot.
bool isVideoDiscOpenFailureLog({
  required String prefix,
  required String level,
}) =>
    level.trim() == 'error' &&
    const <String>{'bd', 'dvdnav', 'stream'}.contains(prefix.trim());

class VideoDiscMenuException implements Exception {
  const VideoDiscMenuException(this.code);
  final String code;

  @override
  String toString() => 'Blu-ray menu: $code';
}

/// Whether [command] forwards a remote-control key or click to the disc.
///
/// For these, libbluray's negative answer means the disc did not consume the
/// input, not that a command failed: `bd_user_input` / `bd_mouse_select` return
/// -1 when a popup-model menu is closed, a click lands outside every enabled
/// button (a tab button that is not selectable while another tab's submenu is
/// expanded), a button animation is running, or a BD-J Xlet's listener returned
/// false for the key (graphics_controller.c `_user_input` / `_mouse_move`,
/// bdj.c `bdj_process_event`). A hardware player does nothing in that case,
/// and the shipped `fushi-discnav1` patch propagates it as mpv's generic
/// MPV_ERROR_COMMAND (-12). Only `menu` / `title-menu` (`bd_menu_call`, refused
/// by the disc's UO mask) are commands that can genuinely be rejected.
bool isVideoDiscInputCommand(List<String> command) =>
    command.length >= 2 &&
    command.first == 'discnav' &&
    const <String>{
      'up',
      'down',
      'left',
      'right',
      'select',
      'popup',
      'prev',
      'mouse-click',
    }.contains(command[1]);

/// Sends a disc input (see [isVideoDiscInputCommand]) and reports whether the
/// disc consumed it. An unconsumed key is a normal remote-control outcome, so it
/// is a `false` result rather than a [VideoDiscMenuException].
Future<bool> runVideoDiscInputCommand(dynamic native, List<String> command) {
  // Checked synchronously: a non-input command is a programming error, not a
  // native outcome.
  if (!isVideoDiscInputCommand(command)) {
    throw ArgumentError.value(command, 'command', 'Not a disc input');
  }
  return _runVideoDiscCommand(
    native,
    command,
  ).then((int result) => result >= 0);
}

/// media_kit's public command() logs negative mpv results but completes normally.
/// Disc actions need the actual result so a rejected menu never looks successful.
/// The caller must await native initialization and check its load token first.
Future<void> runCheckedVideoDiscCommand(
  dynamic native,
  List<String> command,
) async {
  final int result = await _runVideoDiscCommand(native, command);
  if (result < 0) throw VideoDiscMenuException('command-failed:$result');
}

/// BUG-3507: goes through the media_kit patch's `commandWithResult`
/// (`mpv_command_async`). A synchronous `mpv_command` waits for the mpv core
/// lock on the UI thread and freezes video composition while the core is busy.
/// mpv runs a client's async requests in order, so commands issued one after
/// another keep their order against media_kit's own commands and writes.
Future<int> _runVideoDiscCommand(dynamic native, List<String> command) async {
  final Object? result = await native.commandWithResult(command);
  return result is int ? result : -1;
}
