import 'dart:convert';

enum VideoControlButton {
  speed('speed'),
  subtitleList('subtitleList'),
  favoriteSentence('favoriteSentence'),
  favoriteSentences('favoriteSentences'),
  settings('settings');

  const VideoControlButton(this.storageValue);

  final String storageValue;

  static VideoControlButton? fromStorage(String value) {
    for (final VideoControlButton button in values) {
      if (button.storageValue == value) return button;
    }
    return null;
  }
}

enum VideoControlPlacement {
  bottom('bottom'),
  rightRail('rightRail'),
  settingsOnly('settingsOnly');

  const VideoControlPlacement(this.storageValue);

  final String storageValue;

  static VideoControlPlacement? fromStorage(String value) {
    for (final VideoControlPlacement placement in values) {
      if (placement.storageValue == value) return placement;
    }
    return null;
  }
}

class VideoControlCustomization {
  const VideoControlCustomization({
    required Map<VideoControlButton, VideoControlPlacement> placements,
  }) : _placements = placements;

  static const VideoControlCustomization defaults = VideoControlCustomization(
    placements: <VideoControlButton, VideoControlPlacement>{
      VideoControlButton.speed: VideoControlPlacement.bottom,
      VideoControlButton.subtitleList: VideoControlPlacement.rightRail,
      VideoControlButton.favoriteSentence: VideoControlPlacement.rightRail,
      VideoControlButton.favoriteSentences: VideoControlPlacement.rightRail,
      VideoControlButton.settings: VideoControlPlacement.rightRail,
    },
  );

  final Map<VideoControlButton, VideoControlPlacement> _placements;

  VideoControlPlacement placementFor(VideoControlButton button) {
    return _placements[button] ??
        defaults._placements[button] ??
        VideoControlPlacement.settingsOnly;
  }

  List<VideoControlButton> buttonsFor(VideoControlPlacement placement) {
    return <VideoControlButton>[
      for (final VideoControlButton button in VideoControlButton.values)
        if (placementFor(button) == placement) button,
    ];
  }

  bool isOnPlayer(VideoControlButton button) =>
      placementFor(button) != VideoControlPlacement.settingsOnly;

  List<VideoControlButton> get settingsFallbackButtons =>
      buttonsFor(VideoControlPlacement.settingsOnly);

  VideoControlCustomization copyWithPlacement(
    VideoControlButton button,
    VideoControlPlacement placement,
  ) {
    return VideoControlCustomization(
      placements: <VideoControlButton, VideoControlPlacement>{
        for (final VideoControlButton b in VideoControlButton.values)
          b: placementFor(b),
        button: placement,
      },
    );
  }

  String encode() {
    return jsonEncode(<String, Object>{
      'version': 1,
      'placements': <String, String>{
        for (final VideoControlButton button in VideoControlButton.values)
          button.storageValue: placementFor(button).storageValue,
      },
    });
  }

  static VideoControlCustomization decode(String json) {
    if (json.trim().isEmpty) return defaults;
    try {
      final Object? raw = jsonDecode(json);
      if (raw is! Map<String, dynamic>) return defaults;
      final Object? placementsRaw = raw['placements'];
      if (placementsRaw is! Map<String, dynamic>) return defaults;
      final Map<VideoControlButton, VideoControlPlacement> placements =
          <VideoControlButton, VideoControlPlacement>{
        for (final VideoControlButton button in VideoControlButton.values)
          button: defaults.placementFor(button),
      };
      for (final MapEntry<String, dynamic> entry in placementsRaw.entries) {
        final VideoControlButton? button =
            VideoControlButton.fromStorage(entry.key);
        final Object? rawValue = entry.value;
        final VideoControlPlacement? placement = rawValue is String
            ? VideoControlPlacement.fromStorage(rawValue)
            : null;
        if (button != null && placement != null) {
          placements[button] = placement;
        }
      }
      return VideoControlCustomization(placements: placements);
    } catch (_) {
      return defaults;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VideoControlCustomization) return false;
    for (final VideoControlButton button in VideoControlButton.values) {
      if (placementFor(button) != other.placementFor(button)) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    return Object.hashAll(
      <Object>[
        for (final VideoControlButton button in VideoControlButton.values)
          Object.hash(button, placementFor(button)),
      ],
    );
  }
}

// ============================================================================
// TODO-274 phase 0: 9-slot full drag-customization data model foundation.
// Pure data, no rendering wired. Coexists with the legacy 3-tier model above
// (VideoControlCustomization stays untouched and keeps driving current chrome).
// ============================================================================

/// The 9 target slots for a control button (Bilibili-style: bottom L/C/R +
/// screen L/R + top L/C/R + hidden). [hidden] = not rendered on the player.
enum VideoControlSlot {
  bottomLeft('bottomLeft'),
  bottomCenter('bottomCenter'),
  bottomRight('bottomRight'),
  screenLeft('screenLeft'),
  screenRight('screenRight'),
  topLeft('topLeft'),
  topCenter('topCenter'),
  topRight('topRight'),
  hidden('hidden');

  const VideoControlSlot(this.storageValue);

  final String storageValue;

  /// Whether this slot is visible on the player (hidden is the only non-visible one).
  bool get isOnPlayer => this != VideoControlSlot.hidden;

  static VideoControlSlot? fromStorage(String value) {
    for (final VideoControlSlot slot in VideoControlSlot.values) {
      if (slot.storageValue == value) return slot;
    }
    return null;
  }

