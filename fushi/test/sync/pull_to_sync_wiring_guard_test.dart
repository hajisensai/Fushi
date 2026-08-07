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
        reason: '没配同步后端的用户每次下拉都被弹一句「同步不可用」是纯噪音；'
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
        reason: '同步 + 反馈只能有一份实现（manual_sync_ui.dart）：复制出去的那份迟早'
            '漏掉逐通道冲突呈现（写错端）或鉴权失效登出',
      );
    });
  });

  test('设置页「立即同步」与下拉同步走同一入口', () {
    final String src =
        read('lib/src/sync/sync_settings_schema/actions.part.dart');
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

  test('三页都挂了同步进度条（下拉可能跑几十秒）', () {
    for (final String file in <String>[
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
      'lib/src/pages/implementations/home_video_page.dart',
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ]) {
      expect(
        read(file),
        contains('const SyncProgressBanner()'),
        reason: '$file 缺同步进度条：光一个 RefreshIndicator 转圈看不出跑到哪一步',
      );
    }
  });

  test('词典页查询结果屏不叠下拉刷新（手势与「清空查询」冲突）', () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');
    final String body = bodyAfter(src, 'Widget _buildBody() {', span: 500);
    final int queryReturn = body.indexOf('return _buildQueryBody();');
    final int refreshStart = body.indexOf('RefreshIndicator(');
    expect(queryReturn, isNonNegative);
    expect(
      refreshStart,
      greaterThan(queryReturn),
      reason: '有活跃查询时必须在包 RefreshIndicator 之前就 return —— 结果屏的下拉'
          '已经是 _clearSearchFromResultPull（清空查询），两个手势不能抢',
    );
  });
}
