import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-069 字幕跳转列表（asbplayer 式 transcript 面板）的源码守卫。
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

  test('字幕跳转面板挂在 controls Stack（窗口/全屏共用一层）', () {
    // 面板必须挂进 _buildVideoControlsInner 的 Stack（与字幕 overlay 同源），全屏复用
    // 同一 controls builder 才能在全屏下也出现。
    expect(src.contains('_buildSubtitleJumpPanel(controller),'), isTrue,
        reason: '面板未挂进 controls Stack（全屏将看不到字幕跳转列表）');
    expect(src.contains('VideoSubtitleJumpPanel('), isTrue,
        reason: '未实例化 VideoSubtitleJumpPanel');
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
    expect(
      shortcuts.contains(
          'const SingleActivator(LogicalKeyboardKey.keyL): '
          'actions.toggleSubtitleList'),
      isTrue,
      reason: '裸 L 键未绑定到 toggleSubtitleList',
    );
    expect(src.contains('toggleSubtitleList: _toggleSubtitleJumpList'), isTrue,
        reason: 'toggleSubtitleList action 未接到 _toggleSubtitleJumpList');
  });

  test('Esc 优先关面板（逐级退出，不直接退页/退全屏）', () {
    // escape 回调里，面板开着时先关面板并 return，再到全屏/退页分支。
    final int escIdx = src.indexOf('escape: () {');
    expect(escIdx, greaterThanOrEqualTo(0), reason: '缺 escape 回调');
    final int retIdx =
        src.indexOf('_subtitleListVisible.value = false;', escIdx);
    final int exitIdx = src.indexOf('_handleBackOrExit()', escIdx);
    expect(retIdx, greaterThanOrEqualTo(0),
        reason: 'Esc 未在面板开着时先关面板');
    expect(retIdx, lessThan(exitIdx),
        reason: 'Esc 关面板必须排在退页之前（逐级退出）');
  });

  test('桌面与移动控制条都放了字幕列表入口按钮', () {
    const String needle = 'onPressed: _toggleSubtitleJumpList,';
    final int count = needle.allMatches(src).length;
    expect(count, greaterThanOrEqualTo(2),
        reason: '桌面 + 移动控制条都应有字幕列表入口按钮');
  });
}
