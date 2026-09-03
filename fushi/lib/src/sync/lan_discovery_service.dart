import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:meta/meta.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// A peer Hibiki instance discovered on the LAN.
class FushiDevice {
  FushiDevice({
    required this.name,
    required this.host,
    required this.port,
    required this.deviceId,
    this.tlsEnabled = false,
  });

  final String name;
  final String host;
  final int port;
  final String deviceId;

  /// TODO-961: host 在 mDNS TXT 里自报「已开 HTTPS」（`tls=1`）。旧版 host 不带
  /// 该属性 → false（明文老路径）。v2 探测顺序据此定；[webDavUrl] 的 scheme 也
  /// 按它出（BUG-1693），真实 scheme 最终仍以 /api/ping 为准。
  final bool tlsEnabled;

  /// BUG-1693：TXT 广播 `tls=1` 的 host 服务的是 https，这里硬编码 http 会让
  /// v1 回退路径（`_pairLegacyV1` 直接拿本 URL 落库 + POST /api/pair）拿到错误
  /// scheme。旧版明文 host 不带 tls 属性 → 仍是 http，行为零变化。
  String get webDavUrl => '${tlsEnabled ? 'https' : 'http'}://$host:$port';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'host': host,
        'port': port,
        'deviceId': deviceId,
        'tlsEnabled': tlsEnabled,
      };

  factory FushiDevice.fromJson(Map<String, dynamic> json) => FushiDevice(
        name: json['name'] as String,
        host: json['host'] as String,
        port: json['port'] as int,
        deviceId: json['deviceId'] as String,
        tlsEnabled: json['tlsEnabled'] as bool? ?? false,
      );

  /// Builds a device from a *resolved* Bonsoir service. Returns null when the
  /// platform resolved no usable address. Prefers IPv4 (FushiSyncServer binds
  /// IPv4); an IPv6 literal is detected by the presence of a colon.
  static FushiDevice? fromResolvedService(BonsoirService service) {
    final List<String> addrs = service.hostAddresses;
    if (addrs.isEmpty) return null;
    final String host = addrs.firstWhere(
      (String a) => !a.contains(':'),
      orElse: () => addrs.first,
    );
    return FushiDevice(
      name: service.name,
      host: host,
      port: service.port,
      deviceId:
          service.attributes[LanDiscoveryService.attributeId] ?? service.name,
      tlsEnabled: service.attributes[LanDiscoveryService.attributeTls] == '1',
    );
  }
}

/// Browses the LAN for peer Hibiki sync servers advertised via [serviceType].
class LanDiscoveryService {
  LanDiscoveryService({required this.deviceId});

  static const String serviceType = '_fushi-sync._tcp';
  static const String attributeId = 'id';

  /// TODO-961: TXT 属性——host 已开 HTTPS 时广播 `tls=1`。旧客户端忽略未知
  /// TXT key（向后兼容）。
  static const String attributeTls = 'tls';

  /// Our own id, used to filter our own advertisement out of the results.
  final String deviceId;

  /// Our own LAN IPv4 addresses, used as a fallback self-filter for platforms
  /// that drop the TXT `id` attribute on resolve (then [deviceId] can't match).
  final Set<String> _localAddresses = <String>{};

  final Map<String, FushiDevice> _discoveredDevices = <String, FushiDevice>{};

  /// BUG-1693：serviceName → deviceId 辅助映射。[_discoveredDevices] 以 TXT `id`
  /// 为键，而 lost 事件在多数平台**不带 TXT 属性**、只带 service name——旧实现
  /// 回落 `service.name` 当键去 remove，与存储键对不上，离线对端永远留在列表里。
  /// resolved 时登记、lost 时先查它，消除「lost 事件带不带 TXT」的平台特例。
  final Map<String, String> _serviceNameToDeviceId = <String, String>{};
  final StreamController<List<FushiDevice>> _deviceStream =
      StreamController<List<FushiDevice>>.broadcast();
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;
  bool _disposed = false;

  /// True once [dispose] has run, so the app-exit teardown can assert the
  /// Bonsoir browser was actually stopped before the engine was torn down.
  bool get isDisposed => _disposed;

