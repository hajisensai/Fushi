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

/// Full button library: transport keys + learning keys. Phase 0 only models it.
/// [isSpecialRender] transport keys (play/volume/title/position) get dedicated
/// render branches in phase 1; everything else renders as a plain icon button.
///
/// - [pinnedRequired]: required buttons ([settings] / [playPause]) cannot be
///   moved into [VideoControlSlot.hidden] (enforced at the model layer), so the
///   player always keeps a settings entry and a play/pause control.
/// - [legacyButton]: mapping to the legacy [VideoControlButton] used by the
///   v1->v2 migration to translate old placements into new slots; transport
///   keys have no legacy peer (they were hardcoded in the media_kit theme).
enum VideoControlItem {
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
    pinnedRequired: true,
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
  subtitleTrack('subtitleTrack'),
  audioTrack('audioTrack'),
  episodeList('episodeList'),
  title('title', isSpecialRender: true),
  positionIndicator('positionIndicator', isSpecialRender: true);

  const VideoControlItem(
    this.storageValue, {
    this.isSpecialRender = false,
    this.pinnedRequired = false,
    this.legacyButton,
  });

  final String storageValue;

  /// Special render item (not a plain icon button: play/pause toggle, volume
  /// slider, title text, position indicator). Phase 0 only flags it.
  final bool isSpecialRender;

  /// Required button: cannot be moved into [VideoControlSlot.hidden].
  final bool pinnedRequired;

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
  /// draggable chip. The only items it cannot are the multi-widget special
  /// renders that are NOT a single icon button: [volume] (a slider), [title]
  /// (text), [positionIndicator] (time text). [playPause] is special-render but
  /// still a single button, so it is chip-renderable (TODO-399 decision 2).
  bool get isChipRenderable =>
      this != VideoControlItem.volume &&
      this != VideoControlItem.title &&
      this != VideoControlItem.positionIndicator;

  /// TODO-399 decision 3b: the full set of buttons the visual editor lets users
  /// freely place / duplicate / hide. This is every modeled button that is
  /// [isChipRenderable] -- i.e. all the learning keys plus the transport / nav
  /// keys (play/pause, seek +/-, cue nav, screenshot, subtitle / audio track,
  /// episode list, fullscreen). The non-chip special renders (volume slider,
  /// title text, position indicator) keep their dedicated branch and stay out.
  static List<VideoControlItem> get customizableItems => <VideoControlItem>[
        for (final VideoControlItem item in VideoControlItem.values)
          if (item.isChipRenderable) item,
      ];
}

/// Per-slot ordered full control button layout (v2). Each [VideoControlSlot]
/// holds an ordered List<VideoControlItem> (drag reorder = reorder that list).
/// A button lives in exactly one slot.
///
/// Invariants (kept by the normalizing constructor + the pinned guard):
///   - each [VideoControlItem] appears at most once (deduped in enum order);
///   - missing buttons fall into [VideoControlSlot.hidden] (except required keys);
///   - required buttons ([VideoControlItem.pinnedRequired]) never sit in
///     [VideoControlSlot.hidden]: if the source data puts one there, it is
///     bounced back to its default slot.
class VideoControlLayout {
  VideoControlLayout._(this._slots);

  /// Build from a flat button->slot map; normalizes into slot->ordered list.
  /// [explicitOrder] controls within-slot ordering (preserves user drag order).
  factory VideoControlLayout.fromAssignments(
    Map<VideoControlItem, VideoControlSlot> assignments, {
    Map<VideoControlSlot, List<VideoControlItem>>? explicitOrder,
  }) {
    final Map<VideoControlSlot, List<VideoControlItem>> slots =
        <VideoControlSlot, List<VideoControlItem>>{
      for (final VideoControlSlot slot in VideoControlSlot.values)
        slot: <VideoControlItem>[],
    };

    if (explicitOrder != null) {
      final Set<VideoControlItem> placed = <VideoControlItem>{};
      for (final VideoControlSlot slot in VideoControlSlot.values) {
        for (final VideoControlItem item
            in explicitOrder[slot] ?? const <VideoControlItem>[]) {
          if (placed.add(item)) slots[slot]!.add(item);
        }
      }
      for (final VideoControlItem item in VideoControlItem.values) {
        if (placed.contains(item)) continue;
        final VideoControlSlot slot =
            assignments[item] ?? VideoControlSlot.hidden;
        slots[slot]!.add(item);
      }
    } else {
      for (final VideoControlItem item in VideoControlItem.values) {
        final VideoControlSlot slot =
            assignments[item] ?? VideoControlSlot.hidden;
        slots[slot]!.add(item);
      }
    }

    return VideoControlLayout._(_normalize(slots));
  }

