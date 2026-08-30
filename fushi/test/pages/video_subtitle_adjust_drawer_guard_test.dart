import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 字幕调整走底部抽屉（2026-08 字幕工作台 PR-C）的接线守卫：
/// - `_showPlayerSettings(initialCategory: 'subtitle')` 分流到 `subtitleAdjust` kind；
/// - `subtitleAdjust` 的内容与 `settings` 是同一份快捷设置面板（不另造第二套字幕设置）；
/// - `subtitleAdjust` 的容器是 [VideoTranslucentBottomDrawer]，且包在 FushiAppUiScale 里
///   （与设置侧栏同一缩放纪律）；
/// - 三处字幕入口（字幕轨按钮 / 右键字幕轨 / 字幕加载遮罩）仍经 `_showPlayerSettings`
///   传 'subtitle'，没有绕过分流点各写一个 kind。
void main() {
  final String page = File(
    'lib/src/pages/implementations/video_fushi_page.dart',
  ).readAsStringSync();
  final String sidePanel = File(
    'lib/src/pages/implementations/video_fushi/side_panel.part.dart',
  ).readAsStringSync();
  final String subtitlePart = File(
    'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
  ).readAsStringSync();

  String region(String src, String start, String end) {
    final int a = src.indexOf(start);
    expect(a, greaterThanOrEqualTo(0), reason: 'missing anchor: $start');
    final int b = src.indexOf(end, a + start.length);
    expect(b, greaterThan(a), reason: 'missing end anchor: $end');
    return src.substring(a, b);
  }

  test('subtitle 分类在 _showPlayerSettings 一处分流到 subtitleAdjust', () {
    final String show = region(
      page,
      'void _showPlayerSettings({',
      '/// 把用户挑选/拖入的外部字幕文件',
    );
    expect(show, contains("initialCategory == 'subtitle'"));
    expect(show, contains('_VideoSidePanelKind.subtitleAdjust'));
    expect(show, contains('_VideoSidePanelKind.settings'));
    // 调用方不许自己挑 kind：整棵 video_fushi 树里只有分流点提到 subtitleAdjust。
    expect(
      RegExp(r'_VideoSidePanelKind\.subtitleAdjust').allMatches(subtitlePart),
      isEmpty,
    );
  });

  test('subtitleAdjust 与 settings 共用同一份快捷设置面板', () {
    final String child = region(
      sidePanel,
      'Widget _buildVideoSidePanelChild(',
      'Widget _buildVideoSidePanelContent(',
    );
    final int settingsCase = child.indexOf(
      'case _VideoSidePanelKind.settings:',
    );
    final int adjustCase = child.indexOf(
      'case _VideoSidePanelKind.subtitleAdjust:',
    );
    final int sheet = child.indexOf('return _buildVideoQuickSettingsSheet();');
    expect(settingsCase, greaterThanOrEqualTo(0));
    expect(adjustCase, greaterThan(settingsCase));
    expect(
      sheet,
      greaterThan(adjustCase),
      reason: 'subtitleAdjust 必须 fall-through 到同一个 return',
    );
  });

  test('subtitleAdjust 的容器是底部抽屉并包 FushiAppUiScale', () {
    final String content = region(
      sidePanel,
      'Widget _buildVideoSidePanelContent(',
      '\n}\n',
    );
    final int guard = content.indexOf(
      'if (kind == _VideoSidePanelKind.subtitleAdjust) {',
    );
    expect(guard, greaterThanOrEqualTo(0));
    final int drawer = content.indexOf('VideoTranslucentBottomDrawer(', guard);
    final int scale = content.indexOf('FushiAppUiScale(', guard);
    expect(drawer, greaterThan(guard));
    expect(scale, greaterThan(guard));
    expect(scale, lessThan(drawer), reason: '缩放包在抽屉外层');
    // BUG-254：浮层不带 X，关闭只走 overlay 的点外 barrier——抽屉块里不许出现 onClose
    // （侧栏块保留它给 barrier/其它调用方复用，故只查抽屉那一段）。
    final int sidePanelStart = content.indexOf(
      'VideoTranslucentSidePanel(',
      guard,
    );
    expect(sidePanelStart, greaterThan(drawer));
    expect(
      content.substring(guard, sidePanelStart),
      isNot(contains('onClose:')),
    );
  });

  test('三处字幕入口仍经 _showPlayerSettings 传 subtitle', () {
    expect(
      RegExp(
        r"_showPlayerSettings\([^)]*initialCategory: 'subtitle'",
      ).allMatches(subtitlePart).length,
      greaterThanOrEqualTo(2),
    );
  });
}
