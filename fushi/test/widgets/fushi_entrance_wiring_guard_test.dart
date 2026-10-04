import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-10 动效重做的接入面守卫：PR #1905 只给书架散书网格接了错峰进场，
/// 用户实测「视频那块手感还是之前那样、设置页也要做」（2026-10-04）。这里钉住
/// 视频库（墙格 / 全部视频网格 / 首页横滚行）与设置（分类列表 / 详情分组）都在
/// [FushiEntranceScope] 下用 [FushiStaggeredEntrance] 包卡，防止重构时静默丢掉。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('视频库三种卡片容器都接入错峰进场，切分区重开窗口', () {
    final String src = read(
      'lib/src/pages/implementations/home_video_page.dart',
    );
    expect(src, contains('FushiEntranceScope('));
    expect(
      src,
      contains('replayKey: widget.section'),
      reason: '三个分区共用一个 State，切分区必须重开进场窗口',
    );
    for (final String orientation in <String>['portrait', 'landscape']) {
      expect(
        src,
        contains(
          'child: cells[index].build(VideoCardOrientation.$orientation)',
        ),
        reason: '$orientation 网格格子应包在 FushiStaggeredEntrance 里',
      );
    }
    expect(src, contains('child: items[i].build()'));
    expect(
      RegExp(r'FushiStaggeredEntrance\(').allMatches(src).length,
      greaterThanOrEqualTo(3),
    );
  });

  test('设置分类列表与详情分组都接入错峰进场', () {
    final String src = read('lib/src/settings/material_settings_renderer.dart');
    expect(
      RegExp(r'FushiEntranceScope\(').allMatches(src).length,
      greaterThanOrEqualTo(3),
      reason: '分类列表 / shrinkWrap 详情 / 自滚动详情三处各一个窗口',
    );
    expect(
      RegExp(r'FushiStaggeredEntrance\(').allMatches(src).length,
      greaterThanOrEqualTo(2),
    );
  });
}
