import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-102 跨字幕制卡（区间录制；参考 asbplayer）的源码守卫。
///
/// media_kit 跑不了 headless（无真实播放 / 真实 ffmpeg / 全屏路由），故把页面接线点的核心
/// 不变量钉在 `video_hibiki_page.dart` / `video_player_shortcuts.dart`（参照 TODO-069 字幕
/// 跳转列表、TODO-101 锁定守卫范式）。五条核心不变量：
/// ① 录制态用 ValueNotifier（全屏路由也响应，不靠裸 setState）；
/// ② 区间音频走单一抽取器 extractAudioSegmentViaFfmpeg（[startMs,endMs] 一整段，不逐句抽再拼）；
/// ③ 复用统一落卡链路 _mineVideoCard 生成一张卡（单句与跨字幕共用，没从零造制卡）；
/// ④ 入口按钮挂在桌面 + 移动控制条 + R 快捷键；
/// ⑤ 换集自动取消录制 + dispose 释放 notifier。
void main() {
  late String page;
  late String shortcuts;
  late String recorder;

  setUpAll(() {
    page = File('lib/src/pages/implementations/video_hibiki_page.dart')
        .readAsStringSync();
    shortcuts = File('lib/src/media/video/video_player_shortcuts.dart')
        .readAsStringSync();
    recorder = File('lib/src/media/video/cross_subtitle_recorder.dart')
        .readAsStringSync();
  });

  test('① 录制态用 ValueNotifier（全屏路由也响应），并在 dispose 释放', () {
    expect(
      recorder.contains('ValueNotifier<bool> isRecording'),
      isTrue,
      reason: '录制态必须是 ValueNotifier，否则全屏下录制按钮 / 指示层翻不动（BUG-120）',
    );
    expect(
      page.contains('valueListenable: _crossSubRecorder.isRecording'),
      isTrue,
      reason: '录制指示 / 按钮高亮未监听 isRecording（全屏路由不随页面 setState 重建）',
    );
    expect(page.contains('_crossSubRecorder.dispose();'), isTrue,
        reason: 'recorder 未在 dispose 释放');
  });

  test('② 区间音频走单一抽取器、一整段 [startMs,endMs]（不逐句抽再拼）', () {
    // 跨字幕落卡经 _mineVideoCard，音频用 extractAudioSegmentViaFfmpeg 抽 clipStart→clipEnd
    // 一整段；区间从 selection.audioRange 来（[起始cue.startMs, 结束cue.endMs]）。
    expect(page.contains('extractAudioSegmentViaFfmpeg('), isTrue);
    expect(
      page.contains('startMs: clipStartMs') &&
          page.contains('endMs: clipEndMs'),
      isTrue,
      reason: '音频抽取必须用统一的区间 [clipStartMs, clipEndMs]，跨字幕复用之',
    );
    // audioRange 直接给整段，不在 selection 里逐句拼。
    expect(
      recorder.contains('CrossSubtitleAudioRange? audioRange('),
      isTrue,
      reason: '区间音频范围由 selection.audioRange 一次算出整段',
    );
    expect(
      recorder.contains('cues[lo].startMs') &&
          recorder.contains('cues[hi].endMs'),
      isTrue,
      reason: '区间必须是 [起始cue.startMs, 结束cue.endMs]，不是逐句拼接',
    );
  });

  test('③ 复用统一落卡链路 _mineVideoCard 生成一张卡（没从零造制卡）', () {
    // 单句 onMineEntry 与跨字幕 _mineCrossSubtitleSelection 都调 _mineVideoCard。
    expect(page.contains('Future<bool> _mineVideoCard('), isTrue,
        reason: '缺统一落卡链路 _mineVideoCard');
    final int single = 'await _mineVideoCard('.allMatches(page).length +
        'return _mineVideoCard('.allMatches(page).length;
    expect(single, greaterThanOrEqualTo(2),
        reason: '单句 + 跨字幕都应复用 _mineVideoCard（共用一条制卡链路）');
    // 跨字幕方法存在且拼接文本作句子。
    expect(page.contains('Future<void> _mineCrossSubtitleSelection('), isTrue);
    expect(page.contains('selection.joinText(cues)'), isTrue,
        reason: '跨字幕句子字段必须是区间文本拼接 joinText');
  });

  test('③ 退化单句：起止同一句走单句语义（isSingleCue）', () {
    expect(recorder.contains('bool get isSingleCue => startIndex == endIndex;'),
        isTrue,
        reason: 'startIdx==endIdx 必须退化成单句（只按了一下没动）');
  });

  test('④ 入口按钮挂在桌面 + 移动控制条（两态都可触发）', () {
    const String needle = 'onPressed: _toggleCrossSubtitleRecording,';
    final int count = needle.allMatches(page).length;
    expect(count, greaterThanOrEqualTo(2), reason: '桌面 + 移动控制条都应有跨字幕录制入口按钮');
    expect(
      page.contains('_buildCrossSubtitleRecordButton(desktop: true)') &&
          page.contains('_buildCrossSubtitleRecordButton(desktop: false)'),
      isTrue,
      reason: '桌面 + 移动两套按钮都应挂载',
    );
  });

  test('④ R 快捷键切换录制（未撞既有键），并接到本页 action', () {
    expect(
      shortcuts.contains('const SingleActivator(LogicalKeyboardKey.keyR):'),
      isTrue,
      reason: 'R 未绑定切换跨字幕录制',
    );
    expect(shortcuts.contains('actions.toggleCrossSubtitleRecording'), isTrue,
        reason: 'R 未接到 toggleCrossSubtitleRecording action');
    expect(
        page.contains(
            'toggleCrossSubtitleRecording: _toggleCrossSubtitleRecording'),
        isTrue,
        reason: 'action 未接到 _toggleCrossSubtitleRecording');
    // 裸 L（字幕列表）/ Shift+L（锁定）/ S（截图）不被 R 撞掉。
    expect(
      shortcuts.contains('const SingleActivator(LogicalKeyboardKey.keyL): '
          'actions.toggleSubtitleList'),
      isTrue,
      reason: '裸 L（字幕列表）被撞掉',
    );
  });

  test('⑤ 换集自动取消录制 + Esc 优先取消（逐级退出）', () {
    final int switchIdx =
        page.indexOf('Future<void> _switchEpisode(int index)');
    expect(switchIdx, greaterThanOrEqualTo(0));
    final int cancelIdx =
        page.indexOf('_crossSubRecorder.cancel();', switchIdx);
    expect(cancelIdx, greaterThanOrEqualTo(0),
        reason: '换集未取消跨字幕录制（起始 cue 下标随新集失效）');
    // Esc 在录制中先取消，排在解锁 / 退全屏 / 退页之前。
    final int escIdx = page.indexOf('escape: () {');
    final int escCancelIdx =
        page.indexOf('_crossSubRecorder.isRecording.value', escIdx);
    final int unlockIdx = page.indexOf('_immersiveLocked.value', escIdx);
    expect(escCancelIdx, greaterThanOrEqualTo(0), reason: 'Esc 未在录制中先取消');
    expect(escCancelIdx, lessThan(unlockIdx), reason: 'Esc 取消录制必须排在解锁之前（逐级退出）');
  });

  test('起始/结束 cue 解析复用单句同源 resolveMiningCueIndexForPosition', () {
    expect(page.contains('int resolveMiningCueIndexForPosition('), isTrue,
        reason: '缺 cue 下标解析器（跨字幕按下标界定区间）');
    // 单句 resolveMiningCueForPosition 委托给下标版（单一真相，避免漂移）。
    expect(page.contains('final int idx = resolveMiningCueIndexForPosition('),
        isTrue,
        reason: '单句解析必须委托下标版，保证两者同源');
    final int useCount =
        'resolveMiningCueIndexForPosition('.allMatches(page).length;
    expect(useCount, greaterThanOrEqualTo(3), reason: '定义 + 单句委托 + 跨字幕起止两次调用');
  });
}
