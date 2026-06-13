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
