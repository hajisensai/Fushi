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

  test('从播放器返回后的刷新是本地 _refresh()（不带 remote）', () {
    // _open() 返回后刷新继续观看 hero / 进度，只需本地。
    expect(
      src.contains('从播放器返回后刷新'),
      isTrue,
      reason: '_open 返回后应有本地刷新注释锚点',
    );
    final int anchor = src.indexOf('从播放器返回后刷新');
    final String tail = src.substring(anchor, anchor + 300);
    expect(
      tail.contains('if (mounted) _refresh();'),
      isTrue,
      reason: '播放器返回只刷本地，不得传 remote: true',
    );
    expect(
      tail.contains('_refresh(remote: true)'),
      isFalse,
      reason: '播放器返回不得重拉远端清单',
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
}
