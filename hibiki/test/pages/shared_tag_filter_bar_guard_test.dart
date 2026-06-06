import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：锁定「视频 tab 的标签栏与书架完全一致」——两页共用同一组件
/// [HibikiTagFilterBar]（内联 chip 点选筛选 + 长按拖拽重排 + 末尾管理齿轮），
/// 而不是各画一套。防回归到视频页那套「筛选图标开 sheet + 无拖拽/无管理」的旧样式。
String _read(String relative) {
  final File f = File(relative);
  if (!f.existsSync()) {
    throw StateError(
        'missing source: $relative (cwd=${Directory.current.path})');
  }
  return f.readAsStringSync();
}

void main() {
  test('共享标签栏组件存在且用 MD3 chip + 拖拽重排 + 管理动作', () {
    final String src =
        _read('lib/src/pages/implementations/tag_filter_bar.dart');
    expect(src.contains('class HibikiTagFilterBar'), isTrue);
    expect(src.contains('HibikiTagChip('), isTrue, reason: '用共享 MD3 tag chip');
    expect(src.contains('LongPressDraggable<BookTagRow>'), isTrue,
        reason: '长按拖拽重排');
    expect(src.contains('TagManagementPage'), isTrue, reason: '末尾管理标签动作');
    // 批量选择可选：视频 tab 不传，书架传。
    expect(src.contains('onToggleSelectionMode'), isTrue);
  });

  test('书架标签栏改用共享 HibikiTagFilterBar（不再内联 _TagBarContent）', () {
    final String shelf =
        _read('lib/src/pages/implementations/reader_hibiki_history_page.dart');
    expect(shelf.contains('HibikiTagFilterBar('), isTrue);
    expect(shelf.contains('class _TagBarContent'), isFalse,
        reason: '内联标签栏类应已提取为共享组件');
  });

  test('视频 tab 标签栏改用共享 HibikiTagFilterBar（与书架同一组件）', () {
    final String video =
        _read('lib/src/pages/implementations/home_video_page.dart');
    expect(video.contains('HibikiTagFilterBar('), isTrue,
        reason: '视频标签栏要和书架用同一组件');
    // 旧实现：筛选图标打开 TagFilterSheet 的 modal。
    expect(video.contains('builder: (_) => const TagFilterSheet()'), isFalse,
        reason: '不再用「筛选图标开 sheet」的旧标签栏样式');
  });
}