  /// The slots the phase-2 editor exposes and the player actually renders for
  /// customizable learning buttons. Restricted to the positions that have a real
  /// render target today (bottom bar left/right regions + floating left/right
  /// rails + top-area left/right floating rails + hidden), so the picker never
  /// offers a slot that silently no-ops.
  ///
  /// TODO-388: topLeft / topRight were added so users can also place the
  /// customizable learning buttons in the **top** area (a floating top rail,
  /// mirroring the screen side rails) — the player renders them via the same
  /// learning-button path. The bottom-center transport cluster and topCenter
  /// host fixed transport / nav chrome (title / back / episode nav) and stay out
  /// of this set; remodeling those fixed chrome buttons + the immersion lock as
  /// fully draggable items is a separate, larger change (PM decision pending).
  ///
  /// TODO-399 decision 2: [bottomCenter] joined the editable set so the central
  /// transport cluster (play / seek / cue-nav) can also be rebalanced by the
  /// user. [topCenter] still hosts the fixed title chrome and stays out.
  static const List<VideoControlSlot> editableSlots = <VideoControlSlot>[
    VideoControlSlot.topLeft,
    VideoControlSlot.topRight,
    VideoControlSlot.bottomLeft,
    VideoControlSlot.bottomCenter,
    VideoControlSlot.bottomRight,
    VideoControlSlot.screenLeft,
    VideoControlSlot.screenRight,
    VideoControlSlot.hidden,
  ];
}

/// Full button library: transport keys + learning keys.
/// [isSpecialRender] transport keys (play/volume/title/position) get dedicated
/// render branches; everything else renders as a plain icon button.
///
/// - [pinnedRequired]: required buttons cannot be moved into
///   [VideoControlSlot.hidden] (enforced at the model layer, all platforms), so
///   the player always keeps a play/pause control.
/// - [pinnedOnTouch]: buttons that are the *only* in-player entry to recover
///   controls on touch devices (no right-click context menu there). On touch
///   controls they cannot be moved into [VideoControlSlot.hidden] -- enforced at
///   the UI gate via [canMoveToSlot] (`isTouchControls: true`), NOT in the pure
///   persisted model -- so a touch user can never soft-lock themselves out of
///   the settings panel / on-screen editor (TODO-554). Desktop keeps the
///   button removable (the right-click `Icons.tune` menu can restore it).
/// - [legacyButton]: mapping to the legacy [VideoControlButton] used by the
///   v1->v2 migration to translate old placements into new slots; transport
///   keys have no legacy peer (they were hardcoded in the media_kit theme).
enum VideoControlItem {
  back('back'),
  immersiveLock('immersiveLock'),

  // -- learning keys (1:1 with legacy [VideoControlButton]) --
  speed('speed', legacyButton: VideoControlButton.speed),
  subtitleList('subtitleList', legacyButton: VideoControlButton.subtitleList),
  favoriteSentence(
    'favoriteSentence',
    legacyButton: VideoControlButton.favoriteSentence,
  ),
  favoriteSentences(
    'favoriteSentences',
    legacyButton: VideoControlButton.favoriteSentences,
  ),
  settings(
    'settings',
    legacyButton: VideoControlButton.settings,
    pinnedOnTouch: true,
  ),

  // -- transport keys (hardcoded in the media_kit theme; phase 0 only catalogs) --
  playPause('playPause', isSpecialRender: true, pinnedRequired: true),
  seekBackward('seekBackward'),
  seekForward('seekForward'),
  previousCue('previousCue'),
  nextCue('nextCue'),
  volume('volume', isSpecialRender: true),
  fullscreen('fullscreen'),
  screenshot('screenshot'),
  clipExport('clipExport'),
  subtitleTrack('subtitleTrack'),
  audioTrack('audioTrack'),
  previousEpisode('previousEpisode'),
  nextEpisode('nextEpisode'),
  episodeList('episodeList'),
  previousChapter('previousChapter'),
  nextChapter('nextChapter'),
  chapterList('chapterList'),
  title('title', isSpecialRender: true),
  positionIndicator('positionIndicator', isSpecialRender: true);

  const VideoControlItem(
    this.storageValue, {
    this.isSpecialRender = false,
    this.pinnedRequired = false,
    this.pinnedOnTouch = false,
    this.legacyButton,
  });

  final String storageValue;

  /// Special render item (not a plain icon button: play/pause toggle, volume
  /// slider, title text, position indicator). Phase 0 only flags it.
  final bool isSpecialRender;

  /// Required button: cannot be moved into [VideoControlSlot.hidden] on every
  /// platform.
  final bool pinnedRequired;

  /// Touch-only pinned button: the sole in-player entry to recover controls on
  /// touch devices, so on touch controls it cannot be moved into
  /// [VideoControlSlot.hidden] (TODO-554). Desktop is unaffected (it has a
  /// right-click context-menu fallback to reopen settings / restore the button).
  final bool pinnedOnTouch;

  /// Legacy [VideoControlButton] peer (learning keys only; transport keys null).
  final VideoControlButton? legacyButton;

  static VideoControlItem? fromStorage(String value) {
    for (final VideoControlItem item in VideoControlItem.values) {
      if (item.storageValue == value) return item;
    }
    return null;
  }

  /// Find the new [VideoControlItem] for a legacy [VideoControlButton] (migration).
  static VideoControlItem? fromLegacy(VideoControlButton button) {
    for (final VideoControlItem item in VideoControlItem.values) {
      if (item.legacyButton == button) return item;
    }
    return null;
  }

  /// The learning-key items the phase-2 editor lets users place / hide (the five
  /// keys with a legacy peer: speed / subtitleList / favoriteSentence /
  /// favoriteSentences / settings). Transport / nav keys stay fixed in the
  /// chrome and are not user-customizable in this stage.
  static List<VideoControlItem> get customizableLearning => <VideoControlItem>[
        for (final VideoControlItem item in VideoControlItem.values)
          if (item.legacyButton != null) item,
      ];

  /// Whether the visual icon-chip editor can represent this button as a single
  /// draggable chip. [volume] is a dedicated player widget, but the editor can
  /// still represent its placement with a volume icon chip. The only items it
  /// cannot show as a chip is [positionIndicator] (time text). [title] is a
  /// special text chip in the editor: it keeps a dedicated player render path,
  /// but users can move it among top slots or move it out of the player.
  /// [playPause] is special-render but still a single button, so it is
  /// chip-renderable (TODO-399 decision 2).
  bool get isChipRenderable => this != VideoControlItem.positionIndicator;

  /// Whether the item should be moved as a single instance rather than copied
  /// from the palette. Most controls may sit in several slots; title is unique.
  bool get isSingleInstance => this == VideoControlItem.title;

  /// Whether the item may be placed in [target] by the model/editor.
  ///
  /// [volume] is intentionally limited to the bottom bar in this round: its
  /// dedicated render branch is a full button + popover anchor that must never
  /// enter top bars, side rails, or the removed tray.
  ///
  /// [isTouchControls] is the UI-gate hook (TODO-554): the pure persisted model
  /// always calls this with the default `false` so a saved layout stays
  /// cross-platform identical (decode/normalize never depend on the current
  /// platform). Only the on-screen editor / quick-settings sheet pass `true` on
  /// touch devices, which additionally forbids a [pinnedOnTouch] button (the
  /// sole in-player settings entry) from being dragged into
  /// [VideoControlSlot.hidden] -- desktop keeps it removable (right-click menu
  /// restores it).
  bool canMoveToSlot(
    VideoControlSlot target, {
    bool isTouchControls = false,
  }) {
    if (this == VideoControlItem.volume) {
      return target == VideoControlSlot.bottomLeft ||
          target == VideoControlSlot.bottomRight;
    }
    if (this == VideoControlItem.title) {
      return target == VideoControlSlot.topLeft ||
          target == VideoControlSlot.topCenter ||
          target == VideoControlSlot.topRight ||
          target == VideoControlSlot.hidden;
    }
    if (target == VideoControlSlot.topCenter) return false;
    if (pinnedRequired && target == VideoControlSlot.hidden) return false;
    if (isTouchControls && pinnedOnTouch && target == VideoControlSlot.hidden) {
      return false;
    }
    return true;
  }

