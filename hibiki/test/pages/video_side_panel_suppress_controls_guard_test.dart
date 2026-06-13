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

  test('_markControlsVisible 的强制隐藏分支同时门控沉浸锁与侧栏', () {
    final String body = methodBody(
      'void _markControlsVisible(bool visible) {',
      'void _onVideoControlsHoverExit()',
    );
    expect(
      body.contains(
        'if (_immersiveLocked.value || _videoSidePanel.value != null) {',
      ),
      isTrue,
      reason:
          '_markControlsVisible 强制不可见分支必须同时含 _immersiveLocked 与 _videoSidePanel',
    );
  });

  test('右侧操作 rail gate 含侧栏门控', () {
    final String body = methodBody(
      'Widget _buildVideoSideActionRail(',
      'Widget _buildSideLockButton(',
    );
    // gate 一行可能被 dart format 折行，故只断言两个并列条件都在 gate 块里出现。
    final int gateIdx = body.indexOf('if (!controlsVisible ||');
    expect(gateIdx, greaterThanOrEqualTo(0),
        reason: 'rail 应有 !controlsVisible gate');
    final int braceIdx =
        body.indexOf('return const SizedBox.shrink();', gateIdx);
    expect(braceIdx, greaterThan(gateIdx), reason: 'gate 块应闭合到 shrink');
    final String gate = body.substring(gateIdx, braceIdx);
    expect(gate.contains('_immersiveLocked.value'), isTrue,
        reason: 'rail gate 应含沉浸锁');
    expect(gate.contains('_videoSidePanel.value != null'), isTrue,
        reason: 'rail gate 应含侧栏门控（面板开则不显示 rail）');
  });

  test('media_kit controls 的 IgnorePointer 经 Listenable.merge 绑侧栏', () {
    // 修复把原来只绑 _immersiveLocked 的 ValueListenableBuilder 换成 merge 两 notifier。
    expect(
      src.contains('<Listenable>[_immersiveLocked, _videoSidePanel]'),
      isTrue,
      reason: 'media_kit controls 的 IgnorePointer 必须同时监听沉浸锁与侧栏',
    );
    // 折行无关：把源码空白压成单空格后断言 ignoring 同时含两条件（避免锁死缩进）。
    final String flat = src.replaceAll(RegExp(r'\s+'), ' ');
    expect(
      flat.contains(
        'ignoring: _immersiveLocked.value || _videoSidePanel.value != null',
      ),
      isTrue,
      reason:
          'IgnorePointer.ignoring 必须含 _immersiveLocked 与 _videoSidePanel 两条件',
    );
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
