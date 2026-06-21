import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

void main() {
  String read(String rel) => File(rel).readAsStringSync();

  // TODO-274/312 phase 2: persistence + editor moved from the legacy 3-tier
  // VideoControlCustomization to the 9-slot VideoControlLayout. The legacy pref
  // key is reused (auto-migrating old v1 blobs), so old configs upgrade losslessly.
  test('video page wires the persisted 9-slot control layout', () {
    final String page = readVideoHibikiSource();
    final String appModel = read('lib/src/models/app_model.dart');
    final String prefs = read('lib/src/models/preferences_repository.dart');

    expect(page,
        contains('ValueNotifier<VideoControlLayout> _controlLayoutNotifier'));
    expect(page, contains('VideoControlLayout get _controlLayout'));
    expect(page, contains('appModel.videoControlLayout'));
    expect(page, contains('_setVideoControlLayout'));
    expect(appModel, contains('videoControlLayout'));
    expect(appModel, contains('setVideoControlLayout'));
    // Same persisted key as the legacy model (v1 auto-migrates via decode).
    expect(prefs, contains('video_control_customization'));
    expect(prefs, contains('videoControlLayout'));
    expect(prefs, contains('setVideoControlLayout'));
  });

  test('quick settings owns the staged control drag editor', () {
    final String settings =
        read('lib/src/media/video/video_quick_settings_sheet.dart');

    expect(settings, contains('initialControlLayout'));
    expect(settings, contains('onControlLayoutChanged'));

    expect(settings, contains('_buildControlDragEditor'));
    expect(settings, contains('_buildControlStagePreview'));
    expect(settings, contains('DragTarget<VideoControlDragData>'));
    expect(settings, contains('Draggable<VideoControlDragData>'));
    expect(settings, contains('VideoControlSlot.hidden'));
    expect(settings, contains('Tooltip('));
    expect(settings, contains('Semantics('));
    expect(settings, isNot(contains('Icons.drag_indicator')));
  });

  test('quick settings editor does not depend on the onscreen overlay file',
      () {
    final String settings =
        read('lib/src/media/video/video_quick_settings_sheet.dart');

    expect(settings, isNot(contains('video_control_layout_edit_overlay.dart')));
    expect(settings, isNot(contains('VideoControlLayoutEditOverlay')));
    expect(settings, isNot(contains('t.video_control_edit_on_video')));
  });

  test('saved on-video layout notifies the active controls builder immediately',
      () {
    final String page = readVideoHibikiSource();
    final int setStart = page.indexOf('Future<void> _setVideoControlLayout');
    expect(setStart, greaterThanOrEqualTo(0));
    final int setEnd =
        page.indexOf('void _showVideoControlEditOverlay', setStart);
    expect(setEnd, greaterThan(setStart));
    final String setBody = page.substring(setStart, setEnd);

    expect(
      page,
      contains('ValueNotifier<VideoControlLayout> _controlLayoutNotifier'),
      reason: '全屏/controls builder 不能只靠页面 setState，必须监听当前布局 notifier',
    );
    expect(
      setBody,
      contains('_controlLayoutNotifier.value = layout;'),
      reason: '保存草稿后要先推进当前 controls builder 的监听源',
    );
    expect(
      page,
      contains('valueListenable: _controlLayoutNotifier'),
      reason: '当前控制层需要 ValueListenableBuilder 直接订阅布局变化',
    );
    expect(
      page,
      contains('_currentVideoControlsTheme(controller, layout)'),
      reason: 'controls builder 内要按最新 layout 重新提供 media_kit 控制主题',
    );
    expect(
      page,
      contains('layout: layout,'),
      reason: '画面上编辑 overlay 也应消费 notifier 的最新 layout',
    );
  });

  test(
      'editable item model includes all clickable chrome requested by TODO-452',
      () {
    final String model =
        read('lib/src/media/video/video_control_customization.dart');
    final int enumStart = model.indexOf('enum VideoControlItem {');
    expect(enumStart, greaterThanOrEqualTo(0));
    final int enumEnd =
        model.indexOf(';\n\n  const VideoControlItem', enumStart);
    expect(enumEnd, greaterThan(enumStart));
    final String enumBlock = model.substring(enumStart, enumEnd);

    for (final String item in <String>[
      'back',
      'immersiveLock',
      'episodeList',
      'previousEpisode',
      'nextEpisode',
      'chapterList',
      'previousChapter',
      'nextChapter',
      'subtitleTrack',
      'audioTrack',
      'screenshot',
      'fullscreen',
      'speed',
      'settings',
      'favoriteSentence',
      'subtitleList',
    ]) {
      expect(enumBlock, contains('$item('), reason: '$item must be editable');
    }

    final int customStart =
        model.indexOf('static List<VideoControlItem> get customizableItems');
    expect(customStart, greaterThanOrEqualTo(0));
    final int customEnd = model.indexOf('];', customStart);
    final String customBlock = model.substring(customStart, customEnd);
    expect(customBlock, isNot(contains('VideoControlItem.title')));
    expect(customBlock, isNot(contains('VideoControlItem.positionIndicator')));
    expect(customBlock, isNot(contains('VideoControlItem.volume')));
  });

  test('drag payload carries source index for same-slot reorder', () {
    final String model =
        read('lib/src/media/video/video_control_customization.dart');
    expect(model, contains('final int? sourceIndex'));
    expect(model, contains('VideoControlDragData({'));
    expect(model, contains('sourceIndex'));
  });

  test('player chrome includes right rail, bottom custom buttons and fallbacks',
      () {
    final String page = readVideoHibikiSource();

    expect(page, contains('_buildVideoSideActionRail(controller)'));
    expect(page, contains('Alignment.centerRight'));
    expect(page, contains('_bottomSlotButtons('));
    expect(page, contains('VideoControlButton.subtitleList'));
    expect(page, contains('_toggleSubtitleJumpList'));
    expect(page, contains('VideoControlButton.speed'));
    expect(page, contains('_showSpeedMenu'));
    expect(page, contains('_showPlayerSettings'));
  });

  test('translucent side panel replaces blocking modal player menus', () {
    final String page = readVideoHibikiSource();

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
    // TODO-590 batch9：_showAudioTrackMenu 已抽到 video_hibiki/audio_track.part.dart
    // （合并语料末段），其紧邻后继在 part 内是 _buildAudioTracksSidePanel，改用它作终点。
    final String audioMenu = body(
      'void _showAudioTrackMenu',
      'Widget _buildAudioTracksSidePanel(',
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

  test('TODO-476 side panel launchers preserve the source slot side', () {
    final String page = readVideoHibikiSource();

    String body(String start, String end) {
      final int startIndex = page.indexOf(start);
      expect(startIndex, greaterThanOrEqualTo(0), reason: start);
      final int endIndex = page.indexOf(end, startIndex);
      expect(endIndex, greaterThan(startIndex), reason: end);
      return page.substring(startIndex, endIndex);
    }

    expect(page, contains('class _VideoSidePanelState'));
    expect(page, contains('final _VideoSidePanelKind kind;'));
    expect(page, contains('final Alignment alignment;'));
    expect(
        page, contains('ValueNotifier<_VideoSidePanelState?> _videoSidePanel'));
    expect(page, contains('_sidePanelAlignmentForSlot(sourceSlot)'));

    final String bottomButton = body(
      'Widget _buildBottomSlotButton(',
      'Widget _plainSlotButton(',
    );
    expect(
      bottomButton,
      contains(
          '_plainSlotButton(item, controller, desktop: desktop, slot: slot)'),
      reason: 'bottom left/right/center slots must preserve their source slot',
    );

    final String plainSlot = body(
      'Widget _plainSlotButton(',
      'bool _shouldRenderControlItem',
    );
    expect(plainSlot, contains('required VideoControlSlot slot'));
    expect(plainSlot, contains('sourceSlot: slot'));

    final String topSlot = body(
      'Widget _topBarSlotGroup(',
      'String get _clipExportTooltip',
    );
    expect(topSlot, contains('sourceSlot: slot'),
        reason: 'topLeft/topRight buttons must open panels on their own side');

    final String legacyButton = body(
      'Widget _buildVideoControlButton(',
      'IconData _videoControlButtonIcon',
    );
    expect(legacyButton, contains('required VideoControlSlot slot'));
    expect(legacyButton, contains('sourceSlot: slot'),
        reason: 'legacy learning buttons must not drop the slot');

    final String activateItem = body(
      'void _activateVideoControlItem(',
      '/// 底栏传输组',
    );
    expect(activateItem, contains('VideoControlSlot? sourceSlot'));
    expect(activateItem, contains('sourceSlot: sourceSlot'));
    expect(activateItem,
        contains('_showAudioTrackMenu(controller, sourceSlot: sourceSlot)'));
    expect(activateItem,
        contains('_showChapterPanel(controller, sourceSlot: sourceSlot)'));

    final String activateLegacy = body(
      'void _activateVideoControlButton(',
      'bool _hasRoomyVideoBottomBar',
    );
    expect(activateLegacy, contains('VideoControlSlot? sourceSlot'));
    expect(activateLegacy,
        contains('_showPlayerSettings(sourceSlot: sourceSlot)'));

    final String sideRail = body(
      'Widget _buildVideoSideRailFor(',
      '/// 把 [video]',
    );
    expect(sideRail, contains('sourceSlot: slot'),
        reason: 'screenLeft/screenRight rail buttons must preserve side');

    // TODO-590 batch10：_buildVideoSidePanelContent 已抽到 video_hibiki/side_panel.part.dart
    // 并是该 part 的末方法；旧的 _handlePlaybackDrop 终点失效（它在主壳前段，排在搬出后的
    // content 之前）。改用 part 顶格 extension 闭合 `\n}` 作终点（content 体内无顶格 `}`）。
    final String content = body(
      'Widget _buildVideoSidePanelContent(',
      '\n}',
    );
    expect(content, contains('alignment: panelState.alignment'));
  });

  test('video shortcuts reach real favorite and replay actions', () {
    final String actions = read('lib/src/shortcuts/shortcut_action.dart');
    final String defaults = read('lib/src/shortcuts/shortcut_defaults.dart');
    final String shortcuts =
        read('lib/src/media/video/video_player_shortcuts.dart');
    final String settings =
        read('lib/src/pages/implementations/shortcut_settings_page.dart');
    final String page = readVideoHibikiSource();

    for (final String action in <String>[
      'videoToggleFavoriteSentence',
      'videoReplayCurrentSubtitle',
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
  });

  test('TODO-258 subtitle sidebar filters and checkbox selection are wired',
      () {
    final String panel =
        read('lib/src/media/video/video_subtitle_jump_panel.dart');
    final String page = readVideoHibikiSource();

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
    final String page = readVideoHibikiSource();

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
    // TODO-680/BUG-392：选中 cue 的时间在裁音频/封面前经 miningClipTimeMs(...delayMs)
    // 逆变换回播放器轴，故守卫断言随源同步收紧（仍锁「选中 cue 驱动制卡区间」语义）。
    expect(page, contains('clipStartMs: miningClipTimeMs(selectedCue.startMs'));
    expect(page, contains('clipEndMs: miningClipTimeMs(selectedCue.endMs'));
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
    final String page = readVideoHibikiSource();

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
    final String page = readVideoHibikiSource();
    final int mineStart =
        page.indexOf('Future<MinePopupResult> _mineVideoCard');
    // TODO-590 batch9：_showAudioTrackMenu 已抽到 audio_track.part.dart（合并语料末段），
    // 不能再当 _mineVideoCard 之后的紧邻终点；改用主壳里真实后继 _handleBackOrExit。
    final int mineEnd =
        page.indexOf('Future<void> _handleBackOrExit', mineStart);
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
