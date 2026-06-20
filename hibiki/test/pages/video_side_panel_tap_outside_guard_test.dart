import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频侧栏面板的关闭模型（BUG-254 / TODO-303 / TODO-637）。
///
/// ① overlay 面板 `_buildVideoSidePanelOverlay`（倍速/设置/收藏句子等）在面板后面铺一层
///    全屏不可见 barrier（`GestureDetector(behavior: HitTestBehavior.opaque, onTap:
///    _hideVideoSidePanel)`），点面板外只关面板、不冒泡到控制条 Listener；该面板 widget
///    `VideoTranslucentSidePanel` 不渲染右上角 `Icons.close`（BUG-254，保持现状）。
/// ② TODO-637：字幕列表 `VideoSubtitleJumpPanel` 改回「带 × 的非阻塞侧栏」——画面区不再叠
///    barrier（它会吃掉画面字幕查词手势，TODO-636），头部带回 `Icons.close` X 关闭按钮。
///
/// media_kit 渲染跑不了 headless，故锁源码结构不变量（overlay barrier 存在 + overlay 面板无
/// X；字幕列表有 X）。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );
  final File sidePanel = File('lib/src/media/video/video_side_panel.dart');
  final File jumpPanel =
      File('lib/src/media/video/video_subtitle_jump_panel.dart');

  test('① _buildVideoSidePanelOverlay 含点外关闭的全屏 barrier', () {
    expect(page.existsSync(), isTrue);
    final String src = page.readAsStringSync();
    final int start = src.indexOf('Widget _buildVideoSidePanelOverlay(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '需有 _buildVideoSidePanelOverlay');
    final int end = src.indexOf('Widget _buildVideoSidePanelContent(', start);
    expect(end, greaterThan(start),
        reason: 'overlay 应把内容抽成 _buildVideoSidePanelContent，并作为段终点');
    final String overlay = src.substring(start, end);

    // 压成单空格后断言 barrier 形态（避免折行 / 缩进锁死）。
    final String flat = overlay.replaceAll(RegExp(r'\s+'), ' ');
    expect(flat.contains('Stack('), isTrue,
        reason: 'overlay 应用 Stack 叠 barrier + 面板');
    expect(flat.contains('GestureDetector('), isTrue,
        reason: 'overlay 应有点外关闭的 GestureDetector barrier');
    expect(flat.contains('behavior: HitTestBehavior.opaque'), isTrue,
        reason: 'barrier 必须 opaque 吃掉点击（不冒泡到控制条 Listener）');
    // TODO-631：删收藏面板（唯一可锁面板）后，侧栏锁机制随之移除，barrier 无条件关闭。
    expect(flat.contains('onTap: _hideVideoSidePanel,'), isTrue,
        reason: 'barrier onTap 无条件关闭面板（_hideVideoSidePanel）；锁机制已随收藏面板删除');
    expect(flat.contains('? null : _hideVideoSidePanel'), isFalse,
        reason: '不再有锁门控的 no-op barrier（TODO-631）');

    // barrier 必须排在面板内容之前（在 Stack 下层），面板内容才在其上、点内部不关闭。
    // 用 children 列表里的 `panelContent,`（带逗号的使用处）锚定，避开顶部的声明语句。
    final int barrierIdx = overlay.indexOf('GestureDetector(');
    final int contentIdx = overlay.indexOf('panelContent,');
    expect(barrierIdx, greaterThanOrEqualTo(0));
    expect(contentIdx, greaterThan(barrierIdx),
        reason: 'panelContent 应在 barrier 之后（Stack 上层），点面板内部命中面板自身不关闭');
  });

  test('② VideoTranslucentSidePanel 不再渲染 Icons.close 关闭按钮', () {
    expect(sidePanel.existsSync(), isTrue);
    final String src = sidePanel.readAsStringSync();
    expect(src.contains('Icons.close'), isFalse,
        reason: 'VideoTranslucentSidePanel header 不应再有 X 关闭按钮');
  });

  test(
      '③ VideoSubtitleJumpPanel renders the Icons.close X button again '
      '(TODO-637 non-blocking sidebar)', () {
    expect(jumpPanel.existsSync(), isTrue);
    final String src = jumpPanel.readAsStringSync();
    // TODO-637 reverses BUG-254 *for the subtitle list only*: the X is back in
    // the header (the BUG-256 tap-outside barrier was removed because it ate
    // the picture-subtitle lookup gesture, TODO-636). The overlay panel
    // (VideoTranslucentSidePanel) keeps its no-X / tap-outside behaviour above.
    expect(src.contains('Icons.close'), isTrue,
        reason: 'VideoSubtitleJumpPanel header must render the X close button '
            'again (TODO-637)');
    expect(src.contains('onPressed: widget.onClose'), isTrue,
        reason: 'the X must invoke onClose');
  });
}
