import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';

/// host 地址集的分类与组装（docs/specs/2026-09-28-interconnect-remote-reach.md §1）。
void main() {
  InterconnectAddressKind? classify(String nic, String ip) =>
      classifyInterconnectAddress(nic, InternetAddress(ip));

  group('classifyInterconnectAddress', () {
    test('私网 v4 → lan；100.64/10 → overlay；网卡上的公网 v4 → public', () {
      expect(classify('Ethernet', '192.168.1.5'), InterconnectAddressKind.lan);
      expect(classify('wlan0', '10.0.0.7'), InterconnectAddressKind.lan);
      expect(classify('eth0', '172.20.3.4'), InterconnectAddressKind.lan);
      expect(
        classify('Tailscale', '100.101.5.6'),
        InterconnectAddressKind.overlay,
      );
      expect(classify('eth0', '203.0.113.9'), InterconnectAddressKind.public);
    });

    test('组网网卡上的私网段按 overlay（ZeroTier 默认发 10.x）', () {
      expect(
        classify('ZeroTier One [8056c2e21c]', '10.147.17.3'),
        InterconnectAddressKind.overlay,
      );
      expect(
        classify('ztks57xabc', '172.24.0.9'),
        InterconnectAddressKind.overlay,
      );
      expect(
        classify('EasyTier', '10.126.126.1'),
        InterconnectAddressKind.overlay,
      );
    });

    test('IPv6：ULA → lanV6，全局单播 → ipv6', () {
      expect(classify('eth0', 'fd12:3456::1'), InterconnectAddressKind.lanV6);
      expect(
        classify('eth0', '2408:8207:1234::5'),
        InterconnectAddressKind.ipv6,
      );
    });

    test('回环 / 链路本地 / 本机网桥不公布', () {
      expect(classify('lo', '127.0.0.1'), isNull);
      expect(classify('lo', '::1'), isNull);
      expect(classify('eth0', 'fe80::1'), isNull);
      expect(classify('eth0', '169.254.3.4'), isNull);
      expect(classify('docker0', '172.17.0.1'), isNull);
      expect(classify('vEthernet (WSL)', '172.28.160.1'), isNull);
      expect(classify('VMware Network Adapter VMnet8', '192.168.80.1'), isNull);
    });
  });

  test('interconnectAddressUrl：v6 加方括号、scheme 跟随 TLS', () {
    expect(
      interconnectAddressUrl(InternetAddress('2408::5'), 38765, tls: false),
      'http://[2408::5]:38765',
    );
    expect(
      interconnectAddressUrl(InternetAddress('192.168.1.5'), 38765, tls: true),
      'https://192.168.1.5:38765',
    );
  });

  test('InterconnectHostAddress.fromJson 容忍未知 kind（新 host 多报一种）', () {
    expect(
      InterconnectHostAddress.fromJson(<String, Object?>{
        'url': 'http://x:1',
        'kind': 'lan',
      }),
      const InterconnectHostAddress(
        url: 'http://x:1',
        kind: InterconnectAddressKind.lan,
      ),
    );
    expect(
      InterconnectHostAddress.fromJson(<String, Object?>{
        'url': 'http://x:1',
        'kind': 'quantum',
      }),
      isNull,
    );
    expect(InterconnectHostAddress.fromJson('garbage'), isNull);
  });

  test('decodeInterconnectPublicUrls：JSON 数组，坏数据当没配', () {
    expect(decodeInterconnectPublicUrls('["https://a.example", " "]'), <String>[
      'https://a.example',
    ]);
    expect(decodeInterconnectPublicUrls('not json'), isEmpty);
    expect(decodeInterconnectPublicUrls(null), isEmpty);
    expect(decodeInterconnectPublicUrls(<Object?>['x', 3]), <String>['x']);
  });

  test('listInterconnectHostAddresses：按优先级排序、去重、带上公网与附加地址', () async {
    final List<NetworkInterface> nics = (await NetworkInterface.list(
      includeLoopback: true,
      includeLinkLocal: true,
    ));
    final List<InterconnectHostAddress> addresses =
        await listInterconnectHostAddresses(
          port: 38765,
          tls: false,
          publicUrls: <String>[
            'https://home.example:443',
            'https://home.example:443',
          ],
          extra: const <InterconnectHostAddress>[
            InterconnectHostAddress(
              url: 'p2p://node',
              kind: InterconnectAddressKind.p2p,
            ),
          ],
          interfaceLister: () async => nics,
        );
    final List<int> ranks = <int>[
      for (final InterconnectHostAddress a in addresses)
        interconnectAddressRank(a.kind),
    ];
    expect(ranks, List<int>.of(ranks)..sort());
    expect(
      addresses.where(
        (InterconnectHostAddress a) => a.url == 'https://home.example:443',
      ),
      hasLength(1),
    );
    expect(addresses.last.url, 'p2p://node');
    expect(
      addresses.any(
        (InterconnectHostAddress a) =>
            a.url.contains('127.0.0.1') || a.url.contains('[::1]'),
      ),
      isFalse,
    );
  });
}