  /// BUG-1554 测试缝：当前是否持有一个活着的原生 Bonsoir browser。守卫用它断言
  /// 「dispose 之后再 startDiscovery 不会起孤儿 browser」「重复 startDiscovery 不会
  /// 覆盖丢弃上一个」——这两件事从外部没有别的可观测面（原生 browser 在单测环境
  /// 里既不抛也不回执）。
  @visibleForTesting
  bool get hasActiveBrowser => _discovery != null;

  Stream<List<FushiDevice>> get devices => _deviceStream.stream;
  List<FushiDevice> get currentDevices => _discoveredDevices.values.toList();

  /// BUG-1554：幂等。重复调用曾经会把上一台 [BonsoirDiscovery] 连同它的原生
  /// browser 一起**覆盖丢弃**（`_discovery` / `_sub` 直接改写），泄漏一个没人停得
  /// 掉的原生浏览器 + 一条仍在派发事件的订阅——正是 TODO-036 / BUG-191 要防的
  /// 「引擎拆了事件还在派发」崩溃形状。故先把旧的停干净再起新的。
  ///
  /// 同时守 [_disposed]：`_init` 是「先 register 再 await startDiscovery」，用户在
  /// 这个 await 窗口里关掉设置页时 `dispose()` 已经跑完并 unregister 了，此时再起
  /// 一个原生 browser 就成了既不在 controller 的活跃集合里、也没有 owner 的孤儿。
  Future<void> startDiscovery() async {
    if (_disposed) return;
    if (_discovery != null) await stopDiscovery();
    await _refreshLocalAddresses();
    if (_disposed) return;
    final BonsoirDiscovery discovery = BonsoirDiscovery(type: serviceType);
    _discovery = discovery;
    await discovery.initialize();
    _sub = discovery.eventStream!.listen(_onEvent);
    await discovery.start();
    // 起完再复核一次：initialize/start 之间也可能被 dispose 抢在前面。
    if (_disposed) await stopDiscovery();
  }

  /// Snapshot this device's own IPv4 addresses so a resolved service pointing
  /// back at us can be recognised as self even when its TXT `id` is missing.
  Future<void> _refreshLocalAddresses() async {
    _localAddresses.clear();
    try {
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: true,
      );
      for (final NetworkInterface iface in interfaces) {
        for (final InternetAddress addr in iface.addresses) {
          _localAddresses.add(addr.address);
        }
      }
    } catch (e, stack) {
      // Enumeration can be denied/unsupported; the id filter still applies.
      ErrorLogService.instance.log('LanDiscovery.localAddresses', e, stack);
    }
  }

  void _onEvent(BonsoirDiscoveryEvent event) {
    final BonsoirDiscovery? discovery = _discovery;
    switch (event) {
      // A service was found but not yet resolved: ask the platform to resolve
      // it so host addresses + TXT attributes get populated. The resolution
      // arrives later as a separate resolved event.
      case BonsoirDiscoveryServiceFoundEvent():
        if (discovery == null) return;
        unawaited(_resolve(event.service, discovery));
      // A service finished resolving: map it and add it (unless it is us — by
      // advertised id, or by host address when the id attribute didn't survive).
      case BonsoirDiscoveryServiceResolvedEvent():
        final FushiDevice? device =
            FushiDevice.fromResolvedService(event.service);
        if (device == null ||
            device.deviceId == deviceId ||
            _localAddresses.contains(device.host)) {
          return;
        }
        _discoveredDevices[device.deviceId] = device;
        // BUG-1693：登记 name → deviceId，lost 事件（多不带 TXT）靠它找回存储键。
        _serviceNameToDeviceId[event.service.name] = device.deviceId;
        _deviceStream.add(currentDevices);
      // A service went away: look up the storage key we registered on resolve
      // (lost events usually carry no TXT attributes), falling back to the id
      // attribute / service name for services we never resolved.
      case BonsoirDiscoveryServiceLostEvent():
        final BonsoirService service = event.service;
        final String key = _serviceNameToDeviceId.remove(service.name) ??
            service.attributes[attributeId] ??
            service.name;
        if (_discoveredDevices.remove(key) != null) {
          _deviceStream.add(currentDevices);
        }
      default:
        // Started / stopped / updated / resolve-failed / unknown: no-op.
        break;
    }
  }

  Future<void> _resolve(
    BonsoirService service,
    BonsoirDiscovery discovery,
  ) async {
    try {
      await service.resolve(discovery.serviceResolver);
    } catch (e, stack) {
      // Resolution can fail transiently (interface flap, no usable address);
      // record it rather than swallowing so repeated failures are diagnosable.
      ErrorLogService.instance.log('LanDiscovery.resolve', e, stack);
    }
  }

  /// BUG-1693 测试缝：把一条发现事件直接喂进内部处理器。resolved/lost 的键控一致性
  /// （lost 不带 TXT 也要删得掉）在单测环境没有原生 Bonsoir browser 可驱动，只能
  /// 从这里注入事件、用 [currentDevices] 观测。
  @visibleForTesting
  void debugHandleEvent(BonsoirDiscoveryEvent event) => _onEvent(event);

  Future<void> stopDiscovery() async {
    await _sub?.cancel();
    _sub = null;
    await _discovery?.stop();
    _discovery = null;
    _discoveredDevices.clear();
    _serviceNameToDeviceId.clear();
    // 已关闭的 controller 不能再 add（StateError）：dispose 走的正是这条路径。
    if (!_deviceStream.isClosed) _deviceStream.add(<FushiDevice>[]);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stopDiscovery();
    await _deviceStream.close();
  }

  /// 进程退出专用快速切断（TODO-086/BUG-191）：**同步 await** 取消 Dart 端事件
  /// 订阅——这才是 TODO-036 防崩的关键（事件不再派发到引擎/messenger）；bonsoir
  /// **原生** stop（method channel，可能不归/很慢，根因B）改 fire-and-forget，
  /// 不阻塞退出。随后 exit(0) 进程级终止会回收原生线程，不依赖原生 stop 完成。
  Future<void> cutEventSourceForExit() async {
    if (_disposed) return;
    _disposed = true;
    await _sub?.cancel();
    _sub = null;
    unawaited(_discovery?.stop());
    _discovery = null;
    _discoveredDevices.clear();
    _serviceNameToDeviceId.clear();
    unawaited(_deviceStream.close());
  }
}