  /// Whether the persisted model allows removing this button from the player
  /// (cross-platform, no touch gate). Used by decode / normalize / backfill so a
  /// saved layout round-trips identically on every platform.
  bool get canBeRemovedFromPlayer => canMoveToSlot(VideoControlSlot.hidden);

  /// Whether the UI should let the user remove this button from the player on
  /// the current surface. On touch controls a [pinnedOnTouch] button (the sole
  /// in-player settings entry) is not removable, so the user can never soft-lock
  /// themselves out of the controls editor (TODO-554).
  bool canRemoveFromPlayer({bool isTouchControls = false}) =>
      canMoveToSlot(VideoControlSlot.hidden, isTouchControls: isTouchControls);

  /// TODO-399 decision 3b: the full set of buttons the visual editor lets users
  /// freely place / duplicate / hide. This is every modeled button that is
  /// [isChipRenderable] -- i.e. all the learning keys plus volume and transport / nav
  /// keys (play/pause, seek +/-, cue nav, screenshot, subtitle / audio track,
  /// episode list, fullscreen). The non-chip special renders (volume slider,
  /// title text, position indicator) keep their dedicated branch and stay out.
  static List<VideoControlItem> get customizableItems => <VideoControlItem>[
        for (final VideoControlItem item in VideoControlItem.values)
          if (item.isChipRenderable) item,
      ];
}

class _NormalizedVideoControlLayoutData {
  const _NormalizedVideoControlLayoutData({
    required this.slots,
    required this.removed,
  });

  final Map<VideoControlSlot, List<VideoControlItem>> slots;
  final Set<VideoControlItem> removed;
}

/// Per-slot ordered full control button layout. Each [VideoControlSlot]
/// holds an ordered List<VideoControlItem> (drag reorder = reorder that list).
/// A button may live in several visible slots. Moving a removable button into
/// [VideoControlSlot.hidden] removes it from the player and records it in the
/// explicit removed set; hidden is not a restore surface.
///
/// Invariants (kept by the normalizing constructor + the pinned guard):
///   - each [VideoControlItem] appears at most once per visible slot;
///   - missing buttons can be backfilled by decode fallback assignments;
///   - removed buttons are absent from all visible slots and are not listed in
///     [VideoControlSlot.hidden] for rendering;
///   - required buttons ([VideoControlItem.pinnedRequired], currently
///     [VideoControlItem.playPause]) cannot be removed.
class VideoControlLayout {
  VideoControlLayout._(
    this._slots,
    Set<VideoControlItem> removed,
  ) : _removed = Set<VideoControlItem>.unmodifiable(removed);

  /// Build from a flat button->slot map; normalizes into slot->ordered list.
  /// [explicitOrder] controls within-slot ordering (preserves user drag order).
  factory VideoControlLayout.fromAssignments(
    Map<VideoControlItem, VideoControlSlot> assignments, {
    Map<VideoControlSlot, List<VideoControlItem>>? explicitOrder,
  }) {
    final Map<VideoControlSlot, List<VideoControlItem>> slots = _emptySlotMap();
    final Set<VideoControlItem> removed = <VideoControlItem>{};

    if (explicitOrder != null) {
      final Set<VideoControlItem> placed = <VideoControlItem>{};
      for (final VideoControlSlot slot in VideoControlSlot.values) {
        for (final VideoControlItem item
            in explicitOrder[slot] ?? const <VideoControlItem>[]) {
          if (placed.add(item)) {
            _placeRawItem(slots, removed, item, slot);
          }
        }
      }
      for (final VideoControlItem item in VideoControlItem.values) {
        if (placed.contains(item)) continue;
        final VideoControlSlot slot =
            assignments[item] ?? VideoControlSlot.hidden;
        _placeRawItem(slots, removed, item, slot);
      }
    } else {
      for (final VideoControlItem item in VideoControlItem.values) {
        final VideoControlSlot slot =
            assignments[item] ?? VideoControlSlot.hidden;
        _placeRawItem(slots, removed, item, slot);
      }
    }

    return _fromRaw(
      slots,
      removedItems: removed,
      fallbackAssignments: assignments,
    );
  }

  /// Build directly from a slot->ordered-items map **without de-duplicating**:
  /// the same [VideoControlItem] may appear in more than one slot (TODO-399:
  /// one button in multiple positions). Any button absent from every visible
  /// slot is backfilled into [assignments] unless it is in [removedItems]; the
  /// pinned guard still keeps required keys on the player.
  factory VideoControlLayout.fromSlots(
    Map<VideoControlSlot, List<VideoControlItem>> slotItems, {
    Map<VideoControlItem, VideoControlSlot>? assignments,
    Set<VideoControlItem>? removedItems,
  }) {
    final Map<VideoControlSlot, List<VideoControlItem>> slots = _emptySlotMap();
    final Set<VideoControlItem> removed = <VideoControlItem>{
      ...?removedItems,
    };
    final Set<VideoControlItem> seen = <VideoControlItem>{};
    for (final VideoControlSlot slot in VideoControlSlot.values) {
      for (final VideoControlItem item
          in slotItems[slot] ?? const <VideoControlItem>[]) {
        // De-dupe only WITHIN a slot; the same item across slots is allowed.
        if (slots[slot]!.contains(item)) continue;
        final bool placed = _placeRawItem(slots, removed, item, slot);
        if (placed) seen.add(item);
      }
    }
    // Backfill any button that ended up in no visible slot and was not
    // explicitly removed.
    for (final VideoControlItem item in VideoControlItem.values) {
      if (seen.contains(item)) continue;
      if (removed.contains(item) && item.canBeRemovedFromPlayer) continue;
      final VideoControlSlot slot =
          assignments?[item] ?? VideoControlSlot.hidden;
      _placeRawItem(slots, removed, item, slot);
    }
    return _fromRaw(
      slots,
      removedItems: removed,
      fallbackAssignments: assignments,
    );
  }

  static Map<VideoControlSlot, List<VideoControlItem>> _emptySlotMap() =>
      <VideoControlSlot, List<VideoControlItem>>{
        for (final VideoControlSlot slot in VideoControlSlot.values)
          slot: <VideoControlItem>[],
      };

