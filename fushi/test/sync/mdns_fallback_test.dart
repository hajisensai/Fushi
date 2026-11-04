import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/lan_discovery_service.dart';
import 'package:fushi/src/sync/mdns_fallback.dart';

/// BUG-4105: SteamOS ships Avahi disabled, so on Linux bonsoir cannot
/// initialise and LAN discovery / advertising both failed ("Scan failed").
/// These pin the built-in mDNS fallback: wire format, responder, browser, and
/// that LanDiscoveryService / LanBroadcastService switch to it.

/// In-memory LAN: every transport hears every multicast (like loopback on).
class _FakeLan {
  final List<_FakeTransport> members = <_FakeTransport>[];
  final List<Uint8List> sent = <Uint8List>[];

  _FakeTransport join(String address) {
    final _FakeTransport t = _FakeTransport(this, InternetAddress(address));
    members.add(t);
    return t;
  }
}

class _FakeTransport implements MdnsTransport {
  _FakeTransport(this.lan, this.address);
  final _FakeLan lan;
  final InternetAddress address;
  final StreamController<MdnsDatagram> _in =
      StreamController<MdnsDatagram>.broadcast(sync: true);
  final List<(Uint8List, InternetAddress, int)> unicast =
      <(Uint8List, InternetAddress, int)>[];
  bool closed = false;

  void deliver(Uint8List data, InternetAddress from, int port) =>
      _in.add(MdnsDatagram(data, from, port));

  @override
  Stream<MdnsDatagram> get datagrams => _in.stream;

  @override
  void sendMulticast(Uint8List data) {
    lan.sent.add(data);
    for (final _FakeTransport t in List<_FakeTransport>.of(lan.members)) {
      if (!t.closed) t.deliver(data, address, 5353);
    }
  }

  @override
  void sendTo(Uint8List data, InternetAddress address, int port) =>
      unicast.add((data, address, port));

  @override
  Future<List<InternetAddress>> localAddresses() async => <InternetAddress>[
    InternetAddress('172.17.0.1'), // a docker bridge listed first
    address,
  ];

  @override
  void close() {
    closed = true;
    unawaited(_in.close());
  }
}

