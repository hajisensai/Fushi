import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'video_fushi_page_source_corpus.dart';

void main() {
  final String src = readVideoFushiSource();
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
    final int gate = callback.indexOf('_runWhenImmersiveAllowsShortcuts');
    final int toggle = callback.indexOf('_toggleSubtitleJumpList');
    expect(gate, greaterThanOrEqualTo(0));
    expect(toggle, greaterThan(gate));
  });

  test('Esc 优先关 push-aside 字幕列表 / 浮层，再退页或退全屏（TODO-314）', () {
    // BUG-1862：层序判定收进纯函数 `topVideoForegroundLayer`，执行收进
    // `_dismissTopForegroundLayer`，键盘 Esc / [PopScope] 系统返回键 / 手柄 B 共用同一
    // 份（此前 [PopScope] 那条只关词典浮层，侧栏开着按 Esc 会直接退掉整页）。这里断言
    // 的行为没变：字幕列表比侧栏更前台，两者都排在退页之前。
    final int escIdx = src.indexOf('escape: () {');
    expect(escIdx, greaterThanOrEqualTo(0), reason: '缺 escape 回调');
    final int dismissIdx = src.indexOf('_dismissTopForegroundLayer()', escIdx);
    final int exitIdx = src.indexOf('_handleBackOrExit()', escIdx);
    expect(dismissIdx, greaterThanOrEqualTo(0), reason: 'Esc 未先逐级关前台层');
    expect(dismissIdx, lessThan(exitIdx), reason: 'Esc 关前台层必须排在退页之前');

    final int tableIdx = src.indexOf('bool _dismissTopForegroundLayer() {');
    expect(tableIdx, greaterThanOrEqualTo(0), reason: '缺共用层级表');
    // 层级表读的是两条独立可见性：push-aside 字幕列表 与 side panel。
    final int listGate = src.indexOf(
        'subtitleListVisible: _subtitleListVisible.value', tableIdx);
    final int panelGate =
        src.indexOf('sidePanelOpen: _videoSidePanel.value != null', tableIdx);
    final int listCloseIdx =
        src.indexOf('_toggleSubtitleJumpList();', tableIdx);
    final int closeIdx = src.indexOf('_hideVideoSidePanel();', tableIdx);
    expect(listGate, greaterThanOrEqualTo(0), reason: '层级表未读 push-aside 字幕列表');
    expect(panelGate, greaterThan(listGate), reason: '字幕列表比侧栏更前台，读取顺序应保持一致');
    expect(listCloseIdx, greaterThanOrEqualTo(0), reason: '层级表未关字幕列表');
    expect(closeIdx, greaterThan(listCloseIdx), reason: '层级表未按层序关侧栏');
  });

  test('一体式字幕侧栏只剩「全部 / 收藏」两档，无制卡勾选框', () {
    final String panel =
        File('lib/src/media/video/video_subtitle_jump_panel.dart')
            .readAsStringSync();
    expect(panel, contains('VideoSubtitleListFilter.all'));
    expect(panel, contains('VideoSubtitleListFilter.favorites'));
    // 「选入制卡」勾选框连同「已选」档整条删除：行左侧不再有勾选框列。
    expect(panel, isNot(contains('VideoSubtitleListFilter.selected')));
    expect(panel, isNot(contains('Checkbox(')));
    expect(src, isNot(contains('isCueSelectedForCard')));
    expect(src, isNot(contains('onToggleCueSelection')));
  });
}
