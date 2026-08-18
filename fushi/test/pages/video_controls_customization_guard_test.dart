import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'video_fushi_page_source_corpus.dart';

void main() {
  String read(String rel) => File(rel).readAsStringSync();

  // TODO-274/312 phase 2: persistence + editor moved from the legacy 3-tier
  // VideoControlCustomization to the 9-slot VideoControlLayout. The legacy pref
  // key is reused (auto-migrating old v1 blobs), so old configs upgrade losslessly.
  test('video page wires the persisted 9-slot control layout', () {
    final String page = readVideoFushiSource();
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

  // 阶段B：_buildControlDragEditor 系列从 sheet 原样抽为独立控件
  // VideoControlLayoutEditor（video_control_layout_editor.dart），以 schema 的
  // 'video.player.controls_editor' 自定义项接入面板；守卫改锁新位置。
  // initialControlLayout 参数已删——布局改经 `layout` + didUpdateWidget 同步，
  // host 侧是 controlLayout() getter。
  test('the staged control drag editor lives in its own schema-wired widget',
      () {
    final String editor =
        read('lib/src/media/video/video_control_layout_editor.dart');

    expect(editor, contains('class VideoControlLayoutEditor'));
    expect(editor, contains('final VideoControlLayout layout;'));
    expect(editor, contains('onLayoutChanged'));
    expect(editor, isNot(contains('initialControlLayout')),
        reason: '外部布局改经 layout + didUpdateWidget 同步（重置行是并列 schema action）');
    expect(editor, contains('didUpdateWidget'));

    expect(editor, contains('_buildControlStagePreview'));
    expect(editor, contains('DragTarget<VideoControlDragData>'));
    expect(editor, contains('Draggable<VideoControlDragData>'));
    expect(editor, contains('VideoControlSlot.hidden'));
    expect(editor, contains('Tooltip('));
    expect(editor, contains('Semantics('));
    expect(editor, isNot(contains('Icons.drag_indicator')));

    // schema 声明编辑器行，actions builder 把 host 权威布局 + 回调接进编辑器。
    final String schema = read('lib/src/settings/settings_schema_video.dart');
    expect(schema, contains("id: 'video.player.controls_editor'"));
    expect(schema, contains('buildVideoControlLayoutEditor'));
    final String actions =
        read('lib/src/media/video/video_settings_actions.dart');
    expect(actions, contains('layout: host.controlLayout()'));
    expect(actions, contains('onLayoutChanged: host.onControlLayoutChanged'));
  });

  test('control layout editor does not depend on the onscreen overlay file',
      () {
    final String editor =
        read('lib/src/media/video/video_control_layout_editor.dart');

    expect(editor, isNot(contains('video_control_layout_edit_overlay.dart')));
    expect(editor, isNot(contains('VideoControlLayoutEditOverlay')));
    expect(editor, isNot(contains('t.video_control_edit_on_video')));
  });

  test('saved on-video layout notifies the active controls builder immediately',
      () {
    final String page = readVideoFushiSource();
    final int setStart = page.indexOf('Future<void> _setVideoControlLayout');
    expect(setStart, greaterThanOrEqualTo(0));
    // 阶段B：死代码 _showVideoControlEditOverlay 已删（旧面板从未渲染其入口），
    // _setVideoControlLayout 的紧邻后继改为仍在用的 _hideVideoControlEditOverlay。
    final int setEnd =
        page.indexOf('void _hideVideoControlEditOverlay', setStart);
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
    // BUG-391 r4/r5（提交 1fc54c75a）：控制条 builder 从单一
    // `ValueListenableBuilder<VideoControlLayout>` 升级为
    // `ListenableBuilder + Listenable.merge([_controlLayoutNotifier, _subtitleListVisible,
    // _episodeListVisible])`，builder 内重读 `_controlLayoutNotifier.value`——既保留对布局
    // 变化的直接订阅，又把 push-aside 列表可见性并入（hideMouseOnControlsRemoval 依赖它们）。
    // 故契约从「valueListenable: _controlLayoutNotifier」收紧为「merge 列表含
    // _controlLayoutNotifier 且 builder 重读其 value」。
    expect(
      page,
      contains('_controlLayoutNotifier,'),
      reason: '当前控制层的 Listenable.merge 必须含 _controlLayoutNotifier（直接订阅布局变化）',
    );
    expect(
      page,
      contains(
          'final VideoControlLayout layout = _controlLayoutNotifier.value;'),
      reason: 'builder 内必须重读 _controlLayoutNotifier 的当前布局值',
    );
    expect(
      page,
      contains('_currentVideoControlsTheme(controller, layout)'),
      reason: 'controls builder 内要按最新 layout 重新提供 media_kit 控制主题',
    );
    expect(
      page,
      contains('layout: layout,'),
      reason: 'controls 主题/布局消费方也应消费 notifier 的最新 layout'
          '（阶段B：画面上编辑 overlay 已删，消费点在 controls_theme/layout part）',
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
    final String page = readVideoFushiSource();

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
    final String page = readVideoFushiSource();

    expect(page, contains('video_side_panel.dart'));
    expect(page, contains('VideoTranslucentSidePanel'));
    expect(page, contains('_showVideoSidePanel'));
    expect(page, contains('Positioned.fill'));
    expect(page, contains('_buildVideoSidePanelOverlay'));
    // TODO-1351：音轨/字幕轨切换从「外面浮的轨切换侧栏」收进设置面板对应 tab，
    // audioTracks / subtitleSources 两个浮动 kind 已删；轨切换仍走半透明 side-panel 系统
    // （设置面板本身就是一个 side-panel），故上面的通用 side-panel 不变量仍成立。
    expect(page, isNot(contains('_VideoSidePanelKind.subtitleSources')));
    expect(page, isNot(contains('_VideoSidePanelKind.audioTracks')));

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
    // TODO-590 batch9：_showAudioTrackMenu 已抽到 video_fushi/audio_track.part.dart。
    // TODO-1351：其紧邻后继改为 _buildAudioTrackSettingsSection（设置面板「音频」分类的
    // 音轨切换区），改用它作终点。
    final String audioMenu = body(
      'void _showAudioTrackMenu',
      'Widget _buildAudioTrackSettingsSection(',
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
    final String page = readVideoFushiSource();

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

    // TODO-590 batch10：_buildVideoSidePanelContent 已抽到 video_fushi/side_panel.part.dart
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
    // Action display labels moved from the settings page into the shared
    // shortcut_labels extensions (shortcut settings refactor); the settings
    // page renders every action via `action.label`, so labels-file coverage is
    // what proves the tile can render these actions.
    final String settings = read('lib/src/shortcuts/shortcut_labels.dart');
    final String page = readVideoFushiSource();

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

  test('TODO-258 subtitle sidebar filters are wired', () {
    final String panel =
        read('lib/src/media/video/video_subtitle_jump_panel.dart');

    expect(panel, contains('enum VideoSubtitleListFilter'));
    expect(panel, contains('VideoSubtitleListFilter.all'));
    expect(panel, contains('VideoSubtitleListFilter.favorites'));
    expect(panel, contains('onTap: () => widget.onTapCue(cue)'));
    // 「选入制卡」勾选框已整条移除（连同已选档 / 清空选择 / 制卡多选分支）：行内不得
    // 再出现勾选框，否则字幕列表又多一列占宽的控件。
    expect(panel, isNot(contains('Checkbox(')));
    expect(panel, isNot(contains('VideoSubtitleListFilter.selected')));
  });

  test('字幕列表多选制卡整条链路已移除，制卡上下文只剩查词草稿一条路径', () {
    final String page = readVideoFushiSource();

    // 「选入制卡」勾选框删除后，页面侧的多选状态 / 合成 cue / 清多选副作用都必须一并
    // 消失，否则留下永远无入口的死代码。
    expect(page, isNot(contains('_selectedMiningCueStarts')));
    expect(page, isNot(contains('_selectedMiningCueForCard')));
    expect(page, isNot(contains('_clearSelectedMiningCues')));
    expect(page, isNot(contains('buildSelectedSubtitleCueContext')));
    expect(page, isNot(contains('usedSelectedCue')));

    // TODO-270 E：制卡 cue/区间/文本解析仍收口在 _resolveVideoMiningRange，只是分支
    // 从「多选优先 / 否则草稿」收敛为草稿单路径。
    expect(
        page,
        contains(
            '}) _resolveVideoMiningRange(VideoPlayerController controller) {'));
    // TODO-680/BUG-392：两端点在裁音频/封面前都经 miningClipTimeMs(...clipDelayMs)
    // 逆变换回播放器轴（dart format 会把 clipEndMs 的调用换行，故按实参锚定）。
    expect(page, contains('miningClipTimeMs('));
    expect(page,
        contains('mergedRange?.startMs ?? cue?.startMs ?? 0, clipDelayMs)'));
    expect(
        page, contains('mergedRange?.endMs ?? cue?.endMs ?? 0, clipDelayMs)'));
    expect(page, contains('_lastLookupCue ??'));
    expect(page, contains('_mineVideoCard('));
    // TODO-270 D：清草稿以「制卡成功」信号 result.ankiConnect 为判据（两后端成功时都
    // true），不能用仅 AnkiConnect 非空的 note id，否则 AnkiDroid 成功也不清。
    expect(page, contains('if (result.ankiConnect) {'));
    expect(page, contains('_miningDraft.clear();'));
  });

  test('TODO-266 integrated subtitle sidebar keeps playback and card semantics',
      () {
    final String panel =
        read('lib/src/media/video/video_subtitle_jump_panel.dart');
    final String page = readVideoFushiSource();

    expect(panel, contains('SegmentedButton<VideoSubtitleListFilter>'));
    expect(panel, contains('VideoSubtitleListFilter.all'));
    expect(panel, contains('VideoSubtitleListFilter.favorites'));
    expect(panel, contains('onTap: () => widget.onTapCue(cue)'));

    expect(page, contains('void _handleSubtitleJumpTap(AudioCue cue)'));
    expect(page, contains('_controller?.skipToCue(cue)'));
    // BUG-966: 锚定 cue 解析收口到纯函数 resolveVideoLookupAnchorCue（currentCue 仍是默认）。
    expect(page, contains('_lastLookupCue = resolveVideoLookupAnchorCue('));
    expect(page, contains('currentCue: controller.currentCue'));
    // TODO-1000: the raw-payload assembly moved out of the video shell into the
    // shared ImmersionMiningEngine (fields carried on the request), so the card
    // still lands from the resolved cue context via repo.mineEntry — assert it in
    // the engine source now (jsonEncode(req.fields)). Same invariant, new home.
    final String engine = readImmersionMiningEngineSource();
    expect(engine, contains('rawPayloadJson: jsonEncode(req.fields)'));
  });

  test(
      'TODO-266 playback preview and auto-read do not gate Anki sentence audio',
      () {
    final String page = readVideoFushiSource();
    final int mineStart =
        page.indexOf('Future<MinePopupResult> _mineVideoCard');
    // TODO-590 batch14：_mineVideoCard 已随制卡域抽到 lookup_mining.part.dart（合并语料
    // 末段），其后紧邻 _recordMinedSentenceForVideo；主壳的 _handleBackOrExit 现排在
    // part 之前会切片失败，改用 part 内真实后继 _recordMinedSentenceForVideo 作终点。
    final int mineEnd =
        page.indexOf('Future<void> _recordMinedSentenceForVideo', mineStart);
    expect(mineStart, greaterThanOrEqualTo(0));
    expect(mineEnd, greaterThan(mineStart));
    final String mineBody = page.substring(mineStart, mineEnd);

    // TODO-1000: the media-degradation ladder / audio extraction / no-audio abort
    // / AnkiMiningContext assembly moved out of _mineVideoCard into the shared
    // ImmersionMiningEngine (_mineVideoCard now delegates to it). The extractor +
    // sentence-audio wiring + card landing are asserted in the engine source now;
    // the shell shim only keeps OSD/stats — but the negative invariant (mining
    // sentence audio is NOT gated on playback preview / auto-read state) is a
    // property of the shell shim, so those stay asserted on the shell slice.
    final String engine = readImmersionMiningEngineSource();
    expect(engine, contains('extractAudioSegmentViaFfmpeg'));
    expect(engine, contains('sentenceAudioPath: audioPath'));
    expect(engine, contains('repo.mineEntry('));
    expect(mineBody, contains('ImmersionMiningEngine().mine('));
    expect(mineBody, isNot(contains('autoRead')));
    expect(mineBody, isNot(contains('_pausedForLookup')));
  });
}
