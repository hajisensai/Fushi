import 'dart:async';

import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/lan_discovery_service.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:meta/meta.dart';

/// 已配对 host 的局域网重新定位（反馈 MDzxg3SNQc / BUG-5068）。
///
/// 电脑改连手机热点（或换了路由器）后，手机存着的地址全是旧网段的；学新地址要先
/// 连上 host，连上又要新地址——死结。选路（[rankInterconnectCandidatesDetailed]）在
/// 存量直连地址全不通时向这里要「这台 hostId 此刻在局域网上公布的地址」：做一次
/// 限时 mDNS 浏览（与设置页配对用的同一个 [LanDiscoveryService]），按 TXT `id`
/// 挑出那台 host。TXT 无鉴权，身份核对由选路用本组钉扎指纹 + ping hostId 完成。
///
/// 一次浏览的结果在 [snapshotTtl] 内复用：同一窗口里多个消费方（同步、查词、播放）
/// 各自选路时只浏览一次，浏览不到的 host 也不会每次选路都再等一轮。并发请求合进
/// 同一轮浏览；要找的 host 全部出现就提前结束——这种提前结束的快照只对当时要找的
/// 那几台有定论，别的 host 来要时重新浏览。
class InterconnectLanRelocator {
  InterconnectLanRelocator({
    required Future<String> Function() ownDeviceId,
    LanDiscoveryService Function(String ownDeviceId)? discoveryFactory,
    void Function(LanDiscoveryService discovery)? onBrowseStart,
    void Function(LanDiscoveryService discovery)? onBrowseEnd,
    this.browseTimeout = const Duration(milliseconds: 2500),
    this.snapshotTtl = const Duration(seconds: 30),
    DateTime Function() now = DateTime.now,
  }) : _ownDeviceId = ownDeviceId,
       _discoveryFactory = discoveryFactory ?? _defaultDiscovery,
       _onBrowseStart = onBrowseStart,
       _onBrowseEnd = onBrowseEnd,
       _now = now;

  static LanDiscoveryService _defaultDiscovery(String ownDeviceId) =>
      LanDiscoveryService(deviceId: ownDeviceId);

  final Future<String> Function() _ownDeviceId;
  final LanDiscoveryService Function(String ownDeviceId) _discoveryFactory;

  /// 浏览期间把 browser 交给 app 的退出清理集合（TODO-036：引擎拆掉前必须停掉
  /// Bonsoir 事件源），browser 停完撤回。
  final void Function(LanDiscoveryService discovery)? _onBrowseStart;
  final void Function(LanDiscoveryService discovery)? _onBrowseEnd;

  /// 一轮浏览最多等多久（要找的 host 都出现了会提前结束）。
  final Duration browseTimeout;

  /// 一轮浏览的结果复用多久。
  final Duration snapshotTtl;
  final DateTime Function() _now;

  List<FushiDevice> _snapshot = const <FushiDevice>[];
  DateTime? _snapshotAt;

  /// 上一轮浏览对哪些 hostId 有定论：null = 全部（跑满 [browseTimeout] 或本机浏览
  /// 不了）；非 null = 要找的 host 都出现、提前结束时那一刻要找的那几台——别的 host
  /// 可能只是应答慢一点还没出现，不能拿这份不完整的快照当「它不在」复用。
  Set<String>? _snapshotCovers;
  Future<void>? _flight;
  final Set<String> _wanted = <String>{};

  /// [hostId] 那台 host 在局域网上公布的 https 地址（没找到 → 空）。明文 host
  /// 不给：明文地址按地址归属闸不学，也无从核对身份。
  ///
  /// 等待上限是一轮 [browseTimeout]（赶上一轮已经提前结束、又没覆盖到自己的浏览时
  /// 至多再等一轮）：原生 browser 的起停走 method channel，可能很慢甚至不归，选路
  /// 不能被它拖住——起 browser 不在等待链上，停 browser 在后台做。
  Future<List<String>> urlsFor(String hostId) async {
    while (true) {
      final Future<void>? flight = _flight;
      if (flight != null) {
        _wanted.add(hostId);
        await flight;
        if (_covers(hostId)) return _urlsIn(_snapshot, hostId);
        continue;
      }
      final DateTime? at = _snapshotAt;
      if (at != null &&
          _now().difference(at) < snapshotTtl &&
          _covers(hostId)) {
        return _urlsIn(_snapshot, hostId);
      }
      _wanted.add(hostId);
      _flight = _browse().whenComplete(() {
        _flight = null;
        _wanted.clear();
      });
    }
  }

