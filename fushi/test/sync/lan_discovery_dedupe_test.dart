// BUG-4247: one LAN host listed twice under the same row key.
//
// The discovery map was keyed by the TXT `id`, falling back to the service
// name. A resolve that dropped the TXT record, or a host that re-registered
// under a new instance name, stored a second entry for the same `host:port`.
// The LAN devices list keys each row by `webDavUrl`, so the second entry gave
// a duplicate key ("Duplicate keys found" while building FushiGroupedList),
// which corrupts the element tree; the red screen `_dependents.isEmpty`
// followed on the next route change after pairing.
import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/lan_discovery_service.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:material_ui/material_ui.dart';

BonsoirDiscoveryServiceResolvedEvent _resolvedEvent({
  required String name,
  Map<String, String> attributes = const <String, String>{},
  String host = '192.168.1.50',
  int port = 38765,
}) => BonsoirDiscoveryServiceResolvedEvent(
  service: BonsoirService.ignoreNorms(
    name: name,
    type: LanDiscoveryService.serviceType,
    port: port,
    hostAddresses: <String>[host],
    attributes: attributes,
  ),
);

BonsoirDiscoveryServiceLostEvent _lostEvent(String name) =>
    BonsoirDiscoveryServiceLostEvent(
      service: BonsoirService.ignoreNorms(
        name: name,
        type: LanDiscoveryService.serviceType,
        port: 0,
        attributes: const <String, String>{},
      ),
    );

const Map<String, String> _tlsWithId = <String, String>{
  'id': 'host-pc',
  'tls': '1',
};

List<String> _urls(LanDiscoveryService service) =>
    service.currentDevices.map((FushiDevice d) => d.webDavUrl).toList();

/// The LAN devices list as `_LanDiscoveryWidgetState.build` lays it out: one
/// [FushiStaggeredEntrance] per device inside a [FushiGroupedList], keyed by
/// the device's `webDavUrl`.
Widget _lanDevicesList(List<FushiDevice> devices) => MaterialApp(
  home: Scaffold(
    body: FushiGroupedList(
      children: <Widget>[
        for (int i = 0; i < devices.length; i++)
          FushiStaggeredEntrance(
            key: ValueKey<String>(devices[i].webDavUrl),
            index: i,
            child: Text(devices[i].name),
          ),
      ],
    ),
  ),
);

void main() {
  group('LanDiscoveryService keeps one entry per host (BUG-4247)', () {
    test(
      'a re-resolve that drops the TXT record does not add a second row',
      () {
        final LanDiscoveryService service = LanDiscoveryService(
          deviceId: 'self',
        );
        service.debugHandleEvent(
          _resolvedEvent(name: 'Fushi PC', attributes: _tlsWithId),
        );
        // Same service, TXT lost on this resolve: key falls back to the name.
        service.debugHandleEvent(_resolvedEvent(name: 'Fushi PC'));

        expect(service.currentDevices, hasLength(1));
        expect(_urls(service), <String>['http://192.168.1.50:38765']);

        // The single remaining entry is still removable by its lost event.
        service.debugHandleEvent(_lostEvent('Fushi PC'));
        expect(service.currentDevices, isEmpty);
      },
    );

    test('a host re-registered under a new instance name replaces the old '
        'record for the same endpoint', () {
      final LanDiscoveryService service = LanDiscoveryService(deviceId: 'self');
      // Old record whose TXT never resolved (keyed by name) ...
      service.debugHandleEvent(_resolvedEvent(name: 'Fushi PC'));
      // ... and the re-registered one, same host:port, keyed by its id.
      service.debugHandleEvent(
        _resolvedEvent(name: 'Fushi PC (2)', attributes: _tlsWithId),
      );

      expect(service.currentDevices, hasLength(1));
      expect(service.currentDevices.single.deviceId, 'host-pc');
      expect(_urls(service), <String>['https://192.168.1.50:38765']);
    });

    test('two records with different ids on one endpoint give one row', () {
      final LanDiscoveryService service = LanDiscoveryService(deviceId: 'self');
      service.debugHandleEvent(
        _resolvedEvent(
          name: 'Fushi PC',
          attributes: const <String, String>{'id': 'host-old', 'tls': '1'},
        ),
      );
      service.debugHandleEvent(
        _resolvedEvent(name: 'Fushi PC', attributes: _tlsWithId),
      );

      expect(_urls(service), <String>['https://192.168.1.50:38765']);
      expect(service.currentDevices.single.deviceId, 'host-pc');
    });

    test('a lost event for a superseded name keeps the live entry', () {
      final LanDiscoveryService service = LanDiscoveryService(deviceId: 'self');
      service.debugHandleEvent(
        _resolvedEvent(name: 'Fushi PC', attributes: _tlsWithId),
      );
      service.debugHandleEvent(
        _resolvedEvent(name: 'Fushi PC (2)', attributes: _tlsWithId),
      );
      expect(service.currentDevices, hasLength(1));

      service.debugHandleEvent(_lostEvent('Fushi PC'));
      expect(
        service.currentDevices,
        hasLength(1),
        reason: 'the old instance name no longer owns the entry',
      );

      service.debugHandleEvent(_lostEvent('Fushi PC (2)'));
      expect(service.currentDevices, isEmpty);
    });

    test('different hosts and different ports stay separate rows', () {
      final LanDiscoveryService service = LanDiscoveryService(deviceId: 'self');
      service.debugHandleEvent(
        _resolvedEvent(
          name: 'A',
          attributes: const <String, String>{'id': 'a'},
        ),
      );
      service.debugHandleEvent(
        _resolvedEvent(
          name: 'B',
          attributes: const <String, String>{'id': 'b'},
          host: '192.168.1.60',
        ),
      );
      service.debugHandleEvent(
        _resolvedEvent(
          name: 'C',
          attributes: const <String, String>{'id': 'c'},
          port: 38766,
        ),
      );
      expect(service.currentDevices, hasLength(3));
    });
  });

  testWidgets('LAN devices list builds without duplicate keys when one host '
      'is discovered twice', (WidgetTester tester) async {
    final LanDiscoveryService service = LanDiscoveryService(deviceId: 'self');
    service.debugHandleEvent(
      _resolvedEvent(
        name: 'Fushi PC',
        attributes: const <String, String>{'id': 'host-old', 'tls': '1'},
      ),
    );
    await tester.pumpWidget(_lanDevicesList(service.currentDevices));
    expect(tester.takeException(), isNull);

    // The failing run's shape: a second record for https://<host>:38765.
    service.debugHandleEvent(
      _resolvedEvent(name: 'Fushi PC (2)', attributes: _tlsWithId),
    );
    await tester.pumpWidget(_lanDevicesList(service.currentDevices));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(FushiStaggeredEntrance), findsOneWidget);
    expect(find.text('Fushi PC (2)'), findsOneWidget);
  });
}