final MdnsName _service = MdnsName.parse('_fushi-sync._tcp.local');

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('wire format', () {
    test('a full response round-trips (UTF-8 + dotted instance label)', () {
      final MdnsName instance = _service.child('Fushi · Test.Deck');
      final MdnsName host = MdnsName(const <String>['fushi-abc', 'local']);
      final Uint8List bytes = encodeMdnsMessage(
        MdnsMessage(
          isResponse: true,
          answers: <MdnsRecord>[MdnsPtrRecord(_service, 120, instance)],
          additionals: <MdnsRecord>[
            MdnsSrvRecord(instance, 120, port: 38765, target: host),
            MdnsTxtRecord(instance, 120, const <String, String>{
              'id': 'dev-1',
              'tls': '1',
            }),
            MdnsARecord(host, 120, InternetAddress('10.254.0.217')),
          ],
        ),
      );
      final MdnsMessage m = decodeMdnsMessage(bytes)!;
      expect(m.isResponse, isTrue);
      final List<MdnsRecord> r = m.allRecords.toList();
      expect((r[0] as MdnsPtrRecord).target, instance);
      expect((r[0] as MdnsPtrRecord).target.labels.first, 'Fushi · Test.Deck');
      expect((r[1] as MdnsSrvRecord).port, 38765);
      expect((r[1] as MdnsSrvRecord).target, host);
      expect((r[2] as MdnsTxtRecord).attributes, <String, String>{
        'id': 'dev-1',
        'tls': '1',
      });
      expect((r[3] as MdnsARecord).address.address, '10.254.0.217');
    });

    test('compressed names from other responders decode', () {
      // Header (response, 1 answer) + PTR whose target points back at the
      // question-less owner name: "_fushi-sync._tcp.local" at offset 12.
      final List<int> owner = <int>[
        11,
        ...'_fushi-sync'.codeUnits,
        4,
        ...'_tcp'.codeUnits,
        5,
        ...'local'.codeUnits,
        0,
      ];
      final List<int> rdata = <int>[3, ...'Bob'.codeUnits, 0xc0, 12];
      final Uint8List packet = Uint8List.fromList(<int>[
        0,
        0,
        0x84,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        ...owner,
        0,
        12,
        0,
        1,
        0,
        0,
        0,
        120,
        0,
        rdata.length,
        ...rdata,
      ]);
      final MdnsPtrRecord ptr =
          decodeMdnsMessage(packet)!.answers.single as MdnsPtrRecord;
      expect(ptr.name, _service);
      expect(ptr.target, _service.child('Bob'));
    });

    test('malformed packets are rejected, not thrown', () {
      expect(decodeMdnsMessage(Uint8List.fromList(<int>[0, 0, 0x84])), isNull);
      // A pointer loop.
      expect(
        decodeMdnsMessage(
          Uint8List.fromList(<int>[
            0,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            0,
            0xc0,
            12,
            0,
            12,
            0,
            1,
          ]),
        ),
        isNull,
      );
    });
  });

  group('responder + browser', () {
    test('browser resolves the responder, prefers the same-subnet address, '
        'and reports goodbye as lost', () async {
      final _FakeLan lan = _FakeLan();
      final MdnsServiceResponder responder = MdnsServiceResponder(
        transport: lan.join('10.254.0.217'),
        serviceType: '_fushi-sync._tcp',
        instanceName: 'Deck',
        hostLabel: 'fushi-abc',
        port: 38765,
        attributes: const <String, String>{'id': 'deck-1'},
      );
      final MdnsServiceBrowser browser = MdnsServiceBrowser(
        transport: lan.join('10.254.0.40'),
        serviceType: '_fushi-sync._tcp',
      );
      final List<MdnsBrowseEvent> events = <MdnsBrowseEvent>[];
      browser.events.listen(events.add);
      await responder.start();
      await browser.start(); // its PTR query is answered by the responder
      await _settle();

      final MdnsServiceResolved found = events
          .whereType<MdnsServiceResolved>()
          .single;
      expect(found.name, 'Deck');
      expect(found.port, 38765);
      expect(found.attributes['id'], 'deck-1');
      expect(found.hostAddresses.first, '10.254.0.217');

      await responder.stop();
      await _settle();
      expect(events.last, isA<MdnsServiceLost>());
      expect(events.last.name, 'Deck');
      await browser.stop();
    });

    test('a peer that vanishes without goodbye is lost when its records '
        'expire', () async {
      final _FakeLan lan = _FakeLan();
      DateTime now = DateTime(2026, 11, 4, 9);
      final _FakeTransport t = lan.join('10.254.0.40');
      final MdnsServiceBrowser browser = MdnsServiceBrowser(
        transport: t,
        serviceType: '_fushi-sync._tcp',
        clock: () => now,
      );
      final List<MdnsBrowseEvent> events = <MdnsBrowseEvent>[];
      browser.events.listen(events.add);
      final MdnsName instance = _service.child('Phone');
      final MdnsName host = MdnsName(const <String>['phone', 'local']);
      browser.debugReceive(
        encodeMdnsMessage(
          MdnsMessage(
            isResponse: true,
            answers: <MdnsRecord>[MdnsPtrRecord(_service, 4500, instance)],
            additionals: <MdnsRecord>[
              MdnsSrvRecord(instance, 120, port: 8765, target: host),
              MdnsTxtRecord(instance, 4500, const <String, String>{'id': 'p'}),
              MdnsARecord(host, 120, InternetAddress('10.254.0.50')),
            ],
          ),
        ),
      );
      await _settle();
      expect(events.single, isA<MdnsServiceResolved>());
      now = now.add(const Duration(seconds: 121));
      browser.debugSweep();
      await _settle();
      expect(events.last, isA<MdnsServiceLost>());
      await browser.stop();
    });

    test('a PTR without SRV / TXT triggers follow-up questions and is not '
        'reported half-resolved', () async {
      final _FakeLan lan = _FakeLan();
      final _FakeTransport t = lan.join('10.254.0.40');
      final MdnsServiceBrowser browser = MdnsServiceBrowser(
        transport: t,
        serviceType: '_fushi-sync._tcp',
      );
      final List<MdnsBrowseEvent> events = <MdnsBrowseEvent>[];
      browser.events.listen(events.add);
      await browser.start();
      lan.sent.clear();
      final MdnsName instance = _service.child('Mac');
      browser.debugReceive(
        encodeMdnsMessage(
          MdnsMessage(
            isResponse: true,
            answers: <MdnsRecord>[MdnsPtrRecord(_service, 4500, instance)],
          ),
        ),
      );
      expect(events, isEmpty);
      final MdnsMessage followUp = decodeMdnsMessage(lan.sent.single)!;
      expect(followUp.isResponse, isFalse);
      expect(
        followUp.questions.map((MdnsQuestion q) => (q.name, q.type)),
        <(MdnsName, int)>[(instance, 33), (instance, 16)],
      );
      await browser.stop();
    });

    test('legacy unicast queriers (source port != 5353) get a unicast reply '
        'echoing the id', () async {
      final _FakeLan lan = _FakeLan();
      final _FakeTransport t = lan.join('10.254.0.217');
      final MdnsServiceResponder responder = MdnsServiceResponder(
        transport: t,
        serviceType: '_fushi-sync._tcp',
        instanceName: 'Deck',
        hostLabel: 'fushi-abc',
        port: 38765,
        attributes: const <String, String>{'id': 'deck-1'},
      );
      await responder.start();
      t.deliver(
        encodeMdnsMessage(
          MdnsMessage(
            id: 0x1234,
            isResponse: false,
            questions: <MdnsQuestion>[MdnsQuestion(_service, 12)],
          ),
        ),
        InternetAddress('10.254.0.9'),
        54321,
      );
      await _settle();
      await _settle();
      final (Uint8List data, InternetAddress to, int port) = t.unicast.single;
      expect(to.address, '10.254.0.9');
      expect(port, 54321);
      final MdnsMessage reply = decodeMdnsMessage(data)!;
      expect(reply.id, 0x1234);
      expect(reply.questions.single.name, _service);
      await responder.stop();
    });
  });

  group(
    'LanDiscoveryService / LanBroadcastService fall back without Avahi',
    () {
      test('a failed Avahi initialise browses with the built-in client and '
          'surfaces peers as FushiDevices', () async {
        final _FakeLan lan = _FakeLan();
        final LanDiscoveryService discovery = LanDiscoveryService(
          deviceId: 'self',
          discoveryFactory: (String type) => _FailingDiscovery(type),
          mdnsTransportFactory: () async => lan.join('10.254.1.2'),
          mdnsFallbackEnabled: true,
        );
        final LanBroadcastService peer = LanBroadcastService(
          deviceName: 'Fushi · Test',
          deviceId: 'pc-1',
          port: 38765,
          tlsEnabled: true,
          broadcastFactory: (BonsoirService s) => _FailingBroadcast(s),
          mdnsTransportFactory: () async => lan.join('10.254.1.3'),
          mdnsFallbackEnabled: true,
        );
        await peer.start();
        expect(peer.usingMdnsFallback, isTrue);
        await discovery.startDiscovery(); // must not throw
        await _settle();
        expect(discovery.usingMdnsFallback, isTrue);
        final FushiDevice device = discovery.currentDevices.single;
        expect(device.deviceId, 'pc-1');
        expect(device.webDavUrl, 'https://10.254.1.3:38765');

        await peer.stop();
        await _settle();
        await _settle();
        expect(discovery.currentDevices, isEmpty);
        await discovery.dispose();
        expect(lan.members.every((_FakeTransport t) => t.closed), isTrue);
      });

      test(
        'without the fallback (non-Linux) the Avahi error still surfaces',
        () async {
          final LanDiscoveryService discovery = LanDiscoveryService(
            deviceId: 'self',
            discoveryFactory: (String type) => _FailingDiscovery(type),
            mdnsFallbackEnabled: false,
          );
          await expectLater(
            discovery.startDiscovery(),
            throwsA(isA<StateError>()),
          );
          expect(discovery.hasActiveBrowser, isFalse);
        },
      );

      test(
        'stop during the fallback socket bind leaves nothing running',
        () async {
          final _FakeLan lan = _FakeLan();
          final Completer<MdnsTransport> bind = Completer<MdnsTransport>();
          final Completer<void> binding = Completer<void>();
          final LanDiscoveryService discovery = LanDiscoveryService(
            deviceId: 'self',
            discoveryFactory: (String type) => _FailingDiscovery(type),
            mdnsTransportFactory: () {
              binding.complete();
              return bind.future;
            },
            mdnsFallbackEnabled: true,
          );
          final Future<void> starting = discovery.startDiscovery();
          await binding.future; // Avahi failed, fallback socket is binding
          expect(discovery.hasActiveBrowser, isTrue);
          await discovery.stopDiscovery();
          final _FakeTransport t = lan.join('10.254.0.217');
          bind.complete(t);
          await starting;
          expect(discovery.hasActiveBrowser, isFalse);
          expect(t.closed, isTrue);
        },
      );

      test('mDNS host label is unique per device and DNS-safe', () {
        expect(
          LanBroadcastService.mdnsHostLabel('3F2A-91c0_77de-4b1a-a0'),
          'fushi-3f2a91c077de',
        );
      });
    },
  );
}

class _FailingDiscovery implements BonsoirDiscovery {
  _FailingDiscovery(this.type);

  @override
  final String type;

  @override
  Future<void> initialize() async => throw StateError('avahi: unknown unit');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('never initialised: ${invocation.memberName}');
}

class _FailingBroadcast implements BonsoirBroadcast {
  _FailingBroadcast(this.service);

  @override
  final BonsoirService service;

  @override
  Future<void> initialize() async => throw StateError('avahi: unknown unit');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('never initialised: ${invocation.memberName}');
}