/// Advertises this device so peers can discover it. Bound to the running
/// FushiSyncServer lifecycle by the settings UI (a later task).
class LanBroadcastService {
  LanBroadcastService({
    required this.deviceName,
    required this.deviceId,
    required this.port,
    this.tlsEnabled = false,
  });

  final String deviceName;
  final String deviceId;
  final int port;

  /// TODO-961: 本机 host 是否以 HTTPS 服务；true 时 TXT 广播 `tls=1`，供发现方
  /// 优先走 https 探测。旧客户端忽略该属性，行为不变。
  final bool tlsEnabled;

  BonsoirBroadcast? _broadcast;
  bool get isBroadcasting => _broadcast != null;

  Future<void> start() async {
    if (_broadcast != null) return;
    final BonsoirService service = BonsoirService(
      name: deviceName,
      type: LanDiscoveryService.serviceType,
      port: port,
      attributes: <String, String>{
        LanDiscoveryService.attributeId: deviceId,
        if (tlsEnabled) LanDiscoveryService.attributeTls: '1',
      },
    );
    final BonsoirBroadcast broadcast = BonsoirBroadcast(service: service);
    try {
      await broadcast.initialize();
      await broadcast.start();
      _broadcast = broadcast;
    } catch (e, stack) {
      // Advertising failure (no Avahi on Linux, blocked local-network perm on
      // iOS, etc.) must NOT kill the already-running HTTP server.
      ErrorLogService.instance.log('LanBroadcast.start', e, stack);
      _broadcast = null;
    }
  }

  Future<void> stop() async {
    await _broadcast?.stop();
    _broadcast = null;
  }

  /// 进程退出专用（TODO-086/BUG-191）：广播无 Dart 事件订阅（只对外播报），
  /// 原生 stop 改 fire-and-forget 不阻塞退出；exit(0) 回收原生线程。
  void cutEventSourceForExit() {
    unawaited(_broadcast?.stop());
    _broadcast = null;
  }
}
