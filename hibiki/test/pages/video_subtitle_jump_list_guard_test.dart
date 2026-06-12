import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';

/// TODO-069 字幕跳转列表（asbplayer 式 transcript 面板）+ TODO-121 真 push-aside 的
/// 源码守卫。
///
/// media_kit 跑不了 headless，全屏路由 + 控制条点击也无法在 widget 测试里真实驱动，
/// 故把面板的接线不变量锁在 `video_hibiki_page.dart` 的调用点（面板渲染逻辑本身由
/// `video_subtitle_jump_panel_test.dart` 的真 widget 测试覆盖）。
void main() {
  final String src =
      File('lib/src/pages/implementations/video_hibiki_page.dart')
          .readAsStringSync();
  final String shortcuts =
      File('lib/src/media/video/video_player_shortcuts.dart')
          .readAsStringSync();

  test('字幕跳转面板是真 push-aside（Row 兄弟列，非 controls Stack overlay）', () {
    // TODO-121：面板不再 overlay 盖画面，而是与 Video 同级排进 Row[Expanded(Video), 面板列]，
    // 面板可见时画面真挤窄。故旧的「挂进 controls Stack」接线必须移除，改成两路径各自把
    // Video 包进 _videoWithSubtitlePanel。
    expect(src.contains('_videoWithSubtitlePanel('), isTrue,
        reason: '缺 push-aside 包裹器 _videoWithSubtitlePanel');
    expect(src.contains('Expanded(child: video)'), isTrue,
        reason: 'push-aside 必须用 Expanded 收窄 Video（真挤窄而非 overlay 遮挡）');
    expect(src.contains('VideoSubtitleJumpPanel('), isTrue,
        reason: '未实例化 VideoSubtitleJumpPanel');
    // 面板不得再作为 overlay 挂进 controls Stack（那样会盖住画面，正是 TODO-121 要消除的）。
    expect(src.contains('_buildSubtitleJumpPanel(controller),'), isFalse,
        reason: '面板仍以 overlay 形式挂在 controls Stack（应改为 Row 兄弟列 push-aside）');
  });

  test('窗口与全屏两路径都把 Video 包进 push-aside（缩窄两路径都生效）', () {
    // 窗口侧在 _buildVideoBody 用 _videoWithSubtitlePanel(controller, Video(...))。
    expect(
      src.contains('child: _videoWithSubtitlePanel('),
      isTrue,
      reason: '窗口路径（_buildVideoBody）未用 push-aside 包裹 Video',
    );
    // 全屏侧在自建全屏路由里用 _videoWithSubtitlePanel(playerController, fullscreenVideo)。
    expect(
      src.contains('_videoWithSubtitlePanel(') &&
          src.contains('fullscreenVideo'),
      isTrue,
      reason: '全屏路径（_pushNeutralizedVideoFullscreen）未用 push-aside 包裹 Video',
    );
    // helper 内部用 Row 把 Video 与面板列排成兄弟（横向挤窄）。
    final int helperIdx = src.indexOf('Widget _videoWithSubtitlePanel(');
    expect(helperIdx, greaterThanOrEqualTo(0),
        reason: '缺 _videoWithSubtitlePanel 定义');
    final int rowIdx = src.indexOf('return Row(', helperIdx);
    expect(rowIdx, greaterThanOrEqualTo(0),
        reason: 'push-aside helper 必须用 Row 把 Video 与面板列排成兄弟');
  });

  test('可见性用 ValueNotifier（全屏路由也响应，不靠 setState）', () {
    // 全屏是独立 root 路由、不随本页 setState 重建（BUG-120 同源），故可见性必须走
    // ValueNotifier + ValueListenableBuilder。
    expect(
      src.contains('ValueNotifier<bool> _subtitleListVisible'),
      isTrue,
      reason: '可见性必须是 ValueNotifier，否则全屏下 L 键/按钮翻不动面板',
    );
    expect(
      src.contains('valueListenable: _subtitleListVisible'),
      isTrue,
      reason: '面板未监听 _subtitleListVisible',
    );
    expect(src.contains('_subtitleListVisible.dispose();'), isTrue,
        reason: 'notifier 未在 dispose 释放');
  });

  test('点句调 skipToCue（复用现成 seek，不绕开播放器契约）', () {
    expect(
      src.contains('void _handleSubtitleJumpTap(AudioCue cue)'),
      isTrue,
      reason: '缺点句处理函数',
    );
    expect(
      src.contains('_controller?.skipToCue(cue)'),
      isTrue,
      reason: '点句必须 skipToCue 到该 cue 起点（seek 跳到对应画面）',
    );
    expect(src.contains('onTapCue: _handleSubtitleJumpTap'), isTrue,
        reason: '面板点句回调未接到 _handleSubtitleJumpTap');
  });

  test('L 键映射到打开字幕跳转列表（asbplayer 式，未撞既有键）', () {
    // TODO-134: bare L default lives in the registry now
    // (videoToggleSubtitleList); action->callback wiring stays in
    // video_player_shortcuts.dart.
    expect(
      ShortcutDefaults.forPlatform(
              TargetPlatform.windows)[ShortcutAction.videoToggleSubtitleList]!
          .keyboardBindings
          .contains(const InputBinding(key: LogicalKeyboardKey.keyL)),
      isTrue,
      reason: '裸 L 键未绑定到 videoToggleSubtitleList 默认键',
    );
    expect(
      shortcuts.contains(
          'ShortcutAction.videoToggleSubtitleList: actions.toggleSubtitleList'),
      isTrue,
      reason: 'videoToggleSubtitleList action 未接到 toggleSubtitleList 回调',
    );
    final int actionIdx = src.indexOf('toggleSubtitleList:');
    expect(actionIdx, greaterThanOrEqualTo(0),
        reason: 'page 缺 toggleSubtitleList action');
    final int nextActionIdx = src.indexOf('toggleImmersiveLock:', actionIdx);
    expect(nextActionIdx, greaterThan(actionIdx),
        reason: 'toggleSubtitleList 回调终点缺 toggleImmersiveLock');
    final String callback = src.substring(actionIdx, nextActionIdx);
    final int gate = callback.indexOf('_runWhenImmersiveAllowsFullControls');
    final int toggle = callback.indexOf('_toggleSubtitleJumpList');
    expect(gate, greaterThanOrEqualTo(0),
        reason: 'L 快捷键必须先走沉浸模式 full-controls gate');
    expect(toggle, greaterThan(gate),
        reason:
            'toggleSubtitleList action 通过 gate 后必须接到 _toggleSubtitleJumpList');
  });

  test('Esc 优先关面板（逐级退出，不直接退页/退全屏）', () {
    // escape 回调里，面板开着时先关面板并 return，再到全屏/退页分支。
    final int escIdx = src.indexOf('escape: () {');
    expect(escIdx, greaterThanOrEqualTo(0), reason: '缺 escape 回调');
    final int retIdx =
        src.indexOf('_subtitleListVisible.value = false;', escIdx);
    final int exitIdx = src.indexOf('_handleBackOrExit()', escIdx);
    expect(retIdx, greaterThanOrEqualTo(0), reason: 'Esc 未在面板开着时先关面板');
    expect(retIdx, lessThan(exitIdx), reason: 'Esc 关面板必须排在退页之前（逐级退出）');
  });

  test('桌面与移动控制条都放了字幕列表入口按钮', () {
    const String needle = 'onPressed: _toggleSubtitleJumpList,';
    final int count = needle.allMatches(src).length;
    expect(count, greaterThanOrEqualTo(2), reason: '桌面 + 移动控制条都应有字幕列表入口按钮');
  });
}
