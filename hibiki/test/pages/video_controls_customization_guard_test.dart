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
    // TODO-399 decision 3b: the editor now exposes the FULL customizable button
    // set (learning + transport / nav keys), not just the five learning keys.
    expect(settings, contains('VideoControlItem.customizableItems'));
    // TODO-399 multi-slot: add (palette / drop) + delete (chip close button) via
    // addItemToSlot / removeItemFromSlot, so one button can sit in several slots.
    expect(settings, contains('addItemToSlot('));
    expect(settings, contains('removeItemFromSlot('));
    // All on-player slots + hidden are the user-facing drop regions, including
    // the bottom-center transport block (decision 2).
    expect(settings, contains('VideoControlSlot.bottomLeft'));
    expect(settings, contains('VideoControlSlot.bottomCenter'));
    expect(settings, contains('VideoControlSlot.bottomRight'));
    expect(settings, contains('VideoControlSlot.screenLeft'));
    expect(settings, contains('VideoControlSlot.screenRight'));
    expect(settings, contains('VideoControlSlot.topLeft'));
    expect(settings, contains('VideoControlSlot.topRight'));
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

    // TODO-378（BUG-287）：恢复「重播上一句」(videoReplayPreviousSubtitle / Shift+R)。
    // TODO-328 曾误当它与「上一句字幕」(videoPreviousSubtitle / Ctrl+←) 重复而删除，
    // 但两者语义不同：「重播上一句」走纯 skipToPrevCue（跳到上一条 cue 起点、不退化），
    // 「上一句字幕」gap 太远时按 BUG-185/TODO-085 退化时间 seek。守卫两个动作的全链路
    // 接线都在，且「重播上一句」用纯 skipToPrevCue（不退化），防止再次被合并/删除。
    expect(actions, contains('videoReplayPreviousSubtitle'));
    expect(defaults, contains('videoReplayPreviousSubtitle'));
    expect(shortcuts, contains('replayPreviousSubtitle'));
    expect(settings, contains('videoReplayPreviousSubtitle'));
    expect(page, contains('_replayPreviousCueAndPokeControls'));
    // 「重播上一句」必须是纯句子跳转（skipToPrevCue），不得退化成时间回退。
    expect(page, contains('skipToPrevCue();'));

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
    // TODO-270 E：制卡 cue/区间/文本解析收口到 _resolveVideoMiningRange；选中字幕仍
    // 优先（独立分支，不掺查词草稿），用其单段区间 + join 文本覆盖下一张卡上下文。
    expect(page, contains('if (selectedCue != null) {'),
        reason: '字幕列表多选优先覆盖制卡上下文（独立入口，不掺草稿）。');
    expect(page, contains('clipStartMs: selectedCue.startMs'));
    expect(page, contains('clipEndMs: selectedCue.endMs'));
    expect(page, contains('usedSelectedCue: true'));
    expect(page, contains('_lastLookupCue ??'));
    expect(page, contains('_mineVideoCard('));
    // TODO-270 D：清选中句以「制卡成功」信号 result.ankiConnect 为判据（两后端成功
    // 时都 true），不能用仅 AnkiConnect 非空的 note id，否则 AnkiDroid 成功也不清。
    // TODO-270 E：成功后按 usedSelectedCue 分流——多选清选中句、草稿路径清草稿。
    expect(page, contains('if (result.ankiConnect) {'));
    expect(page, contains('if (range.usedSelectedCue) {'));
    expect(page, contains('_clearSelectedMiningCues();'));
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
