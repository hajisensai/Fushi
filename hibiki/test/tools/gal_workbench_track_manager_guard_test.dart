// BUG-1128 源码守卫：捕获工作台「排除音轨」入口不得被后续改动悄悄退化。
//
// 行为背景：一句没有语音时，自动选源会把 BGM 当成这句的语音收进来（voice_hook_reader
// 的能量选源无绝对门限）。诊断页早有逐轨排除，但用户排查配对时人在捕获工作台，故把
// 「排除音轨」入口也放到工作台。排除某条 BGM 轨后，grabUtterance 的 exclude 集合会滤掉
// 它——没有语音的台词也就不会再读到 BGM。
//
// 守卫的是**用户能力**而非某个实现符号：入口在工作台右栏重构里从「溢出菜单项
// manageTracks → _showTrackManagerDialog」改成了「顶栏直达按钮 → _showSessionTrackPanel」，
// 轨列表体抽成了诊断页/工作台共用的 [GalAudioTracksPanel]。能力没丢、位置变了，所以
// 断言跟着搬到新实现上，而不是把守卫删掉。
//
// 该链路依赖 native 共享内存，无法在 CI 纯 Dart 环境端到端跑，故守卫接线本身：
//   ① 工作台顶栏有直达音轨面板的入口，onTap 分发到 _showSessionTrackPanel；
//   ② 面板打开时刷新音轨快照，并把逐轨排除接到会话的 setTrackExcluded；
//   ③ 共享面板按 galTrackSelectionAffectsCapture 门控，逐轨渲染排除/恢复操作。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String pageSrc =
      File('lib/src/pages/implementations/texthooker_page.dart')
          .readAsStringSync();
  final String panelSrc =
      File('lib/src/mining/gal_audio_tracks_panel.dart').readAsStringSync();

  test('工作台顶栏有音轨面板直达入口（BUG-1128 ①）', () {
    final int entryAt = pageSrc.indexOf("HibikiFocusId('game-toolbar-tracks')");
    expect(
      entryAt,
      greaterThan(0),
      reason: '工作台顶栏必须保留音轨面板按钮（焦点 id game-toolbar-tracks）——'
          '排除 BGM 是会话级操作，不能又退回「先随便找一句才能进」',
    );
    // 按钮声明块内必须直接打开会话音轨面板。
    final int openAt = pageSrc.indexOf('_showSessionTrackPanel()', entryAt);
    expect(openAt, greaterThan(entryAt),
        reason: '顶栏音轨按钮必须打开 _showSessionTrackPanel');
    expect(openAt - entryAt, lessThan(400),
        reason: '打开调用必须就在该按钮声明内，不得匹配到远处无关调用');
    expect(pageSrc.contains('t.game_audio_tracks'), isTrue,
        reason: '顶栏音轨入口必须有可读文案');
  });

  test('面板刷新快照 + 逐轨 setTrackExcluded 接线（BUG-1128 ②）', () {
    final int dialogAt =
        pageSrc.indexOf('Future<void> _showSessionTrackPanel()');
    expect(dialogAt, greaterThan(0), reason: '_showSessionTrackPanel 必须存在');
    final String dialog = pageSrc.substring(dialogAt, dialogAt + 3000);

    expect(dialog.contains('refreshAudioTracks()'), isTrue,
        reason: '打开面板要先刷新音轨快照，避免展示过期列表');
    expect(dialog.contains('GalAudioTracksPanel('), isTrue,
        reason: '工作台音轨面板必须复用共享组件，不许再写第二份轨列表');
    expect(
      dialog.contains('onToggleExcluded: _session.setTrackExcluded'),
      isTrue,
      reason: '逐轨排除/恢复必须走会话既有的 setTrackExcluded 通道',
    );
  });

  test('共享面板按后端门控并渲染排除/恢复操作（BUG-1128 ③）', () {
    expect(panelSrc.contains('galTrackSelectionAffectsCapture'), isTrue,
        reason: '排除只在引擎 PCM 后端生效——必须按后端门控，不让用户点不生效的开关');
    expect(
      panelSrc.contains('game_track_exclude_bgm') &&
          panelSrc.contains('game_track_restore'),
      isTrue,
      reason: '排除/恢复按钮文案复用既有 key',
    );
    final int tileAt = panelSrc.indexOf('class GalTrackTile');
    expect(tileAt, greaterThan(0), reason: '逐轨 tile 组件必须存在');
    expect(panelSrc.indexOf('onToggleExcluded', tileAt), greaterThan(tileAt),
        reason: '逐轨 tile 必须把排除动作回调出去');
  });
}
