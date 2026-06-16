import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频侧栏面板（设置 / 字幕列表 / 音轨 / 倍速 / 收藏句 / 字幕源）打开时，
/// 背景的 media_kit 控制条与右侧操作 rail 不再冒出来盖在面板后面（BUG-253 / TODO-300）。
///
/// 根因：控制条显隐镜像 `_videoControlsVisible` 与 media_kit 自己的控制条此前只被
/// `_immersiveLocked` 抑制、从不看 `_videoSidePanel`。修复把「面板开则抑制」扩展到
/// 控制条显隐 / hover / rail 可见性 / media_kit 指针全部路径，与沉浸锁同源门控。
///
/// media_kit controls + hover 时序跑不了 headless，故锁源码结构不变量（与既有
/// video_mouse_autohide_guard_test / video_settings_panel_no_fullscreen_guard_test 同范式）。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();
  });

  /// 截取从 [signature] 起到下一个顶层方法 / 闭合为止的方法体（粗粒度，足够锚定门控）。
  String methodBody(String signature, String endMarker) {
    final int start = src.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '需有 $signature');
    final int end = src.indexOf(endMarker, start + signature.length);
    expect(end, greaterThan(start), reason: '需有 $endMarker 作为 $signature 的段终点');
    return src.substring(start, end);
  }

  test('_pokeControlsVisible 在面板打开时早返回', () {
    final String body = methodBody(
      'void _pokeControlsVisible() {',
      'static const Duration _videoControlsHoverDuration',
    );
    expect(body.contains('if (_videoSidePanel.value != null) return;'), isTrue,
        reason: '_pokeControlsVisible 必须在 _videoSidePanel 非空时早返回，不唤起背景控制条');
  });

  test('控制条可见性派生（_applyControlsVisibilityFromMediaKit）门控沉浸锁 / 侧栏 / 字幕列表', () {
    // TODO-364：可见性收敛到唯一派生函数，门控成立时强制不可见（旧 _markControlsVisible
    // 强制隐藏分支已并入此处）。TODO-329：门控含字幕列表。
    final String body = methodBody(
      'void _applyControlsVisibilityFromMediaKit() {',
      'void _markControlsVisible(bool visible) {',
    );
    final String flat = body.replaceAll(RegExp(r'\s+'), ' ');
    expect(flat.contains('final bool gated ='), isTrue,
        reason: '派生函数内必须有统一 gated 门控');
    for (final String token in <String>[
      '_immersiveLocked.value',
      '_videoSidePanel.value != null',
      '_subtitleListVisible.value',
      '_videoControlEditMode.value',
    ]) {
      expect(flat.contains(token), isTrue, reason: '派生的门控 gated 必须含 $token');
    }
    expect(flat.contains('!gated && _mediaKitControlsVisible.value'), isTrue,
        reason: '门控成立强制不可见、否则等于 media_kit 真实可见性（单一真相源）');
  });

  test('右侧操作 rail gate 含侧栏门控', () {
    final String body = methodBody(
      'Widget _buildVideoSideActionRail(',
      'Widget _buildSideLockButton(',
    );
    // gate 一行可能被 dart format 折行，故只断言并列条件都在 gate 块里出现。
    // BUG-284：rail 显隐判据从 `!controlsVisible` 收紧为 `(!controlsVisible &&
    // !railHovered)`（hover 期间不被收走防闪烁），沉浸锁 / 侧栏门控仍并列在内。
    final int gateIdx = body.indexOf('if (!controlsVisible && !railHovered)');
    expect(gateIdx, greaterThanOrEqualTo(0),
        reason: 'rail 应有 (!controlsVisible && !railHovered) gate（BUG-284）');
    final int braceIdx =
        body.indexOf('return const SizedBox.shrink();', gateIdx);
    expect(braceIdx, greaterThan(gateIdx), reason: 'gate 块应闭合到 shrink');
    expect(body.contains('if (_immersiveLocked.value)'), isTrue,
        reason: 'rail 应保留沉浸锁分支');
    expect(body.contains('_videoSidePanel.value != null'), isTrue,
        reason: 'rail gate 应含侧栏门控（面板开则不显示 rail）');
  });

  test('media_kit controls 的 IgnorePointer 经 Listenable.merge 绑侧栏 / 字幕列表', () {
    // 修复把原来只绑 _immersiveLocked 的 ValueListenableBuilder 换成 merge 三 notifier
    // （TODO-329 把字幕列表也纳入，否则其 hideMouseOnControlsRemoval 隐藏画面光标）。
    final String flat = src.replaceAll(RegExp(r'\s+'), ' ');
    for (final String token in <String>[
      '_immersiveLocked',
      '_videoSidePanel',
      '_subtitleListVisible',
      '_videoControlEditMode',
    ]) {
      expect(flat.contains(token), isTrue,
          reason: 'media_kit controls 的 IgnorePointer 必须监听 $token');
    }
    for (final String token in <String>[
      '_immersiveLocked.value',
      '_videoSidePanel.value != null',
      '_subtitleListVisible.value',
      '_videoControlEditMode.value',
    ]) {
      expect(flat.contains(token), isTrue,
          reason: 'IgnorePointer.ignoring 必须含 $token');
    }
  });

  test('_showVideoSidePanel 不再唤起控制条、_hideVideoSidePanel 关闭后唤回', () {
    final String show = methodBody(
      'void _showVideoSidePanel(_VideoSidePanelKind kind) {',
      'void _hideVideoSidePanel()',
    );
    // 打开面板时不再 poke（会点亮背景控制条），改为显式收起镜像。
    expect(show.contains('_pokeControlsVisible();'), isFalse,
        reason: '_showVideoSidePanel 打开面板时不应再 _pokeControlsVisible（否则点亮背景控制条）');
    expect(show.contains('_markControlsVisible(false);'), isTrue,
        reason: '_showVideoSidePanel 应显式把已显示的控制条镜像收起');

    final String hide = methodBody(
      'void _hideVideoSidePanel() {',
      'String _videoSidePanelTitle(',
    );
    expect(hide.contains('_pokeControlsVisible();'), isTrue,
        reason: '_hideVideoSidePanel 关闭面板后应 _pokeControlsVisible 唤回控制条');
  });
}