  static bool _placeRawItem(
    Map<VideoControlSlot, List<VideoControlItem>> slots,
    Set<VideoControlItem> removed,
    VideoControlItem item,
    VideoControlSlot slot,
  ) {
    if (slot == VideoControlSlot.hidden) {
      if (item.canBeRemovedFromPlayer) {
        removed.add(item);
      }
      return false;
    }
    if (!item.canMoveToSlot(slot)) return false;
    slots[slot]!.add(item);
    removed.remove(item);
    return true;
  }

  static VideoControlLayout _fromRaw(
    Map<VideoControlSlot, List<VideoControlItem>> slots, {
    Set<VideoControlItem> removedItems = const <VideoControlItem>{},
    Map<VideoControlItem, VideoControlSlot>? fallbackAssignments,
  }) {
    final _NormalizedVideoControlLayoutData data = _normalize(
      slots,
      removedItems: removedItems,
      fallbackAssignments: fallbackAssignments,
    );
    return VideoControlLayout._(data.slots, data.removed);
  }

  /// Default layout: transport keys at traditional positions + learning keys
  /// per the user decision (favorite buttons default to bottomRight).
  ///
  /// This is the new model's own default and does NOT touch the legacy
  /// [VideoControlCustomization.defaults] (which keeps driving current chrome).
  static final VideoControlLayout defaults = VideoControlLayout.fromAssignments(
    const <VideoControlItem, VideoControlSlot>{
      VideoControlItem.back: VideoControlSlot.topLeft,
      VideoControlItem.immersiveLock: VideoControlSlot.screenLeft,
      VideoControlItem.title: VideoControlSlot.topCenter,
      VideoControlItem.previousEpisode: VideoControlSlot.topRight,
      VideoControlItem.nextEpisode: VideoControlSlot.topRight,
      VideoControlItem.episodeList: VideoControlSlot.topRight,
      VideoControlItem.chapterList: VideoControlSlot.topRight,
      VideoControlItem.previousChapter: VideoControlSlot.topRight,
      VideoControlItem.nextChapter: VideoControlSlot.topRight,
      VideoControlItem.positionIndicator: VideoControlSlot.bottomLeft,
      VideoControlItem.previousCue: VideoControlSlot.bottomCenter,
      VideoControlItem.seekBackward: VideoControlSlot.bottomCenter,
      VideoControlItem.playPause: VideoControlSlot.bottomCenter,
      VideoControlItem.seekForward: VideoControlSlot.bottomCenter,
      VideoControlItem.nextCue: VideoControlSlot.bottomCenter,
      VideoControlItem.volume: VideoControlSlot.bottomRight,
      VideoControlItem.speed: VideoControlSlot.bottomRight,
      VideoControlItem.subtitleTrack: VideoControlSlot.bottomRight,
      VideoControlItem.audioTrack: VideoControlSlot.bottomRight,
      VideoControlItem.screenshot: VideoControlSlot.bottomRight,
      VideoControlItem.clipExport: VideoControlSlot.bottomRight,
      VideoControlItem.fullscreen: VideoControlSlot.bottomRight,
      VideoControlItem.settings: VideoControlSlot.bottomRight,
      VideoControlItem.favoriteSentence: VideoControlSlot.bottomRight,
      VideoControlItem.favoriteSentences: VideoControlSlot.bottomRight,
      VideoControlItem.subtitleList: VideoControlSlot.screenRight,
    },
    explicitOrder: const <VideoControlSlot, List<VideoControlItem>>{
      VideoControlSlot.topLeft: <VideoControlItem>[
        VideoControlItem.back,
      ],
      VideoControlSlot.topRight: <VideoControlItem>[
        VideoControlItem.previousEpisode,
        VideoControlItem.nextEpisode,
        VideoControlItem.episodeList,
        VideoControlItem.chapterList,
        VideoControlItem.previousChapter,
        VideoControlItem.nextChapter,
      ],
      VideoControlSlot.screenLeft: <VideoControlItem>[
        VideoControlItem.immersiveLock,
      ],
      VideoControlSlot.bottomCenter: <VideoControlItem>[
        VideoControlItem.seekBackward,
        VideoControlItem.previousCue,
        VideoControlItem.playPause,
        VideoControlItem.nextCue,
        VideoControlItem.seekForward,
      ],
      VideoControlSlot.bottomRight: <VideoControlItem>[
        VideoControlItem.volume,
        VideoControlItem.speed,
        VideoControlItem.subtitleTrack,
        VideoControlItem.audioTrack,
        VideoControlItem.screenshot,
        VideoControlItem.clipExport,
        VideoControlItem.fullscreen,
        VideoControlItem.settings,
        VideoControlItem.favoriteSentence,
        VideoControlItem.favoriteSentences,
      ],
      VideoControlSlot.screenRight: <VideoControlItem>[
        VideoControlItem.subtitleList,
      ],
    },
  );

