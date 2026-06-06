import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：视频页（HomeVideoPage）顶栏必须有「视频统计」入口，且导航到
/// VideoStatisticsPage。与书架页的阅读统计入口位置对等（一个在书架、一个在视频）。
void main() {
  final File src = File('lib/src/pages/implementations/home_video_page.dart');

  test('home_video_page imports VideoStatisticsPage', () {
    final String text = src.readAsStringSync();
    expect(
      text.contains(
          "import 'package:hibiki/src/pages/implementations/video_statistics_page.dart';"),
      isTrue,
      reason: '视频页应导入 VideoStatisticsPage',
    );
  });

  test('home_video_page toolbar has a statistics IconButton', () {
    final String text = src.readAsStringSync();
    expect(text.contains('t.video_statistics'), isTrue,
        reason: '统计按钮 tooltip 应使用 t.video_statistics');
    expect(text.contains('Icons.bar_chart_outlined'), isTrue,
        reason: '统计入口应使用 bar_chart 图标（与书架阅读统计入口一致）');
    expect(text.contains('_openStatistics'), isTrue,
        reason: '应有 _openStatistics 处理器');
  });

  test('_openStatistics navigates to VideoStatisticsPage', () {
    final String text = src.readAsStringSync();
    final int idx = text.indexOf('void _openStatistics()');
    expect(idx, greaterThanOrEqualTo(0), reason: '应定义 _openStatistics 方法');
    final String body = text.substring(idx, idx + 220);
    expect(body.contains('Navigator.push'), isTrue);
    expect(body.contains('VideoStatisticsPage()'), isTrue,
        reason: '_openStatistics 应 push VideoStatisticsPage');
  });
}
