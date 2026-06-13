import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String rel) => File(rel).readAsStringSync();

  test('video page wires persisted player control customization', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');
    final String appModel = read('lib/src/models/app_model.dart');
    final String prefs = read('lib/src/models/preferences_repository.dart');

    expect(page, contains('VideoControlCustomization _controlCustomization'));
    expect(page, contains('appModel.videoControlCustomization'));
    expect(page, contains('_setVideoControlCustomization'));
    expect(appModel, contains('videoControlCustomization'));
    expect(appModel, contains('setVideoControlCustomization'));
    expect(prefs, contains('video_control_customization'));
  });

  test('quick settings exposes control placement customization', () {
    final String settings =
        read('lib/src/media/video/video_quick_settings_sheet.dart');

    expect(settings, contains('initialControlCustomization'));
    expect(settings, contains('onControlCustomizationChanged'));
    expect(settings, contains('VideoControlButton.speed'));
    expect(settings, contains('VideoControlButton.subtitleList'));
    expect(settings, contains('VideoControlPlacement.bottom'));
    expect(settings, contains('VideoControlPlacement.rightRail'));
    expect(settings, contains('VideoControlPlacement.settingsOnly'));
  });

  test('player chrome includes right rail, bottom custom buttons and fallbacks',
      () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    expect(page, contains('_buildVideoSideActionRail(controller)'));
    expect(page, contains('Alignment.centerRight'));
    expect(page, contains('_customBottomControlButtons(controller'));
    expect(page, contains('VideoControlButton.subtitleList'));
    expect(page, contains('_toggleSubtitleJumpList'));
    expect(page, contains('VideoControlButton.speed'));
    expect(page, contains('_showSpeedMenu'));
    expect(page, contains('_showPlayerSettings'));
    expect(page, contains('_showFavoriteSentencesPanel'));
  });

  test('translucent side panel replaces blocking modal player menus', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    expect(page, contains('video_side_panel.dart'));
    expect(page, contains('VideoTranslucentSidePanel'));
    expect(page, contains('_showVideoSidePanel'));
    expect(page, contains('Positioned.fill'));
    expect(page, contains('_buildVideoSidePanelOverlay'));
  });

  test('video shortcuts reach real favorite and replay actions', () {
    final String actions = read('lib/src/shortcuts/shortcut_action.dart');
    final String defaults = read('lib/src/shortcuts/shortcut_defaults.dart');
    final String shortcuts =
        read('lib/src/media/video/video_player_shortcuts.dart');
    final String settings =
        read('lib/src/pages/implementations/shortcut_settings_page.dart');
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    for (final String action in <String>[
      'videoToggleFavoriteSentence',
      'videoReplayCurrentSubtitle',
      'videoReplayPreviousSubtitle',
      'videoShowFavoriteSentences',
    ]) {
      expect(actions, contains(action));
      expect(defaults, contains(action));
      expect(shortcuts, contains(action));
      expect(settings, contains(action));
    }

    expect(page, contains('_toggleFavoriteCurrentCue'));
    expect(page, contains('_replayCurrentCueAndPokeControls'));
    expect(page, contains('_replayPreviousCueAndPokeControls'));
    expect(page, contains('_showFavoriteSentencesPanel'));
  });

  test('TODO-258 subtitle sidebar filters and checkbox selection are wired',
      () {
    final String panel =
        read('lib/src/media/video/video_subtitle_jump_panel.dart');
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    expect(panel, contains('enum VideoSubtitleListFilter'));
    expect(panel, contains('VideoSubtitleListFilter.all'));
    expect(panel, contains('VideoSubtitleListFilter.favorites'));
    expect(panel, contains('VideoSubtitleListFilter.selected'));
    expect(panel, contains('onToggleCueSelection'));
    expect(panel, contains('isCueSelectedForCard'));
    expect(panel, contains('Checkbox('));
    expect(panel, contains('onTap: () => widget.onTapCue(cue)'));

    expect(page, contains('onToggleCueSelection: _toggleCueSelectedForCard'));
    expect(page, contains('isCueSelectedForCard: _isCueSelectedForCard'));
  });

  test('TODO-258 selected subtitles only override next card media context', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    expect(page, contains('_selectedMiningCueStarts'));
    expect(page, contains('_selectedMiningCueForCard'));
    expect(
      page,
      contains(
        'final AudioCue? selectedCue = _selectedMiningCueForCard(controller);',
      ),
    );
    expect(page, contains('final AudioCue? cue = selectedCue ??'));
    expect(page, contains('_lastLookupCue ??'));
    expect(page, contains('_mineVideoCard('));
    expect(page, contains('cueSentence: cue?.text'));
    expect(page, contains('clipStartMs: cue?.startMs ?? 0'));
    expect(page, contains('clipEndMs: cue?.endMs ?? 0'));
    expect(page, contains('if (usedSelectedCue && mined)'));
  });
}
