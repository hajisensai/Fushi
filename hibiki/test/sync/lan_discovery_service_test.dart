import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/lan_discovery_service.dart';

/// Builds a *resolved* [BonsoirService] for the mapper tests. Uses
/// [BonsoirService.ignoreNorms] so the supplied name/attributes are preserved
/// verbatim (the normalizing constructor would rewrite them).
BonsoirService _resolved({
  String name = 'My Phone',
  int port = 8765,
  List<String> hostAddresses = const <String>['192.168.1.100'],
  Map<String, String> attributes = const <String, String>{'id': 'abc123'},
}) =>
    BonsoirService.ignoreNorms(
      name: name,
      type: LanDiscoveryService.serviceType,
      port: port,
      hostAddresses: hostAddresses,
      attributes: attributes,
    );

void main() {
  group('HibikiDevice', () {
    test('serializes to and from JSON', () {
      final device = HibikiDevice(
        name: 'My Phone',
        host: '192.168.1.100',
        port: 8765,
        deviceId: 'abc123',
      );
      final json = device.toJson();
      final restored = HibikiDevice.fromJson(json);
      expect(restored.name, 'My Phone');
      expect(restored.host, '192.168.1.100');
      expect(restored.port, 8765);
      expect(restored.deviceId, 'abc123');
    });

    test('webDavUrl builds correct URL', () {
      final device = HibikiDevice(
        name: 'Test',
        host: '192.168.1.50',
        port: 9999,
        deviceId: 'x',
      );
      expect(device.webDavUrl, 'http://192.168.1.50:9999');
    });
  });

  group('HibikiDevice.fromResolvedService', () {
    test('maps a resolved service to a device', () {
      final device = HibikiDevice.fromResolvedService(_resolved());
      expect(device, isNotNull);
      expect(device!.name, 'My Phone');
      expect(device.host, '192.168.1.100');
      expect(device.port, 8765);
      expect(device.deviceId, 'abc123');
      expect(device.webDavUrl, 'http://192.168.1.100:8765');
    });

    test('prefers IPv4 over IPv6 when both are present', () {
      final device = HibikiDevice.fromResolvedService(
        _resolved(
          hostAddresses: const <String>['fe80::1', '192.168.1.42'],
        ),
      );
      expect(device, isNotNull);
      expect(device!.host, '192.168.1.42');
      expect(device.webDavUrl, 'http://192.168.1.42:8765');
    });

    test('returns null when there are no host addresses', () {
      final device = HibikiDevice.fromResolvedService(
        _resolved(hostAddresses: const <String>[]),
      );
      expect(device, isNull);
    });

    test('falls back to service name as deviceId when no id attribute', () {
      final device = HibikiDevice.fromResolvedService(
        _resolved(
          name: 'Laptop',
          attributes: const <String, String>{},
        ),
      );
      expect(device, isNotNull);
      expect(device!.deviceId, 'Laptop');
    });

    // TODO-961: TXT tls=1 → tlsEnabled；旧版 host 不带该属性 → false（零破坏）。
    test('parses the tls TXT attribute; absent means plaintext host', () {
      final tlsDevice = HibikiDevice.fromResolvedService(
        _resolved(
          attributes: const <String, String>{'id': 'abc123', 'tls': '1'},
        ),
      );
      expect(tlsDevice, isNotNull);
      expect(tlsDevice!.tlsEnabled, isTrue);

      final plainDevice = HibikiDevice.fromResolvedService(_resolved());
      expect(plainDevice, isNotNull);
      expect(plainDevice!.tlsEnabled, isFalse);
    });

    test('tlsEnabled round-trips through JSON and defaults to false', () {
      final device = HibikiDevice(
        name: 'Test',
        host: '192.168.1.50',
        port: 9999,
        deviceId: 'x',
        tlsEnabled: true,
      );
      expect(HibikiDevice.fromJson(device.toJson()).tlsEnabled, isTrue);

      // 旧序列化数据（无 tlsEnabled 字段）读回 false。
      final legacy = HibikiDevice.fromJson(<String, dynamic>{
        'name': 'Old',
        'host': '10.0.0.2',
        'port': 38765,
        'deviceId': 'y',
      });
      expect(legacy.tlsEnabled, isFalse);
    });
  });

  group('LanBroadcastService', () {
    // TODO-961: host 开 TLS 时 TXT 必须广播 tls=1（发现方据此优先 https 探测）。
    test('advertises tls flag in TXT only when enabled', () {
      final LanBroadcastService tlsBroadcast = LanBroadcastService(
        deviceName: 'Hibiki · pc',
        deviceId: 'abc',
        port: 38765,
        tlsEnabled: true,
      );
      expect(tlsBroadcast.tlsEnabled, isTrue);

      final LanBroadcastService plainBroadcast = LanBroadcastService(
        deviceName: 'Hibiki · pc',
        deviceId: 'abc',
        port: 38765,
      );
      expect(plainBroadcast.tlsEnabled, isFalse);
    });
  });

  group('LanDiscoveryService', () {
    test('can be instantiated', () {
      final service = LanDiscoveryService(deviceId: 'test-id');
      expect(service, isNotNull);
      expect(service.currentDevices, isEmpty);
    });

    test('stream is broadcast', () {
      final service = LanDiscoveryService(deviceId: 'test-id');
      expect(service.devices.isBroadcast, isTrue);
    });
  });
}