  /// The layout that reproduces the **current** player chrome pixel-for-pixel
  /// (TODO-274 phase 1 wiring default). Distinct from [defaults] (the phase-0
  /// aspirational target where favorites land in bottomRight): [currentChrome]
  /// keeps every button exactly where today's hardcoded media_kit theme draws
  /// it, so feeding it into the slot renderer leaves the chrome unchanged.
  ///
  /// Mapping of today's chrome:
  ///   - learning keys (speed / subtitleList / favorites / settings): the legacy
  ///     [VideoControlCustomization.defaults] placed speed in the bottom cluster
  ///     and the rest on the right rail -> bottomRight / screenRight respectively.
  ///   - transport / nav keys: drawn in the fixed top bar (back via topLeft,
  ///     title topCenter, episode nav / screenshot / subtitle-track / audio-track
  ///     topRight) and the bottom-center transport cluster (previousCue /
  ///     playPause / nextCue + seek labels) with the position indicator at
  ///     bottomLeft and volume / fullscreen trailing in bottomRight.
  static final VideoControlLayout currentChrome =
      VideoControlLayout.fromAssignments(
    const <VideoControlItem, VideoControlSlot>{
      // -- fixed top bar / side lock, now rendered from layout slots --
      VideoControlItem.back: VideoControlSlot.topLeft,
      VideoControlItem.immersiveLock: VideoControlSlot.screenLeft,
      VideoControlItem.title: VideoControlSlot.topCenter,
      VideoControlItem.previousEpisode: VideoControlSlot.topRight,
      VideoControlItem.nextEpisode: VideoControlSlot.topRight,
      VideoControlItem.episodeList: VideoControlSlot.topRight,
      VideoControlItem.screenshot: VideoControlSlot.topRight,
      VideoControlItem.clipExport: VideoControlSlot.topRight,
      VideoControlItem.subtitleTrack: VideoControlSlot.topRight,
      VideoControlItem.audioTrack: VideoControlSlot.topRight,
      VideoControlItem.chapterList: VideoControlSlot.topRight,
      VideoControlItem.previousChapter: VideoControlSlot.topRight,
      VideoControlItem.nextChapter: VideoControlSlot.topRight,
      // -- bottom-center transport cluster (play pinned geometric centre) --
      VideoControlItem.seekBackward: VideoControlSlot.bottomCenter,
      VideoControlItem.previousCue: VideoControlSlot.bottomCenter,
      VideoControlItem.playPause: VideoControlSlot.bottomCenter,
      VideoControlItem.nextCue: VideoControlSlot.bottomCenter,
      VideoControlItem.seekForward: VideoControlSlot.bottomCenter,
      // -- bottom row trailing / leading --
      VideoControlItem.positionIndicator: VideoControlSlot.bottomLeft,
      VideoControlItem.volume: VideoControlSlot.bottomRight,
      VideoControlItem.fullscreen: VideoControlSlot.bottomRight,
      // -- learning keys, mirroring the legacy default placement --
      VideoControlItem.speed: VideoControlSlot.bottomRight,
      VideoControlItem.subtitleList: VideoControlSlot.screenRight,
      VideoControlItem.favoriteSentence: VideoControlSlot.screenRight,
      VideoControlItem.favoriteSentences: VideoControlSlot.screenRight,
      VideoControlItem.settings: VideoControlSlot.screenRight,
    },
    explicitOrder: const <VideoControlSlot, List<VideoControlItem>>{
      VideoControlSlot.topLeft: <VideoControlItem>[
        VideoControlItem.back,
      ],
      VideoControlSlot.topRight: <VideoControlItem>[
        VideoControlItem.previousEpisode,
        VideoControlItem.nextEpisode,
        VideoControlItem.episodeList,
        VideoControlItem.screenshot,
        VideoControlItem.clipExport,
        VideoControlItem.subtitleTrack,
        VideoControlItem.audioTrack,
        VideoControlItem.chapterList,
        VideoControlItem.previousChapter,
        VideoControlItem.nextChapter,
      ],
      VideoControlSlot.screenLeft: <VideoControlItem>[
        VideoControlItem.immersiveLock,
      ],
      VideoControlSlot.bottomCenter: <VideoControlItem>[
        VideoControlItem.seekBackward,
        VideoControlItem.previousCue,
        VideoControlItem.playPause,
        VideoControlItem.nextCue,
        VideoControlItem.seekForward,
      ],
      VideoControlSlot.bottomLeft: <VideoControlItem>[
        VideoControlItem.positionIndicator,
      ],
      VideoControlSlot.bottomRight: <VideoControlItem>[
        VideoControlItem.volume,
        VideoControlItem.fullscreen,
        VideoControlItem.speed,
      ],
      VideoControlSlot.screenRight: <VideoControlItem>[
        VideoControlItem.subtitleList,
        VideoControlItem.favoriteSentence,
        VideoControlItem.favoriteSentences,
        VideoControlItem.settings,
      ],
    },
  );

  /// Build the live render layout from the persisted legacy
  /// [VideoControlCustomization] (the single persisted source of truth today).
  /// Learning keys follow the user's saved 3-tier placement; transport / nav
  /// keys keep their fixed [currentChrome] positions (the legacy model never
  /// tracked them). Phase 1 reads this so the renderer is data-driven while
  /// persistence stays on the legacy model (phase 2 migrates the picker).
  factory VideoControlLayout.fromLegacy(VideoControlCustomization legacy) {
    final Map<VideoControlItem, VideoControlSlot> assignments =
        <VideoControlItem, VideoControlSlot>{
      for (final VideoControlItem item in VideoControlItem.values)
        item: currentChrome.slotOf(item),
    };
    for (final VideoControlButton button in VideoControlButton.values) {
      final VideoControlItem? item = VideoControlItem.fromLegacy(button);
      if (item == null) continue;
      assignments[item] = _slotForLegacyPlacement(legacy.placementFor(button));
    }
    return VideoControlLayout.fromAssignments(assignments);
  }

  final Map<VideoControlSlot, List<VideoControlItem>> _slots;
  final Set<VideoControlItem> _removed;

  /// Ordered buttons in a slot (unmodifiable copy).
  List<VideoControlItem> itemsIn(VideoControlSlot slot) =>
      List<VideoControlItem>.unmodifiable(
        _slots[slot] ?? const <VideoControlItem>[],
      );

  /// The slot a button currently lives in (constructor guarantees full coverage).
  VideoControlSlot slotOf(VideoControlItem item) {
    for (final VideoControlSlot slot in VideoControlSlot.values) {
      if (_slots[slot]!.contains(item)) return slot;
    }
    return VideoControlSlot.hidden;
  }

  /// Whether the button is visible on the player (non-hidden slot).
  bool isOnPlayer(VideoControlItem item) => slotOf(item).isOnPlayer;

  /// Items explicitly removed from the player, in enum order.
  List<VideoControlItem> get removedItems => <VideoControlItem>[
        for (final VideoControlItem item in VideoControlItem.values)
          if (_removed.contains(item)) item,
      ];

  /// Hidden slot entries are no longer persisted as recoverable buttons. Kept
  /// for old callers and tests that inspect the slot directly; removed items
  /// are exposed via
  /// [removedItems] and restored from the palette/default reset.
  List<VideoControlItem> get hiddenItems => itemsIn(VideoControlSlot.hidden);

  /// Move [item] into [target] at [index] (the core drag-reorder write op).
  /// Moving a required button into hidden is rejected (returns this).
  VideoControlLayout moveItem(
    VideoControlItem item,
    VideoControlSlot target, {
    int? index,
  }) {
    if (!item.canMoveToSlot(target)) {
      return this;
    }
    final Map<VideoControlSlot, List<VideoControlItem>> next =
        <VideoControlSlot, List<VideoControlItem>>{
      for (final VideoControlSlot slot in VideoControlSlot.values)
        slot: List<VideoControlItem>.from(_slots[slot]!)
          ..removeWhere((VideoControlItem i) => i == item),
    };
    final Set<VideoControlItem> removed = <VideoControlItem>{..._removed};
    if (target == VideoControlSlot.hidden) {
      removed.add(item);
      return _fromRaw(next, removedItems: removed);
    }
    removed.remove(item);
    final List<VideoControlItem> targetList = next[target]!;
    final int insertAt =
        (index == null) ? targetList.length : index.clamp(0, targetList.length);
    targetList.insert(insertAt, item);
    return _fromRaw(next, removedItems: removed);
  }

