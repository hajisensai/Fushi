import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';

/// TODO-274 / TODO-312 phase 1: the control bar renderer is now data-driven over
/// the 9-slot [VideoControlLayout] (derived from the persisted legacy
/// [VideoControlCustomization] via [VideoControlLayout.fromLegacy]) instead of
/// reading the legacy 3-tier placements directly.
///
/// This guard pins the **pixel-equivalence contract**: for the default config
/// (and any legacy config), the buttons the new renderer pulls per slot must be
/// the exact same ordered set the old `buttonsFor(...)` lookups produced. If
/// this drifts, the chrome moves → not pixel-identical.
///
/// The media_kit control bar itself can't render headless, so the structural
/// equivalence of the rendered tree is covered by the existing source guards
/// (video_bottom_bar_tooltips / video_play_center_seek_labels /
/// video_controls_customization / video_volume_and_settings_dedupe /
/// video_single_top_bar / video_mobile_controls_static). Here we lock the
/// data-layer mapping the renderer consumes.
void main() {
  /// Learning-key subset of a slot, in render order: iterate the slot's ordered
  /// items and keep the ones that map back to a legacy [VideoControlButton].
  List<VideoControlButton> slotLearningButtons(
    VideoControlLayout layout,
    VideoControlSlot slot,
  ) {
    return <VideoControlButton>[
      for (final VideoControlItem item in layout.itemsIn(slot))
        if (item.legacyButton != null) item.legacyButton!,
    ];
  }

  group('default config: slot renderer == legacy chrome (pixel-equivalent)',
      () {
    final VideoControlLayout layout =
        VideoControlLayout.fromLegacy(VideoControlCustomization.defaults);

    test('bottomRight learning keys == legacy buttonsFor(bottom) == [speed]',
        () {
      final List<VideoControlButton> fromSlot =
          slotLearningButtons(layout, VideoControlSlot.bottomRight);
      final List<VideoControlButton> fromLegacy = VideoControlCustomization
          .defaults
          .buttonsFor(VideoControlPlacement.bottom);
      expect(fromSlot, fromLegacy);
      expect(fromSlot, <VideoControlButton>[VideoControlButton.speed]);
    });

    test('screenRight learning keys == legacy buttonsFor(rightRail) (4 keys)',
        () {
      final List<VideoControlButton> fromSlot =
          slotLearningButtons(layout, VideoControlSlot.screenRight);
      final List<VideoControlButton> fromLegacy = VideoControlCustomization
          .defaults
          .buttonsFor(VideoControlPlacement.rightRail);
      expect(fromSlot, fromLegacy);
      expect(fromSlot, <VideoControlButton>[
        VideoControlButton.subtitleList,
        VideoControlButton.favoriteSentence,
        VideoControlButton.favoriteSentences,
        VideoControlButton.settings,
      ]);
    });

    test('currentChrome itself is what the default derivation resolves to', () {
      // The default legacy config derives to the exact pixel-equivalent layout
      // for the learning keys; the fixed transport/nav keys keep currentChrome.
      expect(
          slotLearningButtons(layout, VideoControlSlot.bottomRight),
          slotLearningButtons(
              VideoControlLayout.currentChrome, VideoControlSlot.bottomRight));
      expect(
          slotLearningButtons(layout, VideoControlSlot.screenRight),
          slotLearningButtons(
              VideoControlLayout.currentChrome, VideoControlSlot.screenRight));
    });
  });

  group('arbitrary legacy config: slot renderer tracks placement losslessly',
      () {
    // Move speed to rightRail and subtitleList to bottom; renderer must follow.
    VideoControlCustomization custom = VideoControlCustomization.defaults
        .copyWithPlacement(
            VideoControlButton.speed, VideoControlPlacement.rightRail)
        .copyWithPlacement(
            VideoControlButton.subtitleList, VideoControlPlacement.bottom)
        .copyWithPlacement(VideoControlButton.favoriteSentence,
            VideoControlPlacement.settingsOnly);
    final VideoControlLayout layout = VideoControlLayout.fromLegacy(custom);

    test('every slot learning subset equals the legacy placement lookup', () {
      for (final MapEntry<VideoControlSlot, VideoControlPlacement> pair
          in <VideoControlSlot, VideoControlPlacement>{
        VideoControlSlot.bottomRight: VideoControlPlacement.bottom,
        VideoControlSlot.screenRight: VideoControlPlacement.rightRail,
        VideoControlSlot.hidden: VideoControlPlacement.settingsOnly,
      }.entries) {
        expect(
          slotLearningButtons(layout, pair.key),
          custom.buttonsFor(pair.value),
          reason: 'slot ${pair.key.name} must equal legacy ${pair.value.name}',
        );
      }
    });

    test('moved-to-hidden learning key drops off the player slots', () {
      expect(
        slotLearningButtons(layout, VideoControlSlot.screenRight),
        isNot(contains(VideoControlButton.favoriteSentence)),
      );
      expect(
        slotLearningButtons(layout, VideoControlSlot.hidden),
        contains(VideoControlButton.favoriteSentence),
      );
    });
  });

  group('page wires the slot renderer (data-driven, not legacy buttonsFor)',
      () {
    final File page = File(
      'lib/src/pages/implementations/video_hibiki_page.dart',
    );
    late String src;
    setUpAll(() {
      expect(page.existsSync(), isTrue);
      src = page.readAsStringSync();
    });

    test('control bar reads the persisted VideoControlLayout (phase 2)', () {
      // Phase 2: _controlLayout is now a persisted field (the v2 source of
      // truth), loaded from AppModel.videoControlLayout, not derived read-only
      // from the legacy customization.
      expect(src,
          contains('ValueNotifier<VideoControlLayout> _controlLayoutNotifier'));
      expect(
          src,
          contains(
              'VideoControlLayout get _controlLayout => _controlLayoutNotifier.value'));
      expect(
          src,
          contains(
              '_controlLayoutNotifier.value = appModel.videoControlLayout'));
      expect(src, contains('ValueListenableBuilder<VideoControlLayout>'));
      expect(src, contains('valueListenable: _controlLayoutNotifier'));
      expect(src, contains('_currentVideoControlsTheme(controller, layout)'));
      expect(src, contains('appModel.setVideoControlLayout(layout)'));
      // The phase-1 read-only derivation is gone.
      expect(
          src,
          isNot(contains(
              'VideoControlLayout.fromLegacy(_controlCustomization)')));
    });

    test('customizable render points go through slot-driven item helpers', () {
      expect(src, contains('List<VideoControlItem> _slotChipItems('));
      // Top bar, bottom bar, and screen rails all resolve from slots.
      expect(
          RegExp(r'_topBarSlotGroup\(\s*VideoControlSlot\.topLeft')
              .hasMatch(src),
          isTrue);
      expect(
          RegExp(r'_topBarSlotGroup\(\s*VideoControlSlot\.topRight')
              .hasMatch(src),
          isTrue);
      expect(src, isNot(contains('_topBarSlotButtons(')));
      expect(src, contains('_bottomSlotButtons('));
      expect(src, contains('VideoControlSlot.bottomLeft'));
      expect(src, contains('VideoControlSlot.bottomRight'));
      expect(src, contains('VideoControlSlot.bottomCenter'));
      expect(src, contains('_buildVideoSideRailFor('));
      expect(src, contains('VideoControlSlot.screenLeft'));
      expect(src, contains('VideoControlSlot.screenRight'));
      // Legacy direct placement lookups removed from the render path.
      expect(src, isNot(contains('buttonsFor(VideoControlPlacement.bottom)')));
      expect(
          src, isNot(contains('buttonsFor(VideoControlPlacement.rightRail)')));
    });
  });
}
