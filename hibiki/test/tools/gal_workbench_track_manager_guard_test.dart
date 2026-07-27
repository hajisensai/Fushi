// BUG-1115 源码守卫：捕获工作台「排除音轨」入口不得被后续改动悄悄退化。
//
// 行为背景：一句没有语音时，自动选源会把 BGM 当成这句的语音收进来（voice_hook_reader
// 的能量选源无绝对门限）。诊断页早有逐轨排除，但用户排查配对时人在捕获工作台，故把
// 「排除音轨」入口也放到工作台。排除某条 BGM 轨后，grabUtterance 的 exclude 集合会滤掉
// 它——没有语音的台词也就不会再读到 BGM。
//
// 这里守卫接线本身（该链路依赖 native 共享内存，无法在 CI 纯 Dart 环境端到端跑）：
//   ① 工具栏溢出菜单有 manageTracks 动作，onSelected 分发到 _showTrackManagerDialog；
//   ② 对话框刷新音轨快照、逐轨调用 setTrackExcluded、按 galTrackSelectionAffectsCapture 门控；
//   ③ 用新 i18n key（game_manage_tracks / game_track_exclusion_title）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String pageSrc =
      File('lib/src/pages/implementations/texthooker_page.dart')
          .readAsStringSync();

  test('工具栏溢出菜单有 manageTracks 动作并分发到对话框（BUG-1115 ①）', () {
    expect(
      pageSrc.contains('manageTracks'),
      isTrue,
      reason: '_GalHookToolbarMenuAction 必须保留 manageTracks 动作',
    );
    final int menuAt =
        pageSrc.indexOf('_GalHookToolbarMenuAction.manageTracks');
    expect(menuAt, greaterThan(0));
    // onSelected 分支必须调对话框。
    expect(
      pageSrc.contains('_showTrackManagerDialog()'),
      isTrue,
      reason: 'manageTracks 必须打开 _showTrackManagerDialog',
    );
    // itemBuilder 里必须出现菜单项文案 key。
    expect(pageSrc.contains('t.game_manage_tracks'), isTrue,
        reason: '溢出菜单必须有「管理音轨」项');
  });

  test('对话框刷新快照 + 逐轨 setTrackExcluded + 后端门控（BUG-1115 ②）', () {
    final int dialogAt =
        pageSrc.indexOf('Future<void> _showTrackManagerDialog()');
    expect(dialogAt, greaterThan(0), reason: '_showTrackManagerDialog 必须存在');
    final String dialog = pageSrc.substring(dialogAt, dialogAt + 3000);

    expect(dialog.contains('refreshAudioTracks()'), isTrue,
        reason: '打开对话框要先刷新音轨快照，避免展示过期列表');
    expect(dialog.contains('galTrackSelectionAffectsCapture'), isTrue,
        reason: '排除只在引擎 PCM 后端生效——必须按后端门控，不让用户点不生效的开关');

    // setTrackExcluded 在专门的音轨行构建函数里调用（对话框体积超过 3000 字符窗口，
    // 逐轨 tile 抽成了 _buildTrackManagerTile）。
    final int tileAt = pageSrc.indexOf('Widget _buildTrackManagerTile(');
    expect(tileAt, greaterThan(0), reason: '逐轨 tile 构建函数必须存在');
    final String tile = pageSrc.substring(tileAt, tileAt + 1500);
    expect(tile.contains('_session.setTrackExcluded('), isTrue,
        reason: '逐轨排除/恢复必须走会话既有的 setTrackExcluded 通道');
    expect(
      tile.contains('game_track_exclude_bgm') &&
          tile.contains('game_track_restore'),
      isTrue,
      reason: '排除/恢复按钮文案复用既有 key',
    );
  });

  test('对话框标题用新 i18n key（BUG-1115 ③）', () {
    expect(pageSrc.contains('t.game_track_exclusion_title'), isTrue);
    expect(pageSrc.contains('t.game_track_exclusion_hint'), isTrue);
  });
}