  /// All slots [item] currently lives in, in [VideoControlSlot.values] order
  /// (TODO-399: a button may sit in more than one slot). Empty maps to
  /// `[hidden]` (the normalizer guarantees every button appears somewhere).
  List<VideoControlSlot> slotsOf(VideoControlItem item) {
    final List<VideoControlSlot> hits = <VideoControlSlot>[
      for (final VideoControlSlot slot in VideoControlSlot.values)
        if (_slots[slot]!.contains(item)) slot,
    ];
    if (hits.isNotEmpty) return hits;
    return _removed.contains(item)
        ? const <VideoControlSlot>[VideoControlSlot.hidden]
        : const <VideoControlSlot>[];
  }

  /// Add a copy of [item] into [target] WITHOUT removing it from other slots
  /// (TODO-399: one button in multiple positions). Idempotent within a slot.
  /// Adding a required button into hidden is rejected (returns this).
  VideoControlLayout addItemToSlot(
    VideoControlItem item,
    VideoControlSlot target, {
    int? index,
  }) {
    if (!item.canMoveToSlot(target)) {
      return this;
    }
    if (item.isSingleInstance) {
      return moveItem(item, target, index: index);
    }
    if (target == VideoControlSlot.hidden) {
      return moveItem(item, target, index: index);
    }
    if (_slots[target]!.contains(item)) return this; // already here, no-op.
    final Map<VideoControlSlot, List<VideoControlItem>> next =
        <VideoControlSlot, List<VideoControlItem>>{
      for (final VideoControlSlot slot in VideoControlSlot.values)
        slot: List<VideoControlItem>.from(_slots[slot]!),
    };
    final Set<VideoControlItem> removed = <VideoControlItem>{..._removed}
      ..remove(item);
    final List<VideoControlItem> targetList = next[target]!;
    final int insertAt =
        (index == null) ? targetList.length : index.clamp(0, targetList.length);
    targetList.insert(insertAt, item);
    return _fromRaw(next, removedItems: removed);
  }

  /// Move the exact dragged copy represented by [payload] into [target].
  ///
  /// Palette drags ([VideoControlDragData.sourceSlot] == null) add a new copy.
  /// Placed-chip drags remove only [payload.sourceIndex] from its source slot
  /// before inserting into [target], so another copy of the same item in a
  /// different slot survives. Same-slot drags become an index-aware reorder.
  VideoControlLayout moveDraggedItem(
    VideoControlDragData payload,
    VideoControlSlot target, {
    int? targetIndex,
  }) {
    final VideoControlItem item = payload.item;
    if (payload.sourceSlot == null) {
      return addItemToSlot(item, target, index: targetIndex);
    }
    if (!item.canMoveToSlot(target)) {
      return this;
    }
    if (item.isSingleInstance) {
      return moveItem(item, target, index: targetIndex);
    }

    final VideoControlSlot source = payload.sourceSlot!;
    final Map<VideoControlSlot, List<VideoControlItem>> next =
        <VideoControlSlot, List<VideoControlItem>>{
      for (final VideoControlSlot slot in VideoControlSlot.values)
        slot: List<VideoControlItem>.from(_slots[slot]!),
    };
    final List<VideoControlItem> sourceList = next[source]!;
    final int sourceIndex = payload.sourceIndex ??
        sourceList
            .indexWhere((VideoControlItem candidate) => candidate == item);
    if (sourceIndex < 0 ||
        sourceIndex >= sourceList.length ||
        sourceList[sourceIndex] != item) {
      return this;
    }

    final Set<VideoControlItem> removed = <VideoControlItem>{..._removed};
    if (target == VideoControlSlot.hidden) {
      sourceList.removeAt(sourceIndex);
      final bool stillVisible = VideoControlSlot.values.any(
        (VideoControlSlot s) => s.isOnPlayer && next[s]!.contains(item),
      );
      if (!stillVisible) removed.add(item);
      return _fromRaw(next, removedItems: removed);
    }
    removed.remove(item);
    final List<VideoControlItem> targetList = next[target]!;
    if (source != target && targetList.contains(item)) {
      return this;
    }

    sourceList.removeAt(sourceIndex);
    int insertAt = targetIndex ?? targetList.length;
    if (source == target && targetIndex != null && sourceIndex < targetIndex) {
      insertAt -= 1;
    }
    insertAt = insertAt.clamp(0, targetList.length);
    targetList.insert(insertAt, item);
    return _fromRaw(next, removedItems: removed);
  }

  /// Remove the copy of [item] sitting in [slot] (TODO-399 delete / un-place).
  /// If that was its last visible copy, the button is marked removed. A required
  /// key whose last visible copy is removed is bounced back to a default slot.
  VideoControlLayout removeItemFromSlot(
    VideoControlItem item,
    VideoControlSlot slot,
  ) {
    if (!_slots[slot]!.contains(item)) return this;
    final Map<VideoControlSlot, List<VideoControlItem>> next =
        <VideoControlSlot, List<VideoControlItem>>{
      for (final VideoControlSlot s in VideoControlSlot.values)
        s: List<VideoControlItem>.from(_slots[s]!),
    };
    next[slot]!.removeWhere((VideoControlItem i) => i == item);
    final Set<VideoControlItem> removed = <VideoControlItem>{..._removed};
    final bool stillVisible = VideoControlSlot.values.any(
      (VideoControlSlot s) => s.isOnPlayer && next[s]!.contains(item),
    );
    if (!stillVisible) {
      if (!item.canBeRemovedFromPlayer) return this;
      removed.add(item);
    }
    return _fromRaw(next, removedItems: removed);
  }

  String encode() {
    return jsonEncode(<String, Object>{
      'version': 3,
      'slots': <String, List<String>>{
        for (final VideoControlSlot slot in VideoControlSlot.values)
          if (slot != VideoControlSlot.hidden)
            slot.storageValue: <String>[
              for (final VideoControlItem item in _slots[slot]!)
                item.storageValue,
            ],
      },
      if (_removed.isNotEmpty)
        'removed': <String>[
          for (final VideoControlItem item in VideoControlItem.values)
            if (_removed.contains(item)) item.storageValue,
        ],
    });
  }

  String encodeV2ForTests() {
    return jsonEncode(<String, Object>{
      'version': 2,
      'slots': <String, List<String>>{
        for (final VideoControlSlot slot in VideoControlSlot.values)
          slot.storageValue: <String>[
            for (final VideoControlItem item in _slots[slot]!)
              item.storageValue,
          ],
      },
    });
  }

