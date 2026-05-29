import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/lan_discovery_service.dart';

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

  group('LanDiscoveryService', () {
    test('can be instantiated', () {
      final service = LanDiscoveryService(
        deviceName: 'Test',
        port: 8765,
        deviceId: 'test-id',
      );
      expect(service, isNotNull);
      expect(service.currentDevices, isEmpty);
    });

    test('stream is broadcast', () {
      final service = LanDiscoveryService(
        deviceName: 'Test',
        port: 8765,
        deviceId: 'test-id',
      );
      expect(service.devices.isBroadcast, isTrue);
    });
  });
}
