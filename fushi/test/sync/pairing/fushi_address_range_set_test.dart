import 'dart:io';

import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
import 'package:test/test.dart';

/// BUG-4279：可信代理地址集合与限速来源键。
void main() {
  group('FushiAddressRangeSet', () {
    test('单个 v4 地址只匹配自己', () {
      final FushiAddressRangeSet set = FushiAddressRangeSet.parse(<String>[
        '127.0.0.1',
      ]);
      expect(set.contains(InternetAddress('127.0.0.1')), isTrue);
      expect(set.contains(InternetAddress('127.0.0.2')), isFalse);
    });

    test('v4 CIDR', () {
      final FushiAddressRangeSet set = FushiAddressRangeSet.parse(<String>[
        '10.0.0.0/8',
        '192.168.1.0/24',
      ]);
      expect(set.contains(InternetAddress('10.200.3.4')), isTrue);
      expect(set.contains(InternetAddress('192.168.1.255')), isTrue);
      expect(set.contains(InternetAddress('192.168.2.1')), isFalse);
      expect(set.contains(InternetAddress('11.0.0.1')), isFalse);
    });

    test('v6 地址与 CIDR', () {
      final FushiAddressRangeSet set = FushiAddressRangeSet.parse(<String>[
        '::1',
        '2001:db8::/32',
      ]);
      expect(set.contains(InternetAddress('::1')), isTrue);
      expect(set.contains(InternetAddress('2001:db8:ffff::9')), isTrue);
      expect(set.contains(InternetAddress('2001:db9::1')), isFalse);
      // 族不同不匹配。
      expect(set.contains(InternetAddress('127.0.0.1')), isFalse);
    });

    test('v4 映射地址两侧都先还原成 v4', () {
      final FushiAddressRangeSet set = FushiAddressRangeSet.parse(<String>[
        '127.0.0.1',
        '::ffff:10.1.0.0/112',
      ]);
      expect(set.contains(InternetAddress('::ffff:127.0.0.1')), isTrue);
      expect(set.contains(InternetAddress('10.1.200.7')), isTrue);
      expect(set.contains(InternetAddress('10.2.0.1')), isFalse);
    });

    test('/0 匹配同族全部地址', () {
      final FushiAddressRangeSet set = FushiAddressRangeSet.parse(<String>[
        '0.0.0.0/0',
      ]);
      expect(set.contains(InternetAddress('8.8.8.8')), isTrue);
      expect(set.contains(InternetAddress('2001:db8::1')), isFalse);
    });

    test('非法条目抛 FormatException 并点名', () {
      for (final String bad in <String>[
        'not-an-ip',
        '10.0.0.0/33',
        '10.0.0.0/x',
        '2001:db8::/129',
        '',
        'example.com',
      ]) {
        expect(
          () => FushiAddressRangeSet.parse(<String>['127.0.0.1', bad]),
          throwsA(
            isA<FormatException>().having(
              (FormatException e) => e.message,
              'message',
              contains('"$bad"'),
            ),
          ),
          reason: bad,
        );
      }
    });

    test('空集合不包含任何地址', () {
      expect(
        FushiAddressRangeSet.empty.contains(InternetAddress('127.0.0.1')),
        isFalse,
      );
      expect(FushiAddressRangeSet.parse(const <String>[]).isEmpty, isTrue);
    });
  });

  group('fushiRateKeyForAddress', () {
    test('v4 → ip:<点分>', () {
      expect(
        fushiRateKeyForAddress(InternetAddress('203.0.113.5')),
        'ip:203.0.113.5',
      );
    });

    test('v4 映射还原成 v4 键', () {
      expect(
        fushiRateKeyForAddress(InternetAddress('::ffff:203.0.113.5')),
        'ip:203.0.113.5',
      );
    });

    test('同一 /64 的两个 v6 地址给出同一键', () {
      final String a = fushiRateKeyForAddress(InternetAddress('2001:db8::1'));
      final String b = fushiRateKeyForAddress(
        InternetAddress('2001:db8:0:0:abcd:ef01:2345:6789'),
      );
      expect(a, b);
      expect(a, 'ip6:2001:db8::/64');
      expect(
        fushiRateKeyForAddress(InternetAddress('2001:db8:0:1::1')),
        isNot(a),
      );
    });
  });
}