  /// Decode persisted string; auto-detects v1 (old placements), v2 (slots where
  /// hidden entries migrate to removed items), and v3 (slots + explicit removed).
  /// Missing buttons in old/partial payloads are backfilled from current chrome.
  /// Any unparseable input falls back to
  /// [currentChrome] and never throws, so upgrading users do not see the player
  /// chrome move until they explicitly save a new visual layout.
  static VideoControlLayout decode(String json) {
    if (json.trim().isEmpty) return currentChrome;
    try {
      final Object? raw = jsonDecode(json);
      if (raw is! Map<String, dynamic>) return currentChrome;
      final Object? version = raw['version'];
      // v1: old 3-tier placements -> new slots (backward-compat iron rule).
      if (raw.containsKey('placements')) {
        return _migrateFromV1(raw['placements']);
      }
      final Object? slotsRaw = raw['slots'];
      if ((version == 2 || version == 3) && slotsRaw is Map<String, dynamic>) {
        return _decodeSlots(
          slotsRaw,
          removedRaw: version == 3 ? raw['removed'] : null,
        );
      }
      return currentChrome;
    } catch (_) {
      return currentChrome;
    }
  }

  /// v1 migration: bottom->bottomRight / rightRail->screenRight /
  /// settingsOnly->removed. Old model only had 5 learning keys; transport keys
  /// keep their current chrome slots (the old model never tracked them).
  static VideoControlLayout _migrateFromV1(Object? placementsRaw) {
    final Map<VideoControlItem, VideoControlSlot> assignments =
        <VideoControlItem, VideoControlSlot>{
      for (final VideoControlItem item in VideoControlItem.values)
        item: currentChrome.slotOf(item),
    };
    if (placementsRaw is Map<String, dynamic>) {
      for (final MapEntry<String, dynamic> entry in placementsRaw.entries) {
        final VideoControlButton? legacy =
            VideoControlButton.fromStorage(entry.key);
        final Object? value = entry.value;
        final VideoControlPlacement? placement =
            value is String ? VideoControlPlacement.fromStorage(value) : null;
        if (legacy == null || placement == null) continue;
        final VideoControlItem? item = VideoControlItem.fromLegacy(legacy);
        if (item == null) continue;
        assignments[item] = _slotForLegacyPlacement(placement);
      }
    }
    return VideoControlLayout.fromAssignments(assignments);
  }

  /// Old placement -> new slot lossless mapping. The hidden target is consumed
  /// by [fromAssignments] as "removed from player", not as a visible tray item.
  static VideoControlSlot _slotForLegacyPlacement(
    VideoControlPlacement placement,
  ) {
    switch (placement) {
      case VideoControlPlacement.bottom:
        return VideoControlSlot.bottomRight;
      case VideoControlPlacement.rightRail:
        return VideoControlSlot.screenRight;
      case VideoControlPlacement.settingsOnly:
        return VideoControlSlot.hidden;
    }
  }

  static VideoControlLayout _decodeSlots(
    Map<String, dynamic> slotsRaw, {
    Object? removedRaw,
  }) {
    final Map<VideoControlSlot, List<VideoControlItem>> explicitOrder =
        <VideoControlSlot, List<VideoControlItem>>{};
    final Set<VideoControlItem> removed = <VideoControlItem>{};
    if (removedRaw is List) {
      for (final Object? rawItem in removedRaw) {
        if (rawItem is! String) continue;
        final VideoControlItem? item = VideoControlItem.fromStorage(rawItem);
        if (item != null && item.canBeRemovedFromPlayer) {
          removed.add(item);
        }
      }
    }
    int visibleItemCount = 0;
    for (final MapEntry<String, dynamic> entry in slotsRaw.entries) {
      final VideoControlSlot? slot = VideoControlSlot.fromStorage(entry.key);
      final Object? listRaw = entry.value;
      if (slot == null || listRaw is! List) continue;
      // TODO-598 / BUG-339: the v2 layout persisted everything the user took off
      // the player inside a single `hidden` slot. v3 replaced that slot with an
      // explicit `removed` set, so on upgrade every v2 hidden key must be carried
      // across as removed (still restorable from the palette) -- never silently
      // dropped from both the player and the tray. Handled by the dedicated
      // migration helper so the intent is explicit, not an inline side effect.
      if (slot == VideoControlSlot.hidden) {
        _migrateV2HiddenKeysAsRemoved(listRaw, removed);
        continue;
      }
      final List<VideoControlItem> items = <VideoControlItem>[];
      for (final Object? rawItem in listRaw) {
        if (rawItem is! String) continue;
        final VideoControlItem? item = VideoControlItem.fromStorage(rawItem);
        if (item == null) continue;
        if (!item.canMoveToSlot(slot)) continue;
        items.add(item);
      }
      if (slot.isOnPlayer) visibleItemCount += items.length;
      explicitOrder[slot] = items;
    }
    if (visibleItemCount == 0 && removed.isEmpty) {
      return currentChrome;
    }
    final Map<VideoControlItem, VideoControlSlot> fallback =
        <VideoControlItem, VideoControlSlot>{
      for (final VideoControlItem item in VideoControlItem.values)
        item: currentChrome.slotOf(item),
    };
    // fromSlots (not fromAssignments) so a button persisted into several slots
    // survives the round trip (TODO-399 one-button-many-positions).
    return VideoControlLayout.fromSlots(
      explicitOrder,
      assignments: fallback,
      removedItems: removed,
    );
  }

  /// TODO-598 / BUG-339: carry every key from a v2 `hidden` slot into the v3
  /// [removed] set so an upgrading user keeps exactly the buttons they had taken
  /// off the player (still restorable from the palette), with no silent loss.
  ///
  /// A key that is no longer removable (only [VideoControlItem.playPause] today)
  /// is intentionally skipped here: [_normalize] backfills it onto the player,
  /// because a required transport key can never be hidden. Every other v2 hidden
  /// key must reach [removed]; this is pinned by the BUG-339 guard test.
  static void _migrateV2HiddenKeysAsRemoved(
    List<dynamic> hiddenRaw,
    Set<VideoControlItem> removed,
  ) {
    for (final Object? rawItem in hiddenRaw) {
      if (rawItem is! String) continue;
      final VideoControlItem? item = VideoControlItem.fromStorage(rawItem);
      if (item == null) continue;
      if (item.canBeRemovedFromPlayer) removed.add(item);
    }
  }

