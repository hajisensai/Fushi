import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';
import 'video_hibiki_page_source_corpus.dart';

String _section(String src, String startToken, String endToken) {
  final int start = src.indexOf(startToken);
  expect(start, greaterThanOrEqualTo(0), reason: '缺少 $startToken');
  final int end = src.indexOf(endToken, start);
  expect(end, greaterThan(start), reason: '$startToken 后缺少 $endToken');
  return src.substring(start, end);
}

/// TODO-101 锁定 / 沉浸模式的源码守卫。
///
/// media_kit 跑不了 headless，全屏路由 + 控制条 hover / 点击都无法在 widget 测试里真实
/// 驱动，故把锁定态的不变量钉在 `video_hibiki_page.dart` / `video_player_shortcuts.dart`
/// 的接线点（参照 TODO-069 字幕跳转列表守卫范式）。锁定态四条核心不变量：
/// ① 可见性用 ValueNotifier（全屏路由也响应，不靠裸 setState）；
/// ② 锁定态控制条不弹（gate `AdaptiveVideoControls` 的指针 + poke 在锁定时早返回）；
/// ③ 锁定态查词 / 快捷键链路未被禁用（IgnorePointer 只过滤指针、字幕 overlay 在其上）；
/// ④ 锁屏入口 + 常驻解锁出口都可达（桌面 + 移动入口按钮 + 常驻解锁层 + Shift+L）。
void main() {
  late String src;
  late String shortcuts;

  setUpAll(() {
    src = readVideoHibikiSource();
    shortcuts = File('lib/src/media/video/video_player_shortcuts.dart')
        .readAsStringSync();
  });

  test('① 锁定可见性用 ValueNotifier（全屏路由也响应），并在 dispose 释放', () {
    expect(
      src.contains('ValueNotifier<bool> _immersiveLocked'),
      isTrue,
      reason: '锁定态必须是 ValueNotifier，否则全屏下锁屏按钮 / 快捷键翻不动',
    );
    expect(
      src.contains('valueListenable: _immersiveLocked'),
      isTrue,
      reason: '锁定态层未监听 _immersiveLocked（全屏路由不随页面 setState 重建，BUG-120）',
    );
    expect(src.contains('_immersiveLocked.dispose();'), isTrue,
        reason: 'notifier 未在 dispose 释放');
  });

  test('② 锁定态 gate AdaptiveVideoControls 的指针（控制条不弹）', () {
    // AdaptiveVideoControls 必须被 IgnorePointer 包住、ignoring 跟随锁定态，鼠标 hover
    // 收不到 → media_kit 控制条不被唤起。BUG-253 起 ignoring 还并入侧栏门控
    // （_videoSidePanel），故只断言 ignoring 含 _immersiveLocked.value、child 是
    // AdaptiveVideoControls（折行无关，压成单空格后匹配）。
    final int idx = src.indexOf('IgnorePointer(');
    expect(idx, greaterThanOrEqualTo(0),
        reason: '锁定态必须用 IgnorePointer 拦掉送往 media_kit controls 的指针');
    final String flat = src.replaceAll(RegExp(r'\s+'), ' ');
    expect(
      RegExp(r'IgnorePointer\( ignoring: _immersiveLocked\.value[^,]*, '
              r'child: AdaptiveVideoControls\(state\),')
          .hasMatch(flat),
      isTrue,
      reason: 'IgnorePointer.ignoring 必须跟随锁定态、child 必须是 AdaptiveVideoControls',
    );
  });

  test('② poke 在锁定态早返回（键盘跳句不再弹控制条）', () {
    // _pokeControlsVisible 在桌面门控之后、派发合成 hover 之前，必须先判锁定态早返回。
    final int pokeIdx = src.indexOf('void _pokeControlsVisible()');
    expect(pokeIdx, greaterThanOrEqualTo(0));
    final int dispatchIdx =
        src.indexOf('GestureBinding.instance.handlePointerEvent', pokeIdx);
    final int gateIdx =
        src.indexOf('if (_immersiveLocked.value) return;', pokeIdx);
    expect(gateIdx, greaterThanOrEqualTo(0),
        reason: 'poke 未在锁定态早返回（锁定态键盘交互会弹控制条）');
    expect(gateIdx, lessThan(dispatchIdx), reason: '锁定态早返回必须排在派发合成 hover 之前');
  });

  test('② poke 在字幕列表等强压制态早返回，不让 hover 与控制条互相拉起', () {
    final int pokeIdx = src.indexOf('void _pokeControlsVisible()');
    expect(pokeIdx, greaterThanOrEqualTo(0));
    final int dispatchIdx =
        src.indexOf('GestureBinding.instance.handlePointerEvent', pokeIdx);
    expect(dispatchIdx, greaterThan(pokeIdx));

    for (final String gate in <String>[
      'if (_immersiveLocked.value) return;',
      'if (_videoSidePanel.value != null) return;',
      'if (_subtitleListVisible.value) return;',
      'if (_videoControlEditMode.value) return;',
    ]) {
      final int gateIdx = src.indexOf(gate, pokeIdx);
      expect(gateIdx, greaterThanOrEqualTo(0),
          reason: '_pokeControlsVisible 缺强压制态早返回：$gate');
      expect(gateIdx, lessThan(dispatchIdx), reason: '$gate 必须排在派发合成 hover 之前');
    }
  });

  test('③ 锁定态查词 / 快捷键不被禁用（IgnorePointer 不裹字幕 overlay / 快捷键）', () {
    // 字幕逐字查词 overlay 必须在 AdaptiveVideoControls 之上、且不被 IgnorePointer 包住。
    final int controlsIdx = src.indexOf('AdaptiveVideoControls(state)');
    final int overlayIdx = src.indexOf('VideoSubtitleOverlay(');
    expect(controlsIdx, greaterThanOrEqualTo(0));
    expect(overlayIdx, greaterThanOrEqualTo(0));
    expect(overlayIdx, greaterThan(controlsIdx),
        reason: '字幕查词 overlay 必须叠在 controls 之上，锁定态点字幕仍能查词');
    // 锁定态绝不能把快捷键表清空 / gate 掉：keyboardShortcuts 仍整表传给主题。
    expect(
        src.contains('keyboardShortcuts: _videoKeyboardShortcuts(controller)'),
        isTrue,
        reason: '快捷键表必须始终传给 media_kit 主题（锁定态快捷键不被禁用）');
  });

  test('④ 锁屏入口可达：视频左侧锁按钮 + 上下文菜单项（TODO-126 已移出 topButtonBar）', () {
    // TODO-126：锁按钮从 topButtonBar 移到视频左侧居中的 [_buildSideLockButton]，
    // 同一枚侧边按钮承载两态图标。入口至少两条：侧边按钮 onPressed + 上下文菜单项。
    expect(
      src.contains('onPressed: _toggleImmersiveLock,'),
      isTrue,
      reason: '视频左侧锁 / 解锁按钮未接到 _toggleImmersiveLock',
    );
    expect(
      src.contains('t.video_menu_lock, _toggleImmersiveLock'),
      isTrue,
      reason: '上下文菜单缺锁屏入口项',
    );
  });

  test('④ 侧边锁按钮图标用状态语义：锁住=闭锁、未锁=开锁（TODO-153/BUG-216）', () {
    // 原先反成「动作提示」语义（locked ? lock_open_outlined : lock_outline）=锁住却显示
    // 开锁，与用户「锁住=闭锁」的状态预期相反，也与 OSD / 悬浮字幕锁 / 原生两端不一致。
    // 修复后状态语义：locked → Icons.lock_outline（闭锁），未锁 → Icons.lock_open_outlined。
    expect(
      RegExp(r'locked\s*\?\s*Icons\.lock_outline\s*:\s*Icons\.lock_open_outlined')
          .hasMatch(src),
      isTrue,
      reason: '侧边锁按钮图标必须是状态语义：锁住显闭锁、未锁显开锁',
    );
    // 防回归倒回旧的「动作提示」反向。
    expect(
      RegExp(r'locked\s*\?\s*Icons\.lock_open_outlined\s*:\s*Icons\.lock_outline')
          .hasMatch(src),
      isFalse,
      reason: '不得倒回「锁住显开锁」的反向动作语义（回归 BUG-216）',
    );
    // tooltip 保持动作语义（锁住时「点击解锁」合理），与图标状态语义并存。
    expect(
      RegExp(r'tooltip: locked\s*\?\s*t\.video_immersive_unlock\s*:\s*t\.video_menu_lock')
          .hasMatch(src),
      isTrue,
      reason: 'tooltip 应保持动作语义（locked → 点击解锁）',
    );
  });

  test('④ 沉浸态常驻解锁层移到视频左侧居中（_buildSideLockButton，挂在 controls Stack）', () {
    final int railIdx = src.indexOf('Widget _buildVideoSideActionRail(');
    expect(railIdx, greaterThanOrEqualTo(0),
        reason: 'controls Stack 应该挂载侧边 rail / 锁按钮层');
    expect(src.indexOf('_buildSideLockButton()', railIdx), greaterThan(railIdx),
        reason: '侧边锁 / 解锁层未挂进 controls Stack（全屏将看不到解锁按钮）');
    expect(src.contains('_slotChipItems(VideoControlSlot.screenLeft)'), isTrue,
        reason: '沉浸锁应能放进可调整的左侧 rail');
    expect(src.contains('_slotChipItems(VideoControlSlot.screenRight)'), isTrue,
        reason: '沉浸锁被移到右侧 rail 后也应仍可发现');
    expect(src.contains('Widget _buildSideLockButton()'), isTrue,
        reason: '缺侧边锁 / 解锁层构建函数');
    // 解锁层点击退出锁定。
    final int idx = src.indexOf('Widget _buildSideLockButton()');
    expect(
        src.indexOf('onPressed: _toggleImmersiveLock,', idx), greaterThan(idx),
        reason: '侧边解锁按钮未接到 _toggleImmersiveLock');
    // TODO-126：放在视频正左边、垂直居中（左侧贴边 + centerLeft 对齐）。
    final int alignIdx = src.indexOf('alignment: Alignment.centerLeft', idx);
    expect(alignIdx, greaterThan(idx),
        reason: '侧边锁按钮应在视频正左边垂直居中（Alignment.centerLeft）');
  });

  test('④ 沉浸锁只压制普通 rail，仍保留可见解锁入口', () {
    final String railBody = _section(
      src,
      'Widget _buildVideoSideActionRail(',
      'Widget _buildVideoSideRailFor(',
    );
    final int lockedIdx = railBody.indexOf('if (_immersiveLocked.value)');
    expect(lockedIdx, greaterThanOrEqualTo(0), reason: 'rail gate 必须单独处理沉浸锁态');
    final int afterLocked = railBody.indexOf('if (!controlsVisible', lockedIdx);
    expect(afterLocked, greaterThan(lockedIdx));
    final String lockedBranch = railBody.substring(lockedIdx, afterLocked);

    expect(lockedBranch.contains('_buildSideLockButton()'), isTrue,
        reason: '沉浸锁下若锁按钮不在 rail 配置中，仍必须渲染独立解锁入口');
    expect(lockedBranch.contains('immersiveOnly: true'), isTrue,
        reason: '沉浸锁下若锁按钮在 rail 配置中，只能渲染 immersiveLock，不得保留普通 rail 按钮');
    expect(lockedBranch.contains('VideoControlItem.immersiveLock'), isTrue,
        reason: '沉浸锁分支必须保留 immersiveLock 解锁入口');
  });

  test('④ 侧边解锁按钮无操作淡出 + 鼠标 / 触屏唤回（TODO-126），退出仍可达', () {
    // 独立可见性源（不被锁 gate），AnimatedOpacity 淡出。
    expect(src.contains('ValueNotifier<bool> _lockButtonVisible'), isTrue,
        reason: '缺侧边锁按钮独立可见性 notifier');
    expect(src.contains('void _pokeLockButton()'), isTrue,
        reason: '缺侧边锁按钮唤回方法');
    final int sideIdx = src.indexOf('Widget _buildSideLockButton()');
    // TODO-388（BUG-295）：可见性源从单一 ValueListenableBuilder 升级为
    // Listenable.merge([_lockButtonVisible, _lockButtonHovered])，判据
    // `_lockButtonVisible.value || _lockButtonHovered.value`——自动淡出仍由
    // _lockButtonVisible 驱动（hover 期间由 _lockButtonHovered 顶住，根除 hover 即消失）。
    // _buildSideLockButton 拆到 layout.part 后是该 extension（也是整份合并语料）的最末
    // 个成员，原来的「下一个方法 IconData _volumeIconFor( 作截断锚点」在合并语料里落在它
    // 之前 → indexOf 返 -1。改用方法自身的 2 空格闭合作段终点（与下方 _pokeLockButton 同款）。
    final int sideEnd = src.indexOf('\n  }', sideIdx);
    expect(sideEnd, greaterThan(sideIdx));
    final String sideBody = src.substring(sideIdx, sideEnd);
    expect(sideBody.contains('_lockButtonVisible.value'), isTrue,
        reason: '侧边锁按钮淡出仍由 _lockButtonVisible 驱动');
    expect(sideBody.contains('_lockButtonHovered.value'), isTrue,
        reason: 'hover 期间应由 _lockButtonHovered 顶住显示（BUG-295）');
    expect(sideBody.contains('AnimatedOpacity('), isTrue,
        reason: '侧边锁按钮淡出应用 AnimatedOpacity');
    // 唤回路径：桌面 hover（onEnter/onHover）+ 移动 / 触屏点画面（_handleVideoPointerUp）。
    expect('_pokeLockButton()'.allMatches(src).length, greaterThanOrEqualTo(3),
        reason: 'hover + 触屏 + toggle 三处都应唤回侧边锁按钮');
    // 退出仍可达：_pokeLockButton 不被锁 gate（与 _markControlsVisible 区分），故沉浸态
    // 解锁按钮淡出后仍能唤回；Esc / Shift+L 另有专门用例钉死。
    final int pokeIdx = src.indexOf('void _pokeLockButton()');
    expect(pokeIdx, greaterThanOrEqualTo(0), reason: '缺侧边锁按钮唤回方法');
    // _pokeLockButton 抽到 controls_visibility.part 后是该 extension 末个成员，
    // 用方法自身的 2 空格闭合作段终点（不再依赖紧随的下一个 void 成员）。
    final int pokeEnd = src.indexOf('\n  }', pokeIdx);
    expect(pokeEnd, greaterThan(pokeIdx));
    final String pokeBody = src.substring(pokeIdx, pokeEnd);
    expect(pokeBody.contains('_immersiveLocked.value'), isFalse,
        reason: '_pokeLockButton 不得被锁 gate（否则沉浸态解锁按钮淡出后唤不回，失去退出口）');
    // 释放。
    expect(src.contains('_lockButtonVisible.dispose();'), isTrue,
        reason: '_lockButtonVisible 未在 dispose 释放');
  });

  test('④ Shift+L 切换锁定（与裸 L 字幕列表区分，未撞键），并接到本页 action', () {
    // TODO-134: keys live in the registry. Shift+L default is
    // videoToggleImmersiveLock; bare L is videoToggleSubtitleList; the
    // action->callback wiring stays in video_player_shortcuts.dart.
    final Map<ShortcutAction, ShortcutBindingSet> vd =
        ShortcutDefaults.forPlatform(TargetPlatform.windows);
    expect(
      vd[ShortcutAction.videoToggleImmersiveLock]!.keyboardBindings.contains(
          const InputBinding(
              key: LogicalKeyboardKey.keyL,
              modifiers: <ModifierKey>{ModifierKey.shift})),
      isTrue,
      reason: 'Shift+L is the default key for immersive lock',
    );
    expect(
        shortcuts.contains('ShortcutAction.videoToggleImmersiveLock: '
            'actions.toggleImmersiveLock'),
        isTrue,
        reason: 'Shift+L action wired to toggleImmersiveLock');
    expect(src.contains('toggleImmersiveLock: _toggleImmersiveLock'), isTrue,
        reason: 'toggleImmersiveLock action wired to _toggleImmersiveLock');
    // bare L still owns the subtitle list (Shift+L must not steal it).
    expect(
      vd[ShortcutAction.videoToggleSubtitleList]!
          .keyboardBindings
          .contains(const InputBinding(key: LogicalKeyboardKey.keyL)),
      isTrue,
      reason: 'bare L still opens the subtitle list',
    );
  });

  test('Esc 优先解锁（最外层沉浸态，排在退全屏 / 退页之前）', () {
    final int escIdx = src.indexOf('escape: () {');
    expect(escIdx, greaterThanOrEqualTo(0), reason: '缺 escape 回调');
    final int unlockIdx = src.indexOf('_immersiveLocked.value', escIdx);
    final int fullscreenExitIdx =
        src.indexOf('_exitVideoFullscreen(ctx)', escIdx);
    final int exitIdx = src.indexOf('_handleBackOrExit()', escIdx);
    expect(unlockIdx, greaterThanOrEqualTo(0), reason: 'Esc 未在锁定态先解锁');
    expect(unlockIdx, lessThan(fullscreenExitIdx), reason: 'Esc 解锁必须排在退全屏之前');
    expect(unlockIdx, lessThan(exitIdx), reason: 'Esc 解锁必须排在退页之前（逐级退出）');
  });
}
