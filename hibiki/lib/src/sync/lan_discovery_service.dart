import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

import 'package:hibiki/src/utils/misc/error_log_service.dart';

class HibikiDevice {
  HibikiDevice({
    required this.name,
    required this.host,
    required this.port,
    required this.deviceId,
  });

  final String name;
  final String host;
  final int port;
  final String deviceId;

  String get webDavUrl => 'http://$host:$port';

  Map<String, dynamic> toJson() => {
        'name': name,
        'host': host,
        'port': port,
        'deviceId': deviceId,
      };

  factory HibikiDevice.fromJson(Map<String, dynamic> json) => HibikiDevice(
        name: json['name'] as String,
        host: json['host'] as String,
        port: json['port'] as int,
        deviceId: json['deviceId'] as String,
      );
}

class LanDiscoveryService {
  LanDiscoveryService({
    required this.deviceName,
    required this.port,
    required this.deviceId,
  });

  static const String serviceType = '_hibiki-sync._tcp';
  static const String serviceDomain = 'local';

  final String deviceName;
  final int port;
  final String deviceId;

  final _discoveredDevices = <String, HibikiDevice>{};
  final _deviceStream = StreamController<List<HibikiDevice>>.broadcast();
  MDnsClient? _mdnsClient;
  Timer? _scanTimer;

  Stream<List<HibikiDevice>> get devices => _deviceStream.stream;
  List<HibikiDevice> get currentDevices => _discoveredDevices.values.toList();

  Future<void> startDiscovery() async {
    _mdnsClient = MDnsClient();
    await _mdnsClient!.start();
    _scanTimer = Timer.periodic(const Duration(seconds: 5), (_) => _scan());
    await _scan();
  }

  Future<void> stopDiscovery() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    _mdnsClient?.stop();
    _mdnsClient = null;
    _discoveredDevices.clear();
    _deviceStream.add([]);
  }

  Future<void> _scan() async {
    if (_mdnsClient == null) return;

    try {
      await for (final ptr in _mdnsClient!.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer('$serviceType.$serviceDomain'))) {
        await for (final srv in _mdnsClient!.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(ptr.domainName))) {
          await for (final ip in _mdnsClient!.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target))) {
            final device = HibikiDevice(
              name: ptr.domainName.split('.').first,
              host: ip.address.address,
              port: srv.port,
              deviceId: ptr.domainName,
            );
            if (device.deviceId != deviceId) {
              _discoveredDevices[device.deviceId] = device;
            }
          }
        }
      }
      _deviceStream.add(currentDevices);
    } catch (e, stack) {
      // A periodic mDNS scan can fail (transient network/interface state).
      // Record it rather than swallowing so repeated failures are diagnosable
      // (HBK-AUDIT-164). Startup failures surface separately via startDiscovery.
      ErrorLogService.instance.log('LanDiscovery.mdnsScan', e, stack);
    }
  }

  Future<void> dispose() async {
    await stopDiscovery();
    await _deviceStream.close();
  }
}
