import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/torrent/torrent_network_diagnosis.dart';
import 'package:fushi_engine/utils/net/fake_ip_dns.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// BUG-2950：fake-ip DNS 下给内置 torrent 引擎找回真实 IP + 会话级网络诊断。
void main() {
  group('isFakeIpAddress', () {
    test('198.18.0.0/15 is fake-ip, neighbours are not', () {
      expect(isFakeIpAddress(InternetAddress('198.18.1.174')), isTrue);
      expect(isFakeIpAddress(InternetAddress('198.19.255.1')), isTrue);
      expect(isFakeIpAddress(InternetAddress('198.17.0.1')), isFalse);
      expect(isFakeIpAddress(InternetAddress('198.20.0.1')), isFalse);
      expect(isFakeIpAddress(InternetAddress('87.98.162.88')), isFalse);
      expect(isFakeIpAddress(InternetAddress('::1')), isFalse);
    });
  });

  group('isFakeIpDnsActive', () {
    test('any probe host resolving into fake-ip range → true', () async {
      final bool active = await isFakeIpDnsActive(
        probeHosts: <String>['a', 'b'],
        lookup: (String host) async => <InternetAddress>[
          InternetAddress(host == 'a' ? '1.2.3.4' : '198.18.0.9'),
        ],
      );
      expect(active, isTrue);
    });

    test('real addresses → false', () async {
      final bool active = await isFakeIpDnsActive(
        probeHosts: <String>['a'],
        lookup: (String host) async => <InternetAddress>[
          InternetAddress('67.215.246.10'),
        ],
      );
      expect(active, isFalse);
    });

    test('all lookups fail (offline) → false, not fake-ip', () async {
      final bool active = await isFakeIpDnsActive(
        probeHosts: <String>['a', 'b'],
        lookup: (String host) async =>
            throw const SocketException('no network'),
      );
      expect(active, isFalse);
    });
  });

  group('parseDohJsonARecords', () {
    test('keeps type-1 IPv4 answers, drops CNAME / fake-ip / junk', () {
      final String body = jsonEncode(<String, Object>{
        'Status': 0,
        'Answer': <Object>[
          <String, Object>{'type': 5, 'data': 'alias.example.'},
          <String, Object>{'type': 1, 'data': '87.98.162.88'},
          <String, Object>{'type': 1, 'data': '198.18.1.2'},
          <String, Object>{'type': 1, 'data': 'not-an-ip'},
          <String, Object>{'type': 1, 'data': '87.98.162.88'},
          <String, Object>{'type': 1, 'data': '212.129.33.59'},
        ],
      });
      expect(parseDohJsonARecords(body), <String>[
        '87.98.162.88',
        '212.129.33.59',
      ]);
    });

    test('non-JSON / no Answer → empty', () {
      expect(parseDohJsonARecords('<html>'), isEmpty);
      expect(parseDohJsonARecords('{"Status":3}'), isEmpty);
    });
  });

  group('splitHostPort / rewriteUdpTrackerHost', () {
    test('splitHostPort', () {
      expect(splitHostPort('dht.libtorrent.org:25401'),
          (host: 'dht.libtorrent.org', port: 25401));
      expect(splitHostPort('host'), isNull);
      expect(splitHostPort('host:0'), isNull);
      expect(splitHostPort('host:70000'), isNull);
      expect(splitHostPort(':6881'), isNull);
    });

    test('only udp:// trackers with a port are rewritten', () {
      expect(
        rewriteUdpTrackerHost(
            'udp://tracker.opentrackr.org:1337/announce', '93.158.213.92'),
        'udp://93.158.213.92:1337/announce',
      );
      expect(
        rewriteUdpTrackerHost(
            'http://nyaa.tracker.wf:7777/announce', '1.2.3.4'),
        isNull,
      );
      expect(rewriteUdpTrackerHost('udp://noport/announce', '1.2.3.4'), isNull);
    });
  });

  group('DohResolver', () {
    test('falls through failing endpoints, sends dns-json accept', () async {
      final List<Uri> seen = <Uri>[];
      final MockClient client = MockClient((http.Request request) async {
        seen.add(request.url);
        expect(request.headers['accept'], 'application/dns-json');
        if (request.url.host == 'bad.example') {
          return http.Response('oops', 500);
        }
        return http.Response(
          jsonEncode(<String, Object>{
            'Answer': <Object>[
              <String, Object>{'type': 1, 'data': '87.98.162.88'},
            ],
          }),
          200,
        );
      });
      final DohResolver doh = DohResolver(
        client: client,
        endpoints: <String>[
          'https://bad.example/resolve',
          'https://good.example/resolve',
        ],
      );
      expect(await doh.resolveA('router.bittorrent.com'),
          <String>['87.98.162.88']);
      expect(seen.map((Uri u) => u.host), <String>[
        'bad.example',
        'good.example',
      ]);
      expect(seen.last.queryParameters,
          <String, String>{'name': 'router.bittorrent.com', 'type': 'A'});
    });

    test('IP literal returned without any request', () async {
      final DohResolver doh = DohResolver(
        client: MockClient(
            (http.Request request) async => fail('should not hit network')),
      );
      expect(await doh.resolveA('1.2.3.4'), <String>['1.2.3.4']);
    });
  });

  group('resolveFakeIpTorrentBypass', () {
    test('rewrites DHT bootstrap + udp trackers, skips unresolvable / http',
        () async {
      final Map<String, List<String>> zone = <String, List<String>>{
        'router.bittorrent.com': <String>['67.215.246.10'],
        'dht.transmissionbt.com': <String>[
          '87.98.162.88',
          '212.129.33.59',
          '9.9.9.9'
        ],
        'tracker.opentrackr.org': <String>['93.158.213.92'],
      };
      final MockClient client = MockClient((http.Request request) async {
        final List<String> ips =
            zone[request.url.queryParameters['name']] ?? const <String>[];
        return http.Response(
          jsonEncode(<String, Object>{
            'Answer': <Object>[
              for (final String ip in ips)
                <String, Object>{'type': 1, 'data': ip},
            ],
          }),
          200,
        );
      });
      final FakeIpTorrentBypass bypass = await resolveFakeIpTorrentBypass(
        doh: DohResolver(
            client: client, endpoints: <String>['https://doh.example/q']),
        bootstrapHostPorts: <String>[
          'router.bittorrent.com:6881',
          'dht.transmissionbt.com:6881',
          'dead.example:6881',
        ],
        udpTrackers: <String>[
          'udp://tracker.opentrackr.org:1337/announce',
          'http://nyaa.tracker.wf:7777/announce',
          'udp://dead.example:80/announce',
        ],
      );
      expect(bypass.dhtNodes, <String>[
        '67.215.246.10:6881',
        '87.98.162.88:6881',
        '212.129.33.59:6881',
      ]);
      expect(bypass.trackers, <String>['udp://93.158.213.92:1337/announce']);
      expect(bypass.isEmpty, isFalse);
    });

    test('bootstrap list mirrors the native default (5 entries)', () {
      expect(kDhtBootstrapHostPorts, hasLength(5));
      expect(kDhtBootstrapHostPorts, contains('router.bittorrent.com:6881'));
    });
  });

  group('diagnoseTorrentNetwork', () {
    const Duration late = Duration(minutes: 5);

    test('healthy DHT → none, even under fake-ip', () {
      expect(
        diagnoseTorrentNetwork(
            dhtEnabled: true,
            dhtNodes: 120,
            sessionAge: late,
            fakeIpDetected: true),
        TorrentNetworkIssue.none,
      );
    });

    test('within grace period → none', () {
      expect(
        diagnoseTorrentNetwork(
            dhtEnabled: true,
            dhtNodes: 0,
            sessionAge: const Duration(seconds: 30),
            fakeIpDetected: true),
        TorrentNetworkIssue.none,
      );
    });

    test('zero / unknown nodes after grace → issue by fake-ip flag', () {
      expect(
        diagnoseTorrentNetwork(
            dhtEnabled: true,
            dhtNodes: 0,
            sessionAge: late,
            fakeIpDetected: true),
        TorrentNetworkIssue.fakeIpUdpBlocked,
      );
      expect(
        diagnoseTorrentNetwork(
            dhtEnabled: true,
            dhtNodes: -1,
            sessionAge: late,
            fakeIpDetected: false),
        TorrentNetworkIssue.dhtUnreachable,
      );
    });

    test('DHT disabled → none (nothing measurable)', () {
      expect(
        diagnoseTorrentNetwork(
            dhtEnabled: false,
            dhtNodes: 0,
            sessionAge: late,
            fakeIpDetected: true),
        TorrentNetworkIssue.none,
      );
    });
  });
}