  /// Build directly from a slot->ordered-items map **without de-duplicating**:
  /// the same [VideoControlItem] may appear in more than one slot (TODO-399:
  /// one button in multiple positions). Any button absent from every slot is
  /// backfilled into [assignments] (or [VideoControlSlot.hidden]); the pinned
  /// guard still keeps required keys on the player.
  factory VideoControlLayout.fromSlots(
    Map<VideoControlSlot, List<VideoControlItem>> slotItems, {
    Map<VideoControlItem, VideoControlSlot>? assignments,
  }) {
    final Map<VideoControlSlot, List<VideoControlItem>> slots =
        <VideoControlSlot, List<VideoControlItem>>{
      for (final VideoControlSlot slot in VideoControlSlot.values)
        slot: <VideoControlItem>[],
    };
    final Set<VideoControlItem> seen = <VideoControlItem>{};
    for (final VideoControlSlot slot in VideoControlSlot.values) {
      for (final VideoControlItem item
          in slotItems[slot] ?? const <VideoControlItem>[]) {
        // De-dupe only WITHIN a slot; the same item across slots is allowed.
        if (slots[slot]!.contains(item)) continue;
        slots[slot]!.add(item);
        seen.add(item);
      }
    }
    // Backfill any button that ended up in no slot at all.
    for (final VideoControlItem item in VideoControlItem.values) {
      if (seen.contains(item)) continue;
      final VideoControlSlot slot =
          assignments?[item] ?? VideoControlSlot.hidden;
      slots[slot]!.add(item);
    }
    return VideoControlLayout._(_normalize(slots));
  }

