import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 根因守卫（BUG-894：互联远端视频看完返回即重拉列表）。
///
/// 症状——连远端视频，点进去看一段（>0 秒）再返回，远端视频卡整片闪空、重新联网
/// 拉取。真根因：从播放器返回走 `_open()` → `_refresh()`，而旧 `_refresh()` 无条件
/// `_remoteFuture = _loadRemoteVideos()` 连带重换远端 future；远端那层 FutureBuilder
/// 无缓存顶值，future 一换 snapshot.data 归 null → 远端卡清空重拉。远端清单不因本地
/// 播放而变，此重拉纯属多余。
///
/// 修复——`_refresh({bool remote = false})` 默认只刷本地；只有真正改变远端来源的
/// `_openManageSources` 传 `remote: true`；远端显式刷新仍由下拉 `_pullToRefresh` 承担。
///
/// HomeVideoPage 运行时表面在 headless 测试里无法稳定挂载（AppModel 未初始化），故
/// 这里用源码扫描锁住不变式：`_refresh` 的远端重拉必须门控在 `remote` 之后，且从
/// 播放器返回的刷新是本地 `_refresh()`（不带 `remote: true`）。
void main() {
  final String src = File(
    'lib/src/pages/implementations/home_video_page.dart',
  ).readAsStringSync();

  test('_refresh 带 remote 开关且默认关（本地刷新不重拉远端）', () {
    expect(
      src.contains('void _refresh({bool remote = false})'),
      isTrue,
      reason: '_refresh 必须有 remote 开关且默认 false，避免本地刷新连带重拉远端',
    );
  });

  test('_refresh 内远端重拉必须门控在 remote 之后', () {
    final int start = src.indexOf('void _refresh({bool remote = false})');
    expect(start, isNonNegative);
    // 截取 _refresh 方法体（到下一个方法/文档注释起始）。
    final int bodyEnd = src.indexOf('/// 下拉刷新', start);
    expect(bodyEnd, greaterThan(start),
        reason: '_refresh 方法体后应紧接 _pullToRefresh 文档注释');
    final String body = src.substring(start, bodyEnd);
    expect(
      body.contains('if (remote) _remoteFuture = _loadRemoteVideos();'),
      isTrue,
      reason: '_refresh 里远端重拉必须门控在 remote 之后（默认路径不重拉）',
    );
    // 断言方法体里没有无条件（未门控）的远端重拉。
    expect(
      body.contains('\n      _remoteFuture = _loadRemoteVideos();'),
      isFalse,
      reason: '_refresh 不得有无条件的 _remoteFuture 重换（回归即恢复闪空重拉）',
    );
  });

  test('从播放器返回后的刷新不碰远端清单（BUG-2376 后改走窄刷新）', () {
    // _open() 返回后刷新继续观看 hero / 进度，只需本地。BUG-2376 起这条路径从
    // 全量 `_refresh()` 收窄为 `_refreshAfterPlayback()`（只重读书架 + 最近观看），
    // 本守卫钉的是「不重拉远端」这个不变式，不是当年那一行的写法。
    expect(
      src.contains('从播放器返回后刷新'),
      isTrue,
      reason: '_open 返回后应有本地刷新注释锚点',
    );
    final int anchor = src.indexOf('从播放器返回后刷新');
    final String tail = src.substring(anchor, anchor + 300);
    expect(
      tail.contains('if (mounted) _refreshAfterPlayback();'),
      isTrue,
      reason: '播放器返回只刷本地，不得传 remote: true',
    );
    expect(
      tail.contains('_refresh(remote: true)'),
      isFalse,
      reason: '播放器返回不得重拉远端清单',
    );
    // 窄刷新自身也不得碰远端 future——远端清单不因本地播放而变。
    final int narrow = src.indexOf('void _refreshAfterPlayback() {');
    expect(narrow, isNonNegative, reason: '找不到 _refreshAfterPlayback');
    final int narrowEnd = src.indexOf('\n  }\n', narrow);
    final String narrowBody = src.substring(narrow, narrowEnd);
    expect(
      narrowBody.contains('_remoteFuture'),
      isFalse,
      reason: '窄刷新不得重换远端 future（回归即恢复 BUG-894 的闪空重拉）',
    );
  });

  test('只有 _openManageSources 传 remote: true（改变远端来源才重拉）', () {
    expect(
      src.contains('if (mounted) _refresh(remote: true);'),
      isTrue,
      reason: '管理互联源后必须重拉远端清单（remote: true）',
    );
    // 全文件里 remote: true 的刷新调用应恰好 1 处（仅管理源）。
    final int count =
        RegExp(r'_refresh\(remote: true\)').allMatches(src).length;
    expect(count, 1, reason: '当前仅管理互联源需要 remote: true 刷新');
  });

  // ── BUG-2567：桌面端必须有**看得见**的手动刷新入口 ──────────────────
  //
  // 「刷新」按钮曾以「下拉刷新仍是手动同步入口」为由删掉，但那条理由在桌面端不
  // 成立：[RefreshIndicator] 只响应 ScrollBehavior.dragDevices 里的设备，而
  // Flutter 的默认集合**不含鼠标**，本页也没有任何 dragDevices 覆写。于是桌面
  // 用户手里一个手动刷新入口都没有——媒体服务器登录后清单被 TTL 挡住、或用户关掉
  // 「进影片页时自动列出」时，就彻底卡在空库上，正是用户报的「电脑版刷新不了」。

  test('页头有刷新按钮，且走的是下拉刷新同一条路径', () {
    final int start = src.indexOf('Widget _buildPageHeader() {');
    expect(start, isNonNegative, reason: '找不到 _buildPageHeader');
    final int end = src.indexOf('\n  /// 长按 / 桌面右键远端视频卡', start);
    expect(end, greaterThan(start), reason: '_buildPageHeader 方法体定位失败');
    final String header = src.substring(start, end);

    expect(
      header.contains("ValueKey<String>('video-library-refresh')"),
      isTrue,
      reason: '页头必须有刷新按钮——桌面端没有别的手动刷新入口',
    );
    expect(
      header.contains('onTap: _headerRefreshBusy ? null : _refreshFromHeader'),
      isTrue,
      reason: '刷新按钮必须接 _refreshFromHeader，且 busy 期间不可重入',
    );
    expect(
      header.contains('busy: _headerRefreshBusy'),
      isTrue,
      reason: '全库枚举动辄几十秒，不标 busy 就是「按了没反应、于是连按五次」',
    );
  });

  test('_refreshFromHeader 只是 _pullToRefresh 加一层 busy 记账，不另写刷新逻辑', () {
    final int start = src.indexOf('Future<void> _refreshFromHeader() async {');
    expect(start, isNonNegative, reason: '找不到 _refreshFromHeader');
    final int end = src.indexOf('\n  }\n', start);
    final String body = src.substring(start, end);

    expect(
      body.contains('await _pullToRefresh();'),
      isTrue,
      reason: '两个刷新入口必须共用一条路径，否则手动同步 / TTL 穿透 / '
          '封面回填记账迟早在其中一边漏掉',
    );
    expect(
      body.contains('_loadRemoteVideos('),
      isFalse,
      reason: '页头刷新不得自绕一套取数（绕过去就丢了手动同步与记账清空）',
    );
  });
}
