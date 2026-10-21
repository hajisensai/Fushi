import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_api_access_policy.dart';

InternetAddress _ip(String s) => InternetAddress(s);

void main() {
  group('FushiIpNetwork', () {
    test('CIDR 前缀匹配与边界', () {
      final FushiIpNetwork n = FushiIpNetwork.tryParse('192.168.1.0/24')!;
      expect(n.contains(_ip('192.168.1.0')), isTrue);
      expect(n.contains(_ip('192.168.1.255')), isTrue);
      expect(n.contains(_ip('192.168.2.1')), isFalse);
      expect(n.contains(_ip('10.0.0.1')), isFalse);
    });

    test('非字节对齐前缀（/20）', () {
      final FushiIpNetwork n = FushiIpNetwork.tryParse('10.1.16.0/20')!;
      expect(n.contains(_ip('10.1.31.255')), isTrue);
      expect(n.contains(_ip('10.1.32.0')), isFalse);
      expect(n.contains(_ip('10.1.15.255')), isFalse);
    });

    test('单个地址按 /32；/0 放行全部 IPv4', () {
      final FushiIpNetwork one = FushiIpNetwork.tryParse('10.0.0.5')!;
      expect(one.contains(_ip('10.0.0.5')), isTrue);
      expect(one.contains(_ip('10.0.0.6')), isFalse);
      expect(
        FushiIpNetwork.tryParse('0.0.0.0/0')!.contains(_ip('8.8.8.8')),
        isTrue,
      );
    });

    test('IPv4 规则匹配 IPv4 映射的 IPv6 来源', () {
      final FushiIpNetwork n = FushiIpNetwork.tryParse('192.168.1.0/24')!;
      expect(n.contains(_ip('::ffff:192.168.1.7')), isTrue);
      expect(n.contains(_ip('::ffff:192.168.9.7')), isFalse);
    });

    test('IPv6 网段，且与 IPv4 规则互不串', () {
      final FushiIpNetwork v6 = FushiIpNetwork.tryParse('fd00::/8')!;
      expect(v6.contains(_ip('fd12:3456::1')), isTrue);
      expect(v6.contains(_ip('fe80::1')), isFalse);
      expect(v6.contains(_ip('192.168.1.1')), isFalse);
    });

    test('非法输入返回 null', () {
      for (final String bad in <String>[
        '',
        'abc',
        '192.168.1.0/33',
        '192.168.1.0/-1',
        '192.168.1.0/x',
        '300.1.1.1',
        'fd00::/129',
      ]) {
        expect(FushiIpNetwork.tryParse(bad), isNull, reason: bad);
      }
    });
  });

  test('parseFushiIpNetworks：换行 / 逗号 / 中文逗号分隔，收集非法条目', () {
    final ({List<FushiIpNetwork> networks, List<String> invalid}) r =
        parseFushiIpNetworks('192.168.1.0/24\n10.0.0.5, bogus，172.16.0.0/12\n');
    expect(r.networks.map((FushiIpNetwork n) => n.source), <String>[
      '192.168.1.0/24',
      '10.0.0.5',
      '172.16.0.0/12',
    ]);
    expect(r.invalid, <String>['bogus']);
  });

  test('FushiApiAccessMode：未知 / 缺失值回落 lan（老用户行为不变）', () {
    expect(FushiApiAccessMode.fromWireName(null), FushiApiAccessMode.lan);
    expect(FushiApiAccessMode.fromWireName('?'), FushiApiAccessMode.lan);
    for (final FushiApiAccessMode m in FushiApiAccessMode.values) {
      expect(FushiApiAccessMode.fromWireName(m.wireName), m);
    }
  });

  group('FushiApiAccessPolicy.decide', () {
    final InternetAddress lanPeer = _ip('192.168.1.20');
    final InternetAddress loopback = _ip('127.0.0.1');

    test('监听地址：仅本机绑回环，其余绑 0.0.0.0', () {
      expect(
        FushiApiAccessPolicy.localOnly.bindAddress,
        InternetAddress.loopbackIPv4,
      );
      expect(
        const FushiApiAccessPolicy(mode: FushiApiAccessMode.lan).bindAddress,
        InternetAddress.anyIPv4,
      );
      expect(
        const FushiApiAccessPolicy(
          mode: FushiApiAccessMode.allowList,
        ).bindAddress,
        InternetAddress.anyIPv4,
      );
    });

    test('本机（含 IPv6 回环与映射回环）恒放行，不论模式与密钥', () {
      for (final FushiApiAccessMode m in FushiApiAccessMode.values) {
        final FushiApiAccessPolicy p = FushiApiAccessPolicy(mode: m);
        for (final InternetAddress a in <InternetAddress>[
          loopback,
          _ip('::1'),
          _ip('::ffff:127.0.0.1'),
        ]) {
          expect(
            p.decide(remote: a, keyConfigured: false),
            FushiApiAccessDecision.allow,
            reason: '$m $a',
          );
        }
      }
    });

    test('局域网模式：非本机没密钥一律拒（根因：此前空密钥全网放行）', () {
      const FushiApiAccessPolicy p = FushiApiAccessPolicy(
        mode: FushiApiAccessMode.lan,
      );
      expect(
        p.decide(remote: lanPeer, keyConfigured: false),
        FushiApiAccessDecision.denyNoKey,
      );
      expect(
        p.decide(remote: lanPeer, keyConfigured: true),
        FushiApiAccessDecision.allow,
      );
    });

    test('仅本机模式：非本机即使有密钥也拒', () {
      expect(
        FushiApiAccessPolicy.localOnly.decide(
          remote: lanPeer,
          keyConfigured: true,
        ),
        FushiApiAccessDecision.denyLocalOnly,
      );
    });

    test('指定网段：不在白名单拒；在白名单仍须有密钥', () {
      final FushiApiAccessPolicy p = FushiApiAccessPolicy(
        mode: FushiApiAccessMode.allowList,
        allowedNetworks: <FushiIpNetwork>[
          FushiIpNetwork.tryParse('192.168.1.0/24')!,
        ],
      );
      expect(
        p.decide(remote: _ip('10.0.0.9'), keyConfigured: true),
        FushiApiAccessDecision.denyNotInAllowList,
      );
      expect(
        p.decide(remote: lanPeer, keyConfigured: false),
        FushiApiAccessDecision.denyNoKey,
      );
      expect(
        p.decide(remote: lanPeer, keyConfigured: true),
        FushiApiAccessDecision.allow,
      );
    });

    test('拿不到来源地址：失败即关闭', () {
      expect(
        const FushiApiAccessPolicy(
          mode: FushiApiAccessMode.lan,
        ).decide(remote: null, keyConfigured: true),
        FushiApiAccessDecision.denyUnknownPeer,
      );
    });
  });
}