  /// v2 default layout: transport keys at traditional positions + learning keys
  /// per the user decision (favorite buttons default to bottomRight).
  ///
  /// This is the new model's own default and does NOT touch the legacy
  /// [VideoControlCustomization.defaults] (which keeps driving current chrome).
  static final VideoControlLayout defaults = VideoControlLayout.fromAssignments(
    const <VideoControlItem, VideoControlSlot>{
      VideoControlItem.title: VideoControlSlot.topCenter,
      VideoControlItem.episodeList: VideoControlSlot.topRight,
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
      VideoControlItem.fullscreen: VideoControlSlot.bottomRight,
      VideoControlItem.settings: VideoControlSlot.bottomRight,
      VideoControlItem.favoriteSentence: VideoControlSlot.bottomRight,
      VideoControlItem.favoriteSentences: VideoControlSlot.bottomRight,
      VideoControlItem.subtitleList: VideoControlSlot.screenRight,
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
      // -- fixed top bar (drawn inline; not user-customizable in phase 1) --
      VideoControlItem.title: VideoControlSlot.topCenter,
      VideoControlItem.episodeList: VideoControlSlot.topRight,
      VideoControlItem.screenshot: VideoControlSlot.topRight,
      VideoControlItem.subtitleTrack: VideoControlSlot.topRight,
      VideoControlItem.audioTrack: VideoControlSlot.topRight,
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

  /// Hidden (settings-fallback) buttons in enum order.
  List<VideoControlItem> get hiddenItems => itemsIn(VideoControlSlot.hidden);

  /// Move [item] into [target] at [index] (the core drag-reorder write op).
  /// Moving a required button into hidden is rejected (returns this).
  VideoControlLayout moveItem(
    VideoControlItem item,
    VideoControlSlot target, {
    int? index,
  }) {
    if (item.pinnedRequired && target == VideoControlSlot.hidden) {
      return this; // pinned guard: refuse to hide a required key.
    }
    final Map<VideoControlSlot, List<VideoControlItem>> next =
        <VideoControlSlot, List<VideoControlItem>>{
      for (final VideoControlSlot slot in VideoControlSlot.values)
        slot: List<VideoControlItem>.from(_slots[slot]!)
          ..removeWhere((VideoControlItem i) => i == item),
    };
    final List<VideoControlItem> targetList = next[target]!;
    final int insertAt =
        (index == null) ? targetList.length : index.clamp(0, targetList.length);
    targetList.insert(insertAt, item);
    return VideoControlLayout._(_normalize(next));
  }

  /// All slots [item] currently lives in, in [VideoControlSlot.values] order
  /// (TODO-399: a button may sit in more than one slot). Empty maps to
  /// `[hidden]` (the normalizer guarantees every button appears somewhere).
  List<VideoControlSlot> slotsOf(VideoControlItem item) {
    final List<VideoControlSlot> hits = <VideoControlSlot>[
      for (final VideoControlSlot slot in VideoControlSlot.values)
        if (_slots[slot]!.contains(item)) slot,
    ];
    return hits.isEmpty
        ? const <VideoControlSlot>[VideoControlSlot.hidden]
        : hits;
  }

  /// Add a copy of [item] into [target] WITHOUT removing it from other slots
  /// (TODO-399: one button in multiple positions). Idempotent within a slot.
  /// Adding a required button into hidden is rejected (returns this).
  VideoControlLayout addItemToSlot(
    VideoControlItem item,
    VideoControlSlot target, {
    int? index,
  }) {
    if (item.pinnedRequired && target == VideoControlSlot.hidden) {
      return this; // pinned guard: never park a required key in hidden.
    }
    if (_slots[target]!.contains(item)) return this; // already here, no-op.
    final Map<VideoControlSlot, List<VideoControlItem>> next =
        <VideoControlSlot, List<VideoControlItem>>{
      for (final VideoControlSlot slot in VideoControlSlot.values)
        slot: List<VideoControlItem>.from(_slots[slot]!),
    };
    final List<VideoControlItem> targetList = next[target]!;
    final int insertAt =
        (index == null) ? targetList.length : index.clamp(0, targetList.length);
    targetList.insert(insertAt, item);
    return VideoControlLayout._(_normalize(next));
  }

  /// Remove the copy of [item] sitting in [slot] (TODO-399 delete / un-place).
  /// If that was its last copy the normalizer drops it to hidden; a required
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
    return VideoControlLayout._(_normalize(next));
  }

  String encode() {
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

  /// Decode persisted string; auto-detects v1 (old placements) / v2 (new slots)
  /// and backfills missing buttons. Any unparseable input falls back to
  /// [defaults] and never throws.
  static VideoControlLayout decode(String json) {
    if (json.trim().isEmpty) return defaults;
    try {
      final Object? raw = jsonDecode(json);
      if (raw is! Map<String, dynamic>) return defaults;
      final Object? version = raw['version'];
      // v1: old 3-tier placements -> new slots (backward-compat iron rule).
      if (raw.containsKey('placements')) {
        return _migrateFromV1(raw['placements']);
      }
      final Object? slotsRaw = raw['slots'];
      if (version == 2 && slotsRaw is Map<String, dynamic>) {
        return _decodeV2(slotsRaw);
      }
      return defaults;
    } catch (_) {
      return defaults;
    }
  }

  /// v1->v2 migration: bottom->bottomRight / rightRail->screenRight /
  /// settingsOnly->hidden. Old model only had 5 learning keys; transport keys
  /// keep their v2 default slots (the old model never tracked them).
  static VideoControlLayout _migrateFromV1(Object? placementsRaw) {
    final Map<VideoControlItem, VideoControlSlot> assignments =
        <VideoControlItem, VideoControlSlot>{
      for (final VideoControlItem item in VideoControlItem.values)
        item: defaults.slotOf(item),
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

  /// Old placement -> new slot lossless mapping (single source of truth).
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

  static VideoControlLayout _decodeV2(Map<String, dynamic> slotsRaw) {
    final Map<VideoControlSlot, List<VideoControlItem>> explicitOrder =
        <VideoControlSlot, List<VideoControlItem>>{};
    for (final MapEntry<String, dynamic> entry in slotsRaw.entries) {
      final VideoControlSlot? slot = VideoControlSlot.fromStorage(entry.key);
      final Object? listRaw = entry.value;
      if (slot == null || listRaw is! List) continue;
      final List<VideoControlItem> items = <VideoControlItem>[];
      for (final Object? rawItem in listRaw) {
        if (rawItem is! String) continue;
        final VideoControlItem? item = VideoControlItem.fromStorage(rawItem);
        if (item != null) items.add(item);
      }
      explicitOrder[slot] = items;
    }
    final Map<VideoControlItem, VideoControlSlot> fallback =
        <VideoControlItem, VideoControlSlot>{
      for (final VideoControlItem item in VideoControlItem.values)
        item: defaults.slotOf(item),
    };
    // fromSlots (not fromAssignments) so a button persisted into several slots
    // survives the round trip (TODO-399 one-button-many-positions).
    return VideoControlLayout.fromSlots(explicitOrder, assignments: fallback);
  }

  /// Normalizing invariant keeper (TODO-399, multi-slot aware):
  ///   1. every button appears in at least one slot (absent maps to hidden);
  ///   2. a required button ([pinnedRequired]) never lives ONLY in hidden
  ///      (with no visible copy): its hidden copy is bounced to a default
  ///      visible slot. A required button that still has a visible copy
  ///      elsewhere may keep being listed in hidden too (harmless, never
  ///      rendered), and a required button may sit in several visible slots.
  static Map<VideoControlSlot, List<VideoControlItem>> _normalize(
    Map<VideoControlSlot, List<VideoControlItem>> slots,
  ) {
    final Set<VideoControlItem> present = <VideoControlItem>{
      for (final List<VideoControlItem> list in slots.values) ...list,
    };
    for (final VideoControlItem item in VideoControlItem.values) {
      if (!present.contains(item)) {
        slots[VideoControlSlot.hidden]!.add(item);
      }
    }
    final List<VideoControlItem> hidden = slots[VideoControlSlot.hidden]!;
    for (final VideoControlItem item in <VideoControlItem>[...hidden]) {
      if (!item.pinnedRequired) continue;
      final bool hasVisibleCopy = VideoControlSlot.values.any(
        (VideoControlSlot s) => s.isOnPlayer && slots[s]!.contains(item),
      );
      if (hasVisibleCopy) continue;
      hidden.removeWhere((VideoControlItem i) => i == item);
      slots[_defaultSlotForPinned(item)]!.add(item);
    }
    return slots;
  }

  /// Recovery slot for a required button wrongly placed in hidden (does not
  /// depend on [defaults] to avoid an init cycle).
  static VideoControlSlot _defaultSlotForPinned(VideoControlItem item) {
    switch (item) {
      case VideoControlItem.playPause:
        return VideoControlSlot.bottomCenter;
      case VideoControlItem.settings:
        return VideoControlSlot.bottomRight;
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
    return true;
  }

  @override
  int get hashCode {
    return Object.hashAll(<Object>[
      for (final VideoControlSlot slot in VideoControlSlot.values) ...<Object>[
        slot,
        ..._slots[slot]!,
      ],
    ]);
  }
}

/// Drag payload for visual control-layout editors: the dragged
/// [VideoControlItem] plus the slot it came from ([sourceSlot] == null means it
/// was dragged from an "all buttons" palette, i.e. an add).
class VideoControlDragData {
  const VideoControlDragData({required this.item, required this.sourceSlot});

  final VideoControlItem item;
  final VideoControlSlot? sourceSlot;
}
