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
      contains('replayKey: (widget.section, firstPaintPending)'),
      reason:
          '三个分区共用一个 State，切分区必须重开进场窗口；首屏骨架换成真墙'
          '也要重开（BUG-3235），否则映射晚于窗口到达时真卡没有进场',
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

  // 2026-10-04 用户追加「所有功能全部都要做」：其余库页 / 浏览页网格同样接入。
  // 每个文件都要同时有窗口（scope）与逐项包装，缺 scope 时窗口常开、懒加载
  // 滚出的每一格都会淡入（拖影）。
  test('其余库页与浏览页网格都在进场窗口内错峰进场', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/games_library_page.dart',
      'lib/src/pages/implementations/game_stream_library_page.dart',
      'lib/src/pages/implementations/history_reader_page.dart',
      'lib/src/pages/implementations/media_server/media_server_grid_view.dart',
      // 2026-10 媒体服务器整块重做：服务器列表 / 首页（横滚行 + 库网格）/
      // 详情集列表同样接入。
      'lib/src/pages/implementations/media_server/media_server_server_list_view.dart',
      'lib/src/pages/implementations/media_server/media_server_home_view.dart',
      'lib/src/pages/implementations/media_server/media_server_detail_view.dart',
      'lib/src/pages/implementations/video_discovery_page.dart',
      'lib/src/media/online/online_source_browse_page.dart',
      'lib/src/media/manga/discovery/manga_discovery_page.dart',
      'lib/src/media/manga/interconnect/interconnect_manga_browse_page.dart',
      'lib/src/media/manga/online/mokuro_moe_catalog_view.dart',
      // 2026-10 漫画阅读器重做：「全部页面」缩略图网格。
      'lib/src/media/manga/reader/manga_reader_page_grid.dart',
      // 合集详情（视频剧集列表 / 书与游戏成员网格）与首页仪表盘分区 + 横滚行。
      'lib/src/pages/implementations/media_collection_detail_page.dart',
      'lib/src/pages/implementations/media_collection_grid_detail_page.dart',
      'lib/src/pages/implementations/home_dashboard_page.dart',
      // 2026-10 查词模块重做：查词页历史 / 最近搜索与词典管理列表。
      'lib/src/pages/implementations/home_dictionary_page.dart',
      'lib/src/pages/implementations/dictionary_dialog_page.dart',
      // 2026-10 字体库重做：样张卡网格 / 列表（含拖拽重排两种形态）。
      'lib/src/pages/implementations/custom_fonts_page.dart',
      // 2026-10-09 排行榜精简：总字数卡 / 筛选 / 榜单行与大西瓜的球。
      'lib/src/pages/implementations/leaderboard/leaderboard_tab.dart',
      'lib/src/pages/implementations/leaderboard/leaderboard_watermelon_page.dart',
    ]) {
      final String src = read(path);
      expect(src, contains('FushiEntranceScope('), reason: path);
      expect(
        src.contains('FushiStaggeredEntrance(') ||
            src.contains('fushiStaggeredItemBuilder('),
        isTrue,
        reason: path,
      );
    }
  });
}