  bool _covers(String hostId) {
    final Set<String>? covers = _snapshotCovers;
    return covers == null || covers.contains(hostId);
  }

  static List<String> _urlsIn(List<FushiDevice> devices, String hostId) =>
      <String>[
        for (final FushiDevice d in devices)
          if (d.deviceId == hostId && d.tlsEnabled)
            Uri(scheme: 'https', host: d.host, port: d.port).toString(),
      ];

  Future<void> _browse() async {
    List<FushiDevice> seen = const <FushiDevice>[];
    final LanDiscoveryService discovery = _discoveryFactory(
      await _ownDeviceId(),
    );
    // 要找的 host 全部出现、提前结束 → 那一刻要找的那几台（快照只对它们有定论）；
    // 到点 / 本机浏览不了 → null（对所有 host 有定论）。
    final Completer<Set<String>?> settled = Completer<Set<String>?>();
    final StreamSubscription<List<FushiDevice>> sub = discovery.devices.listen((
      List<FushiDevice> devices,
    ) {
      if (settled.isCompleted) return;
      seen = devices;
      final bool done = _wanted.every(
        (String id) => devices.any((FushiDevice d) => d.deviceId == id),
      );
      if (done) settled.complete(Set<String>.of(_wanted));
    });
    final Timer deadline = Timer(browseTimeout, () {
      if (!settled.isCompleted) settled.complete();
    });
    _onBrowseStart?.call(discovery);
    unawaited(
      discovery.startDiscovery().then<void>(
        (_) {},
        onError: (Object e, StackTrace stack) {
          // 本机此刻浏览不了（没有 mDNS 能力 / 权限被拒）：这一轮当作什么都没
          // 找到，照样记快照，免得窗口内每次选路都再撞一次；选路随后照常走隧道。
          ErrorLogService.instance.log(
            'InterconnectLanRelocate.browse',
            e,
            stack,
          );
          if (!settled.isCompleted) settled.complete();
        },
      ),
    );
    final Set<String>? covers = await settled.future;
    deadline.cancel();
    _snapshot = seen;
    _snapshotCovers = covers;
    _snapshotAt = _now();
    unawaited(_teardown(discovery, sub));
  }

  /// 停掉这一轮的 browser。不在选路的等待链上；停完才从退出清理集合撤回——停的
  /// 途中进程退出时，退出清理照样能切断它的事件源（TODO-036）。
  Future<void> _teardown(
    LanDiscoveryService discovery,
    StreamSubscription<List<FushiDevice>> sub,
  ) async {
    try {
      await sub.cancel();
      await discovery.dispose();
    } catch (e, stack) {
      ErrorLogService.instance.log('InterconnectLanRelocate.stop', e, stack);
    } finally {
      _onBrowseEnd?.call(discovery);
    }
  }
}

/// 启动时装一次：选路的局域网重新定位用 [lookup]（app 里是
/// [InterconnectLanRelocator.urlsFor]），核对通过的地址经
/// [mergeRelocatedInterconnectAddress] 落进 [repo] 的候选列表（与地址学习同一条
/// 串行写链）。
void installInterconnectLanRelocation(
  SyncRepository repo,
  InterconnectLanAddressLookup lookup,
) {
  setInterconnectLanRelocation(
    relocator: lookup,
    sink: (FushiClientUrl verified) async {
      await repo.updateFushiClientUrls(
        (List<FushiClientUrl> before) =>
            mergeRelocatedInterconnectAddress(before, verified),
      );
    },
  );
}

/// 测试装置：撤掉 [installInterconnectLanRelocation] 装上的一切。
@visibleForTesting
void debugResetInterconnectLanRelocation() => setInterconnectLanRelocation();
