import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// TODO-2490 / TODO-2497 源码扫描守卫：卡片/hero 标题溢出 Tooltip 的接线登记表。
///
/// [ShelfTitleOverflowTooltip] 组件行为本身有 widget 测试
/// （`test/widgets/shelf_title_overflow_tooltip_test.dart`）；但「哪些页面的哪些
/// 标题必须接它」此前零守卫——重写页面时静默丢掉 Tooltip 不会有任何测试变红
/// （PR#652 审查确认的缺口）。本守卫按文件登记**最低接线数**：拆掉任何一处即红；
/// 新增接线点后把数字抬上去。
void main() {
  const String token = 'ShelfTitleOverflowTooltip(';

  int countIn(String path) {
    final File file = File(path);
    expect(file.existsSync(), isTrue, reason: '缺失 $path');
    // 共享词法掩码后再数：注释里提到组件名（迁移说明/TODO）不算接线，
    // 也堵「把接线挪进注释」的假绿。
    return token.allMatches(maskComments(file.readAsStringSync())).length;
  }

  test('视频首页：墙卡（本地/远端/合集）+ hero 轮播 + 横滚行卡都接标题溢出 Tooltip', () {
    // 5 处：合集封面卡 / 远端占位卡 / 本地散卡 / hero 轮播标题 / 横滚行通用卡。
    expect(
      countIn('lib/src/pages/implementations/home_video_page.dart'),
      greaterThanOrEqualTo(5),
      reason: '视频首页标题溢出 Tooltip 接线（TODO-2490/2486）不得少于 5 处：'
          '合集卡、远端卡、本地卡、hero 轮播标题、横滚行卡',
    );
  });

  test('书架：继续阅读 hero 标题接标题溢出 Tooltip（TODO-2497）', () {
    expect(
      countIn('lib/src/pages/implementations/reader_hibiki_history_page.dart'),
      greaterThanOrEqualTo(1),
      reason: '书架继续阅读 hero 标题必须接 ShelfTitleOverflowTooltip',
    );
  });

  test('游戏首页：hero / 随机卡 / 时间轴标题都接标题溢出 Tooltip（TODO-2497）', () {
    expect(
      countIn('lib/src/pages/implementations/galgame_home_page.dart'),
      greaterThanOrEqualTo(3),
      reason: '游戏首页 hero、随机游戏卡、活动时间轴三处标题必须接 '
          'ShelfTitleOverflowTooltip',
    );
  });
}
