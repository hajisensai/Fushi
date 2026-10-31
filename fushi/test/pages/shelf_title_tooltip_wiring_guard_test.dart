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

  test('视频首页：墙卡（本地/远端/合集）+ 横滚行卡都接标题溢出 Tooltip', () {
    // 2026-10-25 材质库页：卡片文字块统一成 [ShelfCardMeta]（标题一行，内部
    // 经 ShelfTitleLine 接 ShelfTitleOverflowTooltip），视频页经 `_videoCardMeta`
    // 一处装配。登记的是 4 个调用点：合集封面卡 / 远端占位卡 / 本地散卡 / 横滚行
    // 通用卡；组件内部的接线由下一条守卫钉住。
    final String src = maskComments(
      File(
        'lib/src/pages/implementations/home_video_page.dart',
      ).readAsStringSync(),
    );
    expect(
      '_videoCardMeta('.allMatches(src).length - 1,
      greaterThanOrEqualTo(4),
      reason:
          '视频首页标题溢出 Tooltip 接线（TODO-2490/2486）不得少于 4 处：'
          '合集卡、远端卡、本地卡、横滚行卡',
    );
    expect(src.contains('ShelfCardMeta('), isTrue);
  });

  test('ShelfCardMeta 的标题行接标题溢出 Tooltip', () {
    expect(
      countIn('lib/src/utils/components/shelf_cover_material.dart'),
      greaterThanOrEqualTo(1),
      reason: '材质库页文字块的单行标题必须接 ShelfTitleOverflowTooltip',
    );
  });

  test('书架：继续阅读 hero 标题接标题溢出 Tooltip（TODO-2497）', () {
    // 2026-10-28 起书架 hero 是共用的 FushiContinueHero，Tooltip 接在组件里。
    final String shelf = maskComments(
      File(
        'lib/src/pages/implementations/reader_fushi_history_page.dart',
      ).readAsStringSync(),
    );
    expect(
      shelf.contains('FushiContinueSpotlight('),
      isTrue,
      reason:
          '书架继续阅读 hero 必须走共用的 FushiContinueSpotlight（主卡皮是 FushiContinueHero）',
    );
    expect(
      countIn('lib/src/utils/components/fushi_continue_hero.dart'),
      greaterThanOrEqualTo(1),
      reason: 'FushiContinueHero 标题必须接 ShelfTitleOverflowTooltip',
    );
  });

  test('游戏首页：hero / 随机卡 / 时间轴标题都接标题溢出 Tooltip（TODO-2497）', () {
    expect(
      countIn('lib/src/pages/implementations/galgame_home_page.dart'),
      greaterThanOrEqualTo(3),
      reason:
          '游戏首页 hero、随机游戏卡、活动时间轴三处标题必须接 '
          'ShelfTitleOverflowTooltip',
    );
  });
}