  /// Normalizing invariant keeper:
  ///   1. a button appears at most once per visible slot;
  ///   2. a button can be absent from the player only when explicitly removed;
  ///   3. old/partial payloads can still backfill missing buttons from
  ///      [fallbackAssignments];
  ///   4. required buttons cannot be removed.
  static _NormalizedVideoControlLayoutData _normalize(
    Map<VideoControlSlot, List<VideoControlItem>> rawSlots, {
    Set<VideoControlItem> removedItems = const <VideoControlItem>{},
    Map<VideoControlItem, VideoControlSlot>? fallbackAssignments,
  }) {
    final Map<VideoControlSlot, List<VideoControlItem>> slots = _emptySlotMap();
    final Set<VideoControlItem> removed = <VideoControlItem>{
      for (final VideoControlItem item in removedItems)
        if (item.canBeRemovedFromPlayer) item,
    };
    for (final VideoControlSlot slot in VideoControlSlot.values) {
      for (final VideoControlItem item
          in rawSlots[slot] ?? const <VideoControlItem>[]) {
        _placeRawItem(slots, removed, item, slot);
      }
    }
    _dedupeWithinSlots(slots);

    final Set<VideoControlItem> visible = <VideoControlItem>{
      for (final VideoControlSlot slot in VideoControlSlot.values)
        if (slot.isOnPlayer) ...slots[slot]!,
    };
    removed.removeWhere(
      (VideoControlItem item) =>
          visible.contains(item) || !item.canBeRemovedFromPlayer,
    );

    for (final VideoControlItem item in VideoControlItem.values) {
      if (visible.contains(item)) continue;
      if (removed.contains(item)) continue;
      final VideoControlSlot? fallback = fallbackAssignments?[item];
      if (fallback != null) {
        final bool placed = _placeRawItem(slots, removed, item, fallback);
        if (placed) {
          visible.add(item);
          continue;
        }
        if (removed.contains(item)) continue;
      }
      if (item.canBeRemovedFromPlayer) {
        removed.add(item);
      } else {
        _placeRawItem(slots, removed, item, _defaultSlotForRequired(item));
        visible.add(item);
      }
    }
    _normalizeVolume(slots, removed);
    _normalizeTitle(slots, removed);
    removed.removeWhere(
      (VideoControlItem item) =>
          !item.canBeRemovedFromPlayer ||
          VideoControlSlot.values.any(
            (VideoControlSlot slot) =>
                slot.isOnPlayer && slots[slot]!.contains(item),
          ),
    );
    slots[VideoControlSlot.hidden]!.clear();
    return _NormalizedVideoControlLayoutData(
      slots: slots,
      removed: removed,
    );
  }

  static void _dedupeWithinSlots(
    Map<VideoControlSlot, List<VideoControlItem>> slots,
  ) {
    for (final VideoControlSlot slot in VideoControlSlot.values) {
      final Set<VideoControlItem> seen = <VideoControlItem>{};
      slots[slot]!.removeWhere((VideoControlItem item) => !seen.add(item));
    }
  }

  static void _normalizeVolume(
    Map<VideoControlSlot, List<VideoControlItem>> slots,
    Set<VideoControlItem> removed,
  ) {
    bool hasBottomVolume = false;
    for (final VideoControlSlot slot in const <VideoControlSlot>[
      VideoControlSlot.bottomLeft,
      VideoControlSlot.bottomRight,
    ]) {
      hasBottomVolume =
          hasBottomVolume || slots[slot]!.contains(VideoControlItem.volume);
    }

    for (final VideoControlSlot slot in VideoControlSlot.values) {
      if (slot == VideoControlSlot.bottomLeft ||
          slot == VideoControlSlot.bottomRight) {
        continue;
      }
      slots[slot]!.removeWhere(
        (VideoControlItem item) => item == VideoControlItem.volume,
      );
    }

    if (!hasBottomVolume) {
      slots[VideoControlSlot.bottomRight]!.insert(
        0,
        VideoControlItem.volume,
      );
    }
    removed.remove(VideoControlItem.volume);
  }

  static void _normalizeTitle(
    Map<VideoControlSlot, List<VideoControlItem>> slots,
    Set<VideoControlItem> removed,
  ) {
    VideoControlSlot? target;
    int targetIndex = 0;
    for (final VideoControlSlot slot in const <VideoControlSlot>[
      VideoControlSlot.topLeft,
      VideoControlSlot.topCenter,
      VideoControlSlot.topRight,
    ]) {
      final int index = slots[slot]!.indexOf(VideoControlItem.title);
      if (index < 0) continue;
      target ??= slot;
      if (target == slot) targetIndex = index;
    }

    for (final VideoControlSlot slot in VideoControlSlot.values) {
      slots[slot]!.removeWhere(
        (VideoControlItem item) => item == VideoControlItem.title,
      );
    }

    if (target == null && removed.contains(VideoControlItem.title)) {
      return;
    }
    final VideoControlSlot resolved = target ?? VideoControlSlot.topCenter;
    final List<VideoControlItem> list = slots[resolved]!;
    list.insert(targetIndex.clamp(0, list.length), VideoControlItem.title);
    removed.remove(VideoControlItem.title);
  }

  /// Recovery slot for a required button wrongly removed (does not
  /// depend on [defaults] to avoid an init cycle).
  static VideoControlSlot _defaultSlotForRequired(VideoControlItem item) {
    switch (item) {
      case VideoControlItem.playPause:
        return VideoControlSlot.bottomCenter;
      default:
        return VideoControlSlot.bottomRight;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VideoControlLayout) return false;
    for (final VideoControlSlot slot in VideoControlSlot.values) {
      final List<VideoControlItem> a = _slots[slot]!;
      final List<VideoControlItem> b = other._slots[slot]!;
      if (a.length != b.length) return false;
      for (int i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
    }
    if (_removed.length != other._removed.length) return false;
    return _removed.containsAll(other._removed);
  }

  @override
  int get hashCode {
    return Object.hashAll(<Object>[
      for (final VideoControlSlot slot in VideoControlSlot.values) ...<Object>[
        slot,
        ..._slots[slot]!,
      ],
      'removed',
      for (final VideoControlItem item in VideoControlItem.values)
        if (_removed.contains(item)) item,
    ]);
  }
}

/// Drag payload for visual control-layout editors: the dragged
/// [VideoControlItem] plus the slot it came from ([sourceSlot] == null means it
/// was dragged from an "all buttons" palette, i.e. an add).
class VideoControlDragData {
  const VideoControlDragData({
    required this.item,
    required this.sourceSlot,
    this.sourceIndex,
  });

  final VideoControlItem item;
  final VideoControlSlot? sourceSlot;
  final int? sourceIndex;
}
