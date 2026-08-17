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
  // BUG-1554 守卫：dispose 之后 startDiscovery 必须是 no-op。
  //
  // `_init` 的形状是「先 register 再 await startDiscovery()」，用户在这个 await 窗口
  // 里关掉设置页时 dispose() 已经跑完并 unregister 了；旧实现照样新起一个原生 Bonsoir
  // browser —— 既不在 controller 的活跃集合里、也没有 owner，正是 TODO-036/BUG-191
  // 要防的「引擎拆了事件还在派发」崩溃源。守卫用「没有平台通道也不抛」做判别器：
  // 一旦回到「无条件 new BonsoirDiscovery + initialize」，这条会因缺 MethodChannel
  // 实现而失败。
  group('LanDiscoveryService lifecycle', () {
    test('startDiscovery after dispose is a no-op', () async {
      final LanDiscoveryService service = LanDiscoveryService(deviceId: 'self');
      await service.dispose();
      expect(service.isDisposed, isTrue);
      await service.startDiscovery();
      expect(service.hasActiveBrowser, isFalse,
          reason: 'dispose 之后再起 browser 就是没人停得掉的孤儿');
      expect(service.currentDevices, isEmpty);
    });

    test('dispose is idempotent and never touches a closed stream', () async {
      final LanDiscoveryService service = LanDiscoveryService(deviceId: 'self');
      await service.dispose();
      await service.dispose();
      expect(service.isDisposed, isTrue);
    });
  });

  group('FushiDevice', () {
    test('serializes to and from JSON', () {
      final device = FushiDevice(
        name: 'My Phone',
        host: '192.168.1.100',
        port: 8765,
        deviceId: 'abc123',
      );
      final json = device.toJson();
      final restored = FushiDevice.fromJson(json);
      expect(restored.name, 'My Phone');
      expect(restored.host, '192.168.1.100');
      expect(restored.port, 8765);
      expect(restored.deviceId, 'abc123');
    });

    test('webDavUrl builds correct URL', () {
      final device = FushiDevice(
        name: 'Test',
        host: '192.168.1.50',
        port: 9999,
        deviceId: 'x',
      );
      expect(device.webDavUrl, 'http://192.168.1.50:9999');
    });
  });

  group('FushiDevice.fromResolvedService', () {
    test('maps a resolved service to a device', () {
      final device = FushiDevice.fromResolvedService(_resolved());
      expect(device, isNotNull);
      expect(device!.name, 'My Phone');
      expect(device.host, '192.168.1.100');
      expect(device.port, 8765);
      expect(device.deviceId, 'abc123');
      expect(device.webDavUrl, 'http://192.168.1.100:8765');
    });

    test('prefers IPv4 over IPv6 when both are present', () {
      final device = FushiDevice.fromResolvedService(
        _resolved(
          hostAddresses: const <String>['fe80::1', '192.168.1.42'],
        ),
      );
      expect(device, isNotNull);
      expect(device!.host, '192.168.1.42');
      expect(device.webDavUrl, 'http://192.168.1.42:8765');
    });

    test('returns null when there are no host addresses', () {
      final device = FushiDevice.fromResolvedService(
        _resolved(hostAddresses: const <String>[]),
      );
      expect(device, isNull);
    });

    test('falls back to service name as deviceId when no id attribute', () {
      final device = FushiDevice.fromResolvedService(
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
      final tlsDevice = FushiDevice.fromResolvedService(
        _resolved(
          attributes: const <String, String>{'id': 'abc123', 'tls': '1'},
        ),
      );
      expect(tlsDevice, isNotNull);
      expect(tlsDevice!.tlsEnabled, isTrue);

      final plainDevice = FushiDevice.fromResolvedService(_resolved());
      expect(plainDevice, isNotNull);
      expect(plainDevice!.tlsEnabled, isFalse);
    });

    test('tlsEnabled round-trips through JSON and defaults to false', () {
      final device = FushiDevice(
        name: 'Test',
        host: '192.168.1.50',
        port: 9999,
        deviceId: 'x',
        tlsEnabled: true,
      );
      expect(FushiDevice.fromJson(device.toJson()).tlsEnabled, isTrue);

      // 旧序列化数据（无 tlsEnabled 字段）读回 false。
      final legacy = FushiDevice.fromJson(<String, dynamic>{
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

  // BUG-1693：lost 事件在多数平台**不带 TXT 属性**，旧实现回落 service.name 当键
  // 去 remove，与 resolved 时按 TXT `id` 存的键对不上 → remove 静默失败，离线对端
  // 一直留在设备列表里。现在 resolved 时登记 name → deviceId，lost 时先查它。
  group('service-lost keying (BUG-1693)', () {
    BonsoirService lostService({String name = 'Peer PC'}) =>
        BonsoirService.ignoreNorms(
          name: name,
          type: LanDiscoveryService.serviceType,
          port: 8765,
          // lost 事件的典型形状：无 hostAddresses、无 TXT 属性，只有 service name。
          attributes: const <String, String>{},
        );

    test('lost event without TXT attributes still removes the device', () {
      final LanDiscoveryService service = LanDiscoveryService(deviceId: 'self');
      service.debugHandleEvent(BonsoirDiscoveryServiceResolvedEvent(
        service: _resolved(
          name: 'Peer PC',
          attributes: const <String, String>{'id': 'peer-1'},
        ),
      ));
      expect(
        service.currentDevices.map((FushiDevice d) => d.deviceId),
        <String>['peer-1'],
      );

      service.debugHandleEvent(
        BonsoirDiscoveryServiceLostEvent(service: lostService()),
      );
      expect(service.currentDevices, isEmpty,
          reason: 'lost 不带 TXT 时必须靠 name → deviceId 辅助映射找回存储键');
    });

    test('lost event with TXT id attribute keeps working', () {
      final LanDiscoveryService service = LanDiscoveryService(deviceId: 'self');
      service.debugHandleEvent(BonsoirDiscoveryServiceResolvedEvent(
        service: _resolved(
          name: 'Peer PC',
          attributes: const <String, String>{'id': 'peer-1'},
        ),
      ));
      expect(service.currentDevices, hasLength(1));

      // 平台带上了 TXT（且 name 从未 resolve 登记过 → 走 id 回落）：同样删得掉。
      service.debugHandleEvent(BonsoirDiscoveryServiceLostEvent(
        service: BonsoirService.ignoreNorms(
          name: 'Renamed Peer',
          type: LanDiscoveryService.serviceType,
          port: 8765,
          attributes: const <String, String>{'id': 'peer-1'},
        ),
      ));
      expect(service.currentDevices, isEmpty);
    });

    test('losing an unknown service is a no-op', () {
      final LanDiscoveryService service = LanDiscoveryService(deviceId: 'self');
      service.debugHandleEvent(BonsoirDiscoveryServiceResolvedEvent(
        service: _resolved(
          name: 'Peer PC',
          attributes: const <String, String>{'id': 'peer-1'},
        ),
      ));
      service.debugHandleEvent(
        BonsoirDiscoveryServiceLostEvent(service: lostService(name: 'Other')),
      );
      expect(service.currentDevices, hasLength(1));
    });
  });

  // BUG-1693：TXT 广播 tls=1 的 host 服务的是 https，webDavUrl 不能硬编码 http
  // （v1 回退路径会把这个 URL 原样落库并 POST /api/pair）。
  group('webDavUrl scheme follows tls (BUG-1693)', () {
    test('tlsEnabled device builds an https URL', () {
      final FushiDevice device = FushiDevice(
        name: 'Test',
        host: '192.168.1.50',
        port: 9999,
        deviceId: 'x',
        tlsEnabled: true,
      );
      expect(device.webDavUrl, 'https://192.168.1.50:9999');
    });

    test('resolved service with tls=1 yields an https webDavUrl', () {
      final FushiDevice? device = FushiDevice.fromResolvedService(
        _resolved(
          attributes: const <String, String>{'id': 'abc123', 'tls': '1'},
        ),
      );
      expect(device, isNotNull);
      expect(device!.webDavUrl, 'https://192.168.1.100:8765');
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
