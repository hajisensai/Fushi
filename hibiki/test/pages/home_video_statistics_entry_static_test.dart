import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：视频页（HomeVideoPage）的「视频统计」入口必须接上导航链路——导入
/// VideoStatisticsPage、有 _openStatistics 处理器、并 push VideoStatisticsPage。
///
/// 收窄记录：按钮的存在性 + 位置（tooltip=t.video_statistics、bar_chart 图标在
/// 顶栏 actions 内且顺序钉死）已由 video_header_button_order_guard_test.dart
/// (TODO-162) 双重覆盖，故本守卫只保留导航接线 3 个 token 断言，删去脆弱的
/// substring(idx, idx+220) 窗口锚以及 t.video_statistics / Icons.bar_chart_outlined
/// 这类纯外观/位置断言（避免合法重排即转红）。
void main() {
  final File src = File('lib/src/pages/implementations/home_video_page.dart');

  test('home_video_page wires the statistics entry to VideoStatisticsPage', () {
    final String text = src.readAsStringSync();
    expect(
      text.contains(
          "import 'package:fushi/src/pages/implementations/video_statistics_page.dart';"),
      isTrue,
      reason: '视频页应导入 VideoStatisticsPage',
    );
    expect(text.contains('_openStatistics'), isTrue,
        reason: '应有 _openStatistics 处理器');
    expect(text.contains('VideoStatisticsPage()'), isTrue,
        reason: '_openStatistics 应 push VideoStatisticsPage');
  });
}
