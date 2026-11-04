/// 首页「继续」里互联远端补位（[RemoteContinueCandidate]）的进程级最新结果。
///
/// 远端候选只在首页算（互联开关 / 配对鉴权 / 共享 TTL 清单缓存 / 删除墓碑 / 合集收养
/// 都在那条取数链上），桌面小组件不再自己发一遍互联请求，也不在别处复刻那套过滤：
/// 首页每算完一轮就 [publish]，小组件快照（`WidgetSnapshotSource`）读 [current] 并在
/// [updates] 时重发。与 [ServerContinueFeed] 同一形态，按数据库实例（[of]）各留一份，
/// 换库（切 Profile 库 / 恢复备份）即换一份。
library;

import 'dart:async';

import 'package:fushi/src/utils/misc/dashboard_remote_merge.dart'
    show RemoteContinueCandidate;

class RemoteContinueFeed {
  RemoteContinueFeed();

  static final Expando<RemoteContinueFeed> _byOwner =
      Expando<RemoteContinueFeed>('remote-continue-feed');

  /// [owner] 一般是数据库实例。
  static RemoteContinueFeed of(Object owner) =>
      _byOwner[owner] ??= RemoteContinueFeed();

  List<RemoteContinueCandidate> _current = const <RemoteContinueCandidate>[];
  String? _deviceName;

  /// 首页最近一轮算出的远端候选（互联关闭 / 还没算过 = 空）。
  List<RemoteContinueCandidate> get current => _current;

  /// 配对时存下的 host 设备名（来源标注用）；没有为 null。
  String? get deviceName => _deviceName;

  final StreamController<void> _updates = StreamController<void>.broadcast();

  /// 每次 [publish] / [clear] 真的改了内容就响一次。
  Stream<void> get updates => _updates.stream;

  /// 首页取完一轮互联清单后调用。
  void publish(List<RemoteContinueCandidate> candidates, {String? deviceName}) {
    if (identical(candidates, _current) && deviceName == _deviceName) return;
    _current = List<RemoteContinueCandidate>.unmodifiable(candidates);
    _deviceName = deviceName;
    _updates.add(null);
  }

  /// 互联被关掉 / 解除配对：远端补位全部撤下。
  void clear() {
    if (_current.isEmpty && _deviceName == null) return;
    _current = const <RemoteContinueCandidate>[];
    _deviceName = null;
    _updates.add(null);
  }
}
