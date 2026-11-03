import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「下拉 = 手动同步」的接线守卫。
///
/// 需求：书架 / 视频 / 词典三页下拉刷新时，除了刷新互联远端列表，还要跑一遍云备份 +
/// 互联同步。实现方式是把设置页「立即同步」那 75 行（跑同步 + 三种 outcome 提示 +
/// **逐通道**冲突呈现 + 鉴权失效登出）抽成单点 [runManualSyncWithFeedback]，四个入口
/// 共用。
///
/// 这里钉住的是**单点**这件事本身：一旦有人图省事把 `runManualFullSync` 直接抄回某个
/// 页面，冲突就会用错通道的后端去 apply（写错端），或者鉴权失效后卡在无效会话里 ——
/// 这两个坑不会让编译报错，也不会让别的测试变红，只会在真机上表现成难查的数据错乱。
///
/// 页面运行时表面在 headless 测试里挂不稳（AppModel 未初始化），故用源码扫描锁不变式；
/// 词典页的实际手势行为另有 widget 测试（home_dictionary_pull_to_sync_test.dart）。
void main() {
  String read(String path) => File(path).readAsStringSync();

  /// 截取 [src] 中从 [signature] 开始、长度 [span] 的片段（够覆盖一个短方法体）。
  String bodyAfter(String src, String signature, {int span = 700}) {
    final int start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '找不到 $signature');
    final int end = (start + span) > src.length ? src.length : start + span;
    return src.substring(start, end);
  }

  final Map<String, ({String file, String signature})> pullEntries =
      <String, ({String file, String signature})>{
        '书架': (
          file: 'lib/src/pages/implementations/reader_history/remote.part.dart',
          signature: 'Future<void> _pullToRefreshBooks() async {',
        ),
        '视频': (
          file: 'lib/src/pages/implementations/home_video_page.dart',
          signature: 'Future<void> _pullToRefresh() async {',
        ),
        '词典': (
          file: 'lib/src/pages/implementations/home_dictionary_page.dart',
          signature: 'Future<void> _pullToRefreshDictionary() async {',
        ),
      };

  pullEntries.forEach((String page, ({String file, String signature}) e) {
    test('$page页下拉刷新调用共享的 runManualSyncWithFeedback', () {
      final String body = bodyAfter(read(e.file), e.signature);
      expect(
        body,
        contains('runManualSyncWithFeedback('),
        reason: '$page页下拉必须跑手动同步，而不只是刷列表',
      );
    });

    test('$page页下拉不弹「同步未配置」噪音', () {
      final String body = bodyAfter(read(e.file), e.signature);
      expect(
        body,
        contains('announceNotConfigured: false'),
        reason:
            '没配同步后端的用户每次下拉都被弹一句「同步不可用」是纯噪音；'
            '此时下拉应静默退化成纯列表刷新',
      );
      expect(
        body,
        contains('announceBusy: false'),
        reason: '已有同步在飞时用户下拉，数据照样会更新，不该再打断他',
      );
    });

    test('$page页不得自己复制一份 runManualFullSync 调用', () {
      expect(
        read(e.file),
        isNot(contains('runManualFullSync(')),
        reason:
            '同步 + 反馈只能有一份实现（manual_sync_ui.dart）：复制出去的那份迟早'
            '漏掉逐通道冲突呈现（写错端）或鉴权失效登出',
      );
    });
  });

  test('设置页「立即同步」与下拉同步走同一入口', () {
    final String src = read(
      'lib/src/sync/sync_settings_schema/actions.part.dart',
    );
    final String body = bodyAfter(src, 'Future<void> _syncNow() async {');
    expect(body, contains('runManualSyncWithFeedback('));
    expect(
      src,
      isNot(contains('runManualFullSync(')),
      reason: '设置页也必须是共享入口的壳，否则两条路径会各自演化',
    );
  });

  test('共享入口保留逐通道冲突呈现与鉴权失效登出', () {
    final String src = read('lib/src/sync/manual_sync_ui.dart');
    // 合并报告的冲突可能来自互联通道，用云后端 apply 会写错端（option B 双通道）。
    expect(src, contains('for (final ManualSyncChannelReport channel in'));
    expect(src, contains('backend: channel.backend'));
    expect(src, contains('source: ConflictSource.manual'));
    // TODO-836：鉴权失效必须登出，否则账号行不退回「未登录」，用户无从重新登录。
    expect(src, contains('on SyncAuthError catch'));
    expect(src, contains('await backend.signOut(repo: repo)'));
  });

  // 2026-11-03 顶栏让位：同步进度不再在各库页顶部铺两行横幅（常驻挤掉近一行
  // 封面），改由首页外壳的「后台任务」入口（右下 FAB / MD3 底栏 FAB / Apple
  // 大标题行，外圈分段进度环）统一承载——它听全局状态，对任何在飞的同步都亮。
  test('首页各 tab 不再挂同步横幅，进度归外壳的「后台任务」入口', () {
    for (final String file in <String>[
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
      'lib/src/pages/implementations/home_video_page.dart',
      'lib/src/pages/implementations/home_dictionary_page.dart',
      'lib/src/pages/implementations/srs/srs_deck_list_page.dart',
      'lib/src/pages/implementations/music/music_library_page.dart',
      'lib/src/pages/implementations/home_game_page.dart',
      'lib/src/pages/implementations/home_dashboard_page.dart',
    ]) {
      expect(
        read(file),
        isNot(contains('SyncProgressBanner(')),
        reason: '$file 又挂回了顶部同步横幅：进度已由外壳「后台任务」入口承载',
      );
    }
    final String home = read('lib/src/pages/implementations/home_page.dart');
    expect(home, contains('syncBackgroundTasksListenable'));
    expect(home, contains('...syncBackgroundTasks(),'));
    expect(home, contains('BackgroundTasksGlyph('));
  });

  test('推出去的「同步与历史」页看不到外壳入口，仍挂同步横幅', () {
    expect(
      read('lib/src/pages/implementations/srs/srs_history_page.dart'),
      contains('const SyncProgressBanner()'),
    );
  });

  test('同步进度（横幅与后台任务入口）也听复习同步的进度', () {
    for (final String file in <String>[
      'lib/src/sync/sync_progress_banner.dart',
      'lib/src/sync/background_tasks_indicator.dart',
    ]) {
      expect(
        read(file),
        contains('srsSyncProgress'),
        reason: '$file：复习同步不经 syncInProgress，不听它就会出现「同步十几分钟、界面零反馈」',
      );
    }
  });

  test('词典页查询结果屏不叠下拉刷新（手势与「清空查询」冲突）', () {
    final String src = read(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    );
    final String body = bodyAfter(src, 'Widget _buildBody() {', span: 500);
    final int queryReturn = body.indexOf('return _buildQueryBody();');
    final int refreshStart = body.indexOf('RefreshIndicator(');
    expect(queryReturn, isNonNegative);
    expect(
      refreshStart,
      greaterThan(queryReturn),
      reason:
          '有活跃查询时必须在包 RefreshIndicator 之前就 return —— 结果屏的下拉'
          '已经是 _clearSearchFromResultPull（清空查询），两个手势不能抢',
    );
  });
}
