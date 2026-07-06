import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// TODO-1254：视频制卡成功提示（`card_exported` / `card_overwritten`，走
/// `_showOsd(..., prominent: true)`）的定位守卫。
///
/// media_kit 跑不了 headless，全屏视频 + OSD 无法在 widget 测试里真实驱动，故把
/// 「制卡成功 OSD 锚在左上角、不居中遮挡画面」的不变量钉在 `volume_osd.part.dart`
/// 的 `_buildOsdCard` 接线点（参照 TODO-101 沉浸锁 / TODO-069 字幕守卫范式）。
///
/// TODO-971 曾把突出变体（制卡成功）改成 `Alignment.center`，居中会遮挡正在看的画面；
/// 用户报「卡片已覆盖到『…』提示挡在屏幕正中」。修复后突出变体保留醒目卡片样式
/// （更大字号 / 厚卡片 / 勾图标），但定位回归左上角（与被动 OSD 同锚点）。
String _osdCardBody(String src) {
  final int start = src.indexOf('Widget _buildOsdCard(');
  expect(start, greaterThanOrEqualTo(0), reason: '缺 _buildOsdCard');
  // 方法自身的 2 空格闭合作段终点（照搬本仓库其它合并语料守卫的段截断范式）。
  final int end = src.indexOf('\n  }', start);
  expect(end, greaterThan(start), reason: '_buildOsdCard 未闭合');
  return src.substring(start, end);
}

void main() {
  late String src;

  setUpAll(() {
    src = readVideoHibikiSource();
  });

  test('制卡成功 OSD 触发保留：_showOsd(described.message, prominent: true)', () {
    // 只改定位、不动内容 / 触发：突出制卡提示仍走 prominent 变体。
    expect(
      src.contains('_showOsd(described.message, prominent: true);'),
      isTrue,
      reason: '制卡成功提示必须仍走 prominent OSD（内容 / 触发不得改）',
    );
  });

  test('OSD 卡片锚定左上角，突出变体不再居中（TODO-1254）', () {
    final String body = _osdCardBody(src);
    // 定位常量必须是左上角。
    expect(
      body.contains('AlignmentGeometry alignment = Alignment.topLeft'),
      isTrue,
      reason: 'OSD 卡片必须锚在左上角（Alignment.topLeft）',
    );
    // 防回归：不得再把（任何变体的）OSD 定位设成居中。
    expect(
      body.contains('Alignment.center'),
      isFalse,
      reason: 'OSD 卡片不得居中（TODO-1254 回归：居中会遮挡画面）',
    );
    // 突出变体不得再用 all(24) 的居中式外边距，改与被动 OSD 同款左上外边距。
    expect(
      body.contains('EdgeInsets.only(left: 16, top: 52)'),
      isTrue,
      reason: 'OSD 卡片外边距应锚左上（left:16, top:52，避开顶栏）',
    );
  });
}
