// BUG-1022 源码守卫：音轨快照自动刷新接线 + 诊断页 UX 修正不得被后续改动悄悄退化。
//
// 行为断言见 test/mining/gal_hook_track_autorefresh_test.dart；此处守卫接线本身：
//   ① controller 各激活路径 / backend 迁移路径都调 _syncTrackAutoRefresh（自动刷新）；
//   ② _stopSources 回收音轨刷新定时器（定时器生命周期挂会话）；
//   ③ 诊断页 initState 自动拉一次快照——refreshAudioTracks 不再只有手动按钮一个调用点；
//   ④ 「刷新音轨」按钮就近挂在「活跃音轨」卡片，页头不再持有；
//   ⑤ gameResource / Loopback 空轨解释态分支存在（不再误导「尚无音轨数据」）；
//   ⑥ selectVoiceTrack 无 engine 有结构化事件 + 页面 toast（不再静默）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String controllerSrc =
      File('lib/src/mining/gal_hook_session_controller.dart')
          .readAsStringSync();
  final String pageSrc =
      File('lib/src/pages/implementations/game_diagnostics_page.dart')
          .readAsStringSync();

  test('controller：激活/backend 迁移路径接线 _syncTrackAutoRefresh（BUG-1022 ①）', () {
    expect(
      controllerSrc.contains('void _syncTrackAutoRefresh()'),
      isTrue,
      reason: '音轨自动刷新的统一接线点 _syncTrackAutoRefresh 不得被移除',
    );
    for (final String activator in <String>[
      'void _activateEngine(',
      'Future<void> _activateResourceWithLoopback(',
      'Future<bool> _activateTextWithLoopback(',
      'void _promoteLateResourceAudio(',
    ]) {
      final int at = controllerSrc.indexOf(activator);
      expect(at, greaterThan(0), reason: '$activator 不存在，守卫需更新');
      // 从该方法声明起到下一个方法边界内必须出现自动刷新接线调用。
      final int callAt = controllerSrc.indexOf('_syncTrackAutoRefresh();', at);
      expect(callAt, greaterThan(at),
          reason: '$activator 内（或其后）必须调用 _syncTrackAutoRefresh——'
              '会话激活/音频后端变化后音轨快照要自动刷新（BUG-1022）');
      // 粗粒度边界：调用点必须离声明 4000 字符以内，防止匹配到无关远处调用。
      expect(callAt - at, lessThan(4000),
          reason: '$activator 附近未找到 _syncTrackAutoRefresh 调用');
    }
  });

  test('controller：_stopSources 回收音轨刷新定时器', () {
    final int stopAt = controllerSrc.indexOf('Future<void> _stopSources()');
    expect(stopAt, greaterThan(0));
    final int cancelAt =
        controllerSrc.indexOf('_trackRefreshTimer?.cancel();', stopAt);
    expect(cancelAt, greaterThan(stopAt),
        reason: 'stopCapture/close 必须经 _stopSources 取消音轨刷新定时器');
    expect(cancelAt - stopAt, lessThan(600),
        reason: '定时器取消必须在 _stopSources 开头的清理段内');
  });

  test('诊断页：initState 自动拉音轨快照（refreshAudioTracks 非仅手动按钮）', () {
    final int initAt = pageSrc.indexOf('void initState()');
    expect(initAt, greaterThan(0), reason: '诊断页必须有 initState 自动刷新');
    final int refreshAt = pageSrc.indexOf('refreshAudioTracks', initAt);
    expect(refreshAt, greaterThan(initAt),
        reason: 'initState 内必须自动调用 refreshAudioTracks（BUG-1022）');
    expect(refreshAt - initAt, lessThan(600));
  });

  test('诊断页：「刷新音轨」按钮在活跃音轨卡片内、不在页头 actions', () {
    final int headerActionsAt = pageSrc.indexOf('actions: <Widget>[');
    expect(headerActionsAt, greaterThan(0));
    final int headerActionsEnd = pageSrc.indexOf('],', headerActionsAt);
    final String headerActions =
        pageSrc.substring(headerActionsAt, headerActionsEnd);
    expect(headerActions.contains('game_refresh_tracks'), isFalse,
        reason: '刷新音轨按钮应就近移入「活跃音轨」卡片标题行，页头只留清事件');

    final int tracksCardAt = pageSrc.indexOf('class _AudioTracksCard');
    expect(tracksCardAt, greaterThan(0));
    expect(
      pageSrc.indexOf('game_refresh_tracks', tracksCardAt),
      greaterThan(tracksCardAt),
      reason: '「活跃音轨」卡片必须保有手动刷新按钮（自动刷新的兜底）',
    );
  });

  test('诊断页：gameResource / Loopback 空轨走解释态分支（BUG-1022 ②）', () {
    final int tracksCardAt = pageSrc.indexOf('class _AudioTracksCard');
    expect(tracksCardAt, greaterThan(0));
    final String tracksCard = pageSrc.substring(tracksCardAt);
    expect(tracksCard.contains('galTrackEmptyHintFor'), isTrue,
        reason: '空轨解释态必须按 audioBackend 分支（纯函数 galTrackEmptyHintFor）');
    expect(tracksCard.contains('game_tracks_resource_mode_hint'), isTrue,
        reason: 'gameResource 空轨必须显示资源模式解释而非通用「尚无音轨数据」');
    expect(tracksCard.contains('game_tracks_loopback_hint'), isTrue,
        reason: '纯 Loopback 空轨必须显示回环无逐轨枚举的解释');
  });

  test('选轨无 engine 不静默：controller 记事件 + 页面 toast（BUG-1022 ④）', () {
    final int selectAt =
        controllerSrc.indexOf('void selectVoiceTrack(int sourcePtr)');
    expect(selectAt, greaterThan(0));
    final int eventAt =
        controllerSrc.indexOf('audio.voice_track_select_unavailable', selectAt);
    expect(eventAt, greaterThan(selectAt),
        reason: 'selectVoiceTrack 无 engine 必须记结构化警告事件，不得静默 return');
    expect(eventAt - selectAt, lessThan(800));

    expect(pageSrc.contains('game_track_select_requires_engine'), isTrue,
        reason: '诊断页无 engine 选轨必须 toast 提示');
  });

  test('诊断页：逐轨试听接线（grabUtterance 导出 + 播放/停止切换）', () {
    expect(pageSrc.contains('exportTrackPreview'), isTrue,
        reason: '音轨行必须能经 exportTrackPreview 抓取该轨片段试听');
    expect(pageSrc.contains('game_track_preview_failed'), isTrue,
        reason: '试听失败必须 toast 反馈，不得静默');
    final int previewAt =
        controllerSrc.indexOf('Future<GalTrackPreview?> exportTrackPreview(');
    expect(previewAt, greaterThan(0));
    final String previewBody =
        controllerSrc.substring(previewAt, previewAt + 2200);
    expect(previewBody.contains('grabUtterance'), isTrue,
        reason: '试听必须走既有 grabUtterance IPC 按轨抓取（sourcePtr 过滤）');
  });
}
