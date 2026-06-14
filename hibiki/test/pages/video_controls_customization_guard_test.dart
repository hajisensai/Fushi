import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String rel) => File(rel).readAsStringSync();

  // TODO-274/312 phase 2: persistence + editor moved from the legacy 3-tier
  // VideoControlCustomization to the 9-slot VideoControlLayout. The legacy pref
  // key is reused (auto-migrating old v1 blobs), so old configs upgrade losslessly.
  test('video page wires the persisted 9-slot control layout', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');
    final String appModel = read('lib/src/models/app_model.dart');
    final String prefs = read('lib/src/models/preferences_repository.dart');

    expect(page, contains('VideoControlLayout _controlLayout'));
    expect(page, contains('appModel.videoControlLayout'));
    expect(page, contains('_setVideoControlLayout'));
    expect(appModel, contains('videoControlLayout'));
    expect(appModel, contains('setVideoControlLayout'));
    // Same persisted key as the legacy model (v1 auto-migrates via decode).
    expect(prefs, contains('video_control_customization'));
    expect(prefs, contains('videoControlLayout'));
    expect(prefs, contains('setVideoControlLayout'));
  });

  test('quick settings exposes the 9-slot control placement editor', () {
    final String settings =
        read('lib/src/media/video/video_quick_settings_sheet.dart');

    expect(settings, contains('initialControlLayout'));
    expect(settings, contains('onControlLayoutChanged'));
    // Editor iterates the customizable learning items and offers slot choices.
    expect(settings, contains('VideoControlItem.customizableLearning'));
    expect(settings, contains('VideoControlSlot.editableSlots'));
    expect(settings, contains('_controlLayout.moveItem('));
    // The four on-player slots + hidden are the user-facing choices.
    expect(settings, contains('VideoControlSlot.bottomLeft'));
    expect(settings, contains('VideoControlSlot.bottomRight'));
    expect(settings, contains('VideoControlSlot.screenLeft'));
    expect(settings, contains('VideoControlSlot.screenRight'));
    expect(settings, contains('VideoControlSlot.hidden'));
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
    expect(page, contains('_VideoSidePanelKind.subtitleSources'));
    expect(page, contains('_VideoSidePanelKind.audioTracks'));

    String body(String start, String end) {
      final int startIndex = page.indexOf(start);
      expect(startIndex, greaterThanOrEqualTo(0), reason: start);
      final int endIndex = page.indexOf(end, startIndex);
      expect(endIndex, greaterThan(startIndex), reason: end);
      return page.substring(startIndex, endIndex);
    }

    final String subtitleMenu = body(
      'Future<void> _showSubtitleSourceMenu',
      'Future<void> _openJimakuDialog',
    );
    final String audioMenu = body(
      'void _showAudioTrackMenu',
      'Future<void> _handleBackOrExit',
    );
    final String subtitleLoading = body(
      'void _showSubtitleLoadingOverlay',
      '/// 选中某字幕源',
    );

    expect(subtitleMenu, isNot(contains('showModalBottomSheet')));
    expect(audioMenu, isNot(contains('showModalBottomSheet')));
    expect(subtitleLoading, isNot(contains('showDialog')));
    expect(subtitleLoading, isNot(contains('Navigator.of')));
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
      'videoShowFavoriteSentences',
    ]) {
      expect(actions, contains(action));
      expect(defaults, contains(action));
      expect(shortcuts, contains(action));
      expect(settings, contains(action));
    }

    // TODO-328：移除「重播上一句」(videoReplayPreviousSubtitle / Shift+R)。它与逐句
    // 导航「上一句」(videoPreviousSubtitle) 行为重复，用户决定只保留逐句导航且不要
    // 退化回退。守卫这两个符号确实从所有快捷键层与页面回调中消失，防止回归。
    expect(actions, isNot(contains('videoReplayPreviousSubtitle')));
    expect(defaults, isNot(contains('videoReplayPreviousSubtitle')));
    expect(shortcuts, isNot(contains('replayPreviousSubtitle')));
    expect(settings, isNot(contains('videoReplayPreviousSubtitle')));
    expect(page, isNot(contains('_replayPreviousCueAndPokeControls')));

    expect(page, contains('_toggleFavoriteCurrentCue'));
    expect(page, contains('_replayCurrentCueAndPokeControls'));
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
    // TODO-270 D：清选中句以「制卡成功」信号 result.ankiConnect 为判据（两后端成功
    // 时都 true），不能用仅 AnkiConnect 非空的 note id，否则 AnkiDroid 成功也不清。
    expect(page, contains('if (usedSelectedCue && result.ankiConnect)'));
  });

  test('TODO-266 integrated subtitle sidebar keeps playback and card semantics',
      () {
    final String panel =
        read('lib/src/media/video/video_subtitle_jump_panel.dart');
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    expect(panel, contains('SegmentedButton<VideoSubtitleListFilter>'));
    expect(panel, contains('VideoSubtitleListFilter.all'));
    expect(panel, contains('VideoSubtitleListFilter.favorites'));
    expect(panel, contains('VideoSubtitleListFilter.selected'));
    expect(panel, contains('onTap: () => widget.onTapCue(cue)'));
    expect(panel, contains('Checkbox('));
    expect(
      panel,
      contains('onChanged: (_) => widget.onToggleCueSelection?.call(cue)'),
    );

    expect(page, contains('void _handleSubtitleJumpTap(AudioCue cue)'));
    expect(page, contains('_controller?.skipToCue(cue)'));
    expect(page, contains('_lastLookupCue = controller.currentCue ??'));
    expect(page, contains('buildSelectedSubtitleCueContext'));
    expect(page, contains('rawPayloadJson: jsonEncode(fields)'));
  });

  test(
      'TODO-266 playback preview and auto-read do not gate Anki sentence audio',
      () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');
    final int mineStart =
        page.indexOf('Future<MinePopupResult> _mineVideoCard');
    final int mineEnd = page.indexOf('void _showAudioTrackMenu', mineStart);
    expect(mineStart, greaterThanOrEqualTo(0));
    expect(mineEnd, greaterThan(mineStart));
    final String mineBody = page.substring(mineStart, mineEnd);

    expect(mineBody, contains('extractAudioSegmentViaFfmpeg'));
    expect(mineBody, contains('sasayakiAudioPath: audioPath'));
    expect(mineBody, contains('repo.mineEntry('));
    expect(mineBody, isNot(contains('autoRead')));
    expect(mineBody, isNot(contains('_pausedForLookup')));
  });
}
