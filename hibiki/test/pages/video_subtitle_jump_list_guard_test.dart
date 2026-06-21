import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';
import 'video_hibiki_page_source_corpus.dart';

void main() {
  final String src = readVideoHibikiSource();
  final String shortcuts =
      File('lib/src/media/video/video_player_shortcuts.dart')
          .readAsStringSync();

  test('字幕列表走 push-aside（把画面挤左），不再 overlay 浮层遮挡也不回旧阻塞弹窗（TODO-314）', () {
    final int toggleIdx = src.indexOf('void _toggleSubtitleJumpList()');
    final int nextHandlerIdx =
        src.indexOf('void _handleSubtitleJumpTap', toggleIdx);
    final String toggleBody = src.substring(toggleIdx, nextHandlerIdx);

    // push-aside 由 _subtitleListVisible / _videoWithSubtitlePanel 承载（Row 真挤窄画面）。
    expect(src, contains('final ValueNotifier<bool> _subtitleListVisible'));
    expect(src, contains('Widget _videoWithSubtitlePanel('));
    expect(src, contains('VideoSubtitleJumpPanel('));
    // 不再经 overlay side-panel 系统开字幕列表（那会浮在画面上遮挡，TODO-314 根因）。
    expect(toggleBody, contains('_subtitleListVisible.value'));
    expect(
        toggleBody,
        isNot(
            contains('_showVideoSidePanel(_VideoSidePanelKind.subtitleList)')));
    expect(toggleBody, isNot(contains('showModalBottomSheet')));
  });

  test('字幕列表入口由右侧 action rail 和自定义控制层承载', () {
    expect(src, contains('_buildVideoSideActionRail(controller)'));
    expect(src, contains('Alignment.centerRight'));
    expect(src, contains('VideoControlButton.subtitleList'));
    expect(src, contains('_toggleSubtitleJumpList'));
    expect(src, contains('_activateVideoControlButton'));
  });

  test('点句调 skipToCue，复用现成 seek，不绕开播放器契约', () {
    expect(
      src,
      contains('void _handleSubtitleJumpTap(AudioCue cue)'),
      reason: '缺点句处理函数',
    );
    expect(
      src,
      contains('_controller?.skipToCue(cue)'),
      reason: '点句必须 skipToCue 到该 cue 起点',
    );
    expect(src, contains('onTapCue: _handleSubtitleJumpTap'));
  });

  test('L 键映射到打开字幕列表，未撞既有按键', () {
    expect(
      ShortcutDefaults.forPlatform(
        TargetPlatform.windows,
      )[ShortcutAction.videoToggleSubtitleList]!
          .keyboardBindings
          .contains(const InputBinding(key: LogicalKeyboardKey.keyL)),
      isTrue,
      reason: '裸 L 键未绑定到 videoToggleSubtitleList 默认键',
    );
    expect(
      shortcuts.contains(
        'ShortcutAction.videoToggleSubtitleList: actions.toggleSubtitleList',
      ),
      isTrue,
      reason: 'videoToggleSubtitleList action 未接到 toggleSubtitleList 回调',
    );
    final int actionIdx = src.indexOf('toggleSubtitleList:');
    expect(actionIdx, greaterThanOrEqualTo(0),
        reason: 'page 缺 toggleSubtitleList action');
    final int nextActionIdx = src.indexOf('toggleImmersiveLock:', actionIdx);
    expect(nextActionIdx, greaterThan(actionIdx));
    final String callback = src.substring(actionIdx, nextActionIdx);
    final int gate = callback.indexOf('_runWhenImmersiveAllowsFullControls');
    final int toggle = callback.indexOf('_toggleSubtitleJumpList');
    expect(gate, greaterThanOrEqualTo(0));
    expect(toggle, greaterThan(gate));
  });

  test('Esc 优先关 push-aside 字幕列表 / 浮层，再退页或退全屏（TODO-314）', () {
    final int escIdx = src.indexOf('escape: () {');
    expect(escIdx, greaterThanOrEqualTo(0), reason: '缺 escape 回调');
    // push-aside 字幕列表分支先判 _subtitleListVisible → 关列表。
    final int listGate =
        src.indexOf('if (_subtitleListVisible.value) {', escIdx);
    final int listCloseIdx = src.indexOf('_toggleSubtitleJumpList();', escIdx);
    // 浮层分支判 _videoSidePanel → _hideVideoSidePanel。
    final int panelGate =
        src.indexOf('if (_videoSidePanel.value != null) {', escIdx);
    final int closeIdx = src.indexOf('_hideVideoSidePanel();', escIdx);
    final int exitIdx = src.indexOf('_handleBackOrExit()', escIdx);
    expect(listGate, greaterThanOrEqualTo(0),
        reason: 'Esc 未先判 push-aside 字幕列表');
    expect(listCloseIdx, greaterThan(listGate), reason: 'Esc 字幕列表分支未关列表');
    expect(panelGate, greaterThan(listGate), reason: 'Esc 浮层分支应在字幕列表之后');
    expect(closeIdx, greaterThan(panelGate), reason: 'Esc 浮层分支未关浮层');
    expect(closeIdx, lessThan(exitIdx), reason: 'Esc 关侧栏必须排在退页之前');
  });

  test('一体式字幕侧栏支持过滤和下一张卡字幕选择', () {
    final String panel =
        File('lib/src/media/video/video_subtitle_jump_panel.dart')
            .readAsStringSync();
    expect(panel, contains('VideoSubtitleListFilter.all'));
    expect(panel, contains('VideoSubtitleListFilter.favorites'));
    expect(panel, contains('VideoSubtitleListFilter.selected'));
    expect(panel, contains('Checkbox('));
    expect(src, contains('isCueSelectedForCard: _isCueSelectedForCard'));
    expect(src, contains('onToggleCueSelection: _toggleCueSelectedForCard'));
  });
}
