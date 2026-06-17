import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：字幕跳转列表走 push-aside（把画面挤窄到左侧），而非 overlay 浮层遮挡
/// （TODO-314 / BUG-256）。
///
/// 根因：此前 `_toggleSubtitleJumpList` 误经 `_showVideoSidePanel(subtitleList)` 进 overlay
/// side-panel 系统，且 `_showVideoSidePanel` 无条件把 `_subtitleListVisible` 置 false →
/// 真正的 push-aside 布局 `_videoWithSubtitlePanel`（`Row[Expanded(video), 面板列]`）成死
/// 代码，列表改由 overlay `Align centerRight` 浮在画面上遮挡。
///
/// 修复：`_toggleSubtitleJumpList` 改驱动 `_subtitleListVisible`（push-aside）；从
/// `_VideoSidePanelKind` 删除 subtitleList 枚举值；给 push-aside 面板补点外关闭。
///
/// media_kit 在 headless test 跑不起真视频 widget，故断言源码层的可见性路由与结构。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();
  });

  test('字幕列表枚举已从 overlay side-panel 系统移除（subtitleList 不再是 _VideoSidePanelKind）',
      () {
    final int enumStart = src.indexOf('enum _VideoSidePanelKind {');
    expect(enumStart, greaterThan(-1), reason: '应有 _VideoSidePanelKind 枚举');
    final int enumEnd = src.indexOf('}', enumStart);
    final String enumBody = src.substring(enumStart, enumEnd);
    expect(
      enumBody.contains('subtitleList'),
      isFalse,
      reason: 'subtitleList 已改 push-aside，不应再是 overlay 面板 kind',
    );
  });

  test('_toggleSubtitleJumpList 驱动 _subtitleListVisible（push-aside），不走 overlay',
      () {
    final int start = src.indexOf('void _toggleSubtitleJumpList() {');
    expect(start, greaterThan(-1), reason: '应有 _toggleSubtitleJumpList 方法');
    final int end = src.indexOf('\n  }', start);
    final String body = src.substring(start, end);
    expect(
      body.contains('_subtitleListVisible.value'),
      isTrue,
      reason: '应翻转 push-aside 可见性 _subtitleListVisible',
    );
    expect(
      body.contains('_showVideoSidePanel(_VideoSidePanelKind.subtitleList'),
      isFalse,
      reason: '不应再经 overlay side-panel 系统开字幕列表',
    );
  });

  test('字幕列表与浮层互斥：开 push-aside 列表先关浮层，开浮层关 push-aside 列表', () {
    // _toggleSubtitleJumpList 开列表前关浮层。
    final int toggleStart = src.indexOf('void _toggleSubtitleJumpList() {');
    final int toggleEnd = src.indexOf('\n  }', toggleStart);
    final String toggleBody = src.substring(toggleStart, toggleEnd);
    expect(
      toggleBody.contains('_hideVideoSidePanel()'),
      isTrue,
      reason: '开 push-aside 字幕列表前应关掉打开的浮层',
    );
    // _showVideoSidePanel 开浮层时关 push-aside 列表。
    final int showStart = src.indexOf('void _showVideoSidePanel(');
    expect(showStart, greaterThan(-1));
    final int showEnd =
        src.indexOf('\n  void _hideVideoSidePanel()', showStart);
    expect(showEnd, greaterThan(showStart));
    final String showBody = src.substring(showStart, showEnd);
    expect(
      showBody.contains('_subtitleListVisible.value = false'),
      isTrue,
      reason: '开任何浮层都应关掉 push-aside 字幕列表',
    );
  });

  test('push-aside 面板有点外关闭途径（点画面区关列表）', () {
    final int start = src.indexOf('Widget _videoWithSubtitlePanel(');
    expect(start, greaterThan(-1),
        reason: '应有 push-aside 布局 _videoWithSubtitlePanel');
    final int end = src.indexOf('\n  }', start);
    final String body = src.substring(start, end);
    // 可见时画面区叠 opaque barrier，点画面 → _subtitleListVisible=false。
    expect(
      body.contains('HitTestBehavior.opaque'),
      isTrue,
      reason: '应有吃掉点击的 barrier，避免冒泡到下方控制条',
    );
    expect(
      body.contains('_subtitleListVisible.value = false'),
      isTrue,
      reason: '点画面/外部应关闭 push-aside 字幕列表',
    );
  });

  test('删除了 overlay 版 _buildSubtitleListSidePanel（已无 overlay 路径）', () {
    expect(
      src.contains('Widget _buildSubtitleListSidePanel('),
      isFalse,
      reason: 'overlay 版字幕列表面板构造器应随 push-aside 改造删除',
    );
  });
}
