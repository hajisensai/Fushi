import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：视频播放设置面板已从 bespoke 深色单列 `showModalBottomSheet` 迁移到与阅读器
/// 同款 master-detail（`VideoQuickSettingsSheet` + 桌面 `HibikiDialogFrame(900)` /
/// 移动 `adaptiveModalSheet`）。防回归退回旧的黑底单列 StatefulBuilder/ChoiceChip。
String _between(String source, String start, String end) {
  final int s = source.indexOf(start);
  expect(s, isNonNegative, reason: 'missing marker: $start');
  final int e = source.indexOf(end, s);
  expect(e, isNonNegative, reason: 'missing marker: $end');
  return source.substring(s, e);
}

void main() {
  test('video player settings uses the shared master-detail sheet', () {
    final String source =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();
    final String method = _between(
      source,
      'void _showPlayerSettings() {',
      '_openShaderDialog() async {',
    );

    // 用共享面板 + 与阅读器一致的呈现（桌面分栏宽画布 / 移动 bottom sheet）。
    expect(method, contains('VideoQuickSettingsSheet('));
    expect(method, contains('HibikiDialogFrame('));
    expect(method, contains('maxWidth: 900'));
    expect(method, contains('scrollable: false'));
    expect(method, contains('adaptiveModalSheet<void>('));
    expect(method, contains('isDesktopPlatform'));

    // 旧 bespoke 深色单列面板已移除（防回归）。
    expect(method, isNot(contains('showModalBottomSheet')),
        reason: '播放设置不再走 bespoke bottom sheet');
    expect(method, isNot(contains('Colors.black87')));
    expect(method, isNot(contains('StatefulBuilder')));
    expect(method, isNot(contains('ChoiceChip')));
  });

  test('VideoQuickSettingsSheet mirrors the reader master-detail skeleton', () {
    final String source =
        File('lib/src/media/video/video_quick_settings_sheet.dart')
            .readAsStringSync();

    expect(source, contains('class VideoQuickSettingsSheet'));
    // 与阅读器同源的「不套外层滚动 + 宽窗撑满有界高度」范式（BUG-096）。
    expect(source, contains('HibikiModalSheetFrame('));
    expect(source, contains('scrollable: false'));
    expect(source, contains('MaterialSupportingPaneLayout('));
    expect(source, contains('minSplitWidth: 640'));
    expect(source, contains('SupportingPaneSide.start'));
    expect(source, contains('height: constraints.maxHeight'));
    expect(source, contains('constraints.maxWidth >= 640'));
    // 左父菜单单选高亮（pill），无 chevron 误导 push。
    expect(source, contains('HibikiListItemSelectedShape.pill'));
    // 右 pane 按选中 id KeyedSubtree，防 Element 复用副作用。
    expect(source, contains('KeyedSubtree('));
    expect(source, contains("_subPage ?? 'playback'"));
    // 四个分类齐全。
    for (final String id in <String>[
      "id: 'playback'",
      "id: 'shaders'",
      "id: 'mpv'",
      "id: 'subtitle'",
    ]) {
      expect(source, contains(id), reason: 'missing category $id');
    }
  });
}
