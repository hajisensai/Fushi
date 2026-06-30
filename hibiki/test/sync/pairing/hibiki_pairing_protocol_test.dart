import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/pairing/hibiki_pairing_protocol.dart';

/// TODO-961 M1 §3.6 协议单元测试：nonce 生成、pinProof HMAC 计算/校验、错误 PIN
/// 拒绝、pinRequired 分支、LAN 地址判定。全部纯函数，无 IO。
void main() {
  group('generateNonce', () {
    test('每次生成不同的非空 base64url（无填充）', () {
      final String a = HibikiPairingProtocol.generateNonce();
      final String b = HibikiPairingProtocol.generateNonce();
      expect(a, isNotEmpty);
      expect(b, isNotEmpty);
      expect(a, isNot(equals(b)));
      expect(a.contains('='), isFalse);
    });
  });

  group('generatePin', () {
    test('恒为 6 位数字字符串（前导零保留）', () {
      for (var i = 0; i < 200; i++) {
        final String pin = HibikiPairingProtocol.generatePin();
        expect(pin.length, 6);
        expect(RegExp(r'^\d{6}$').hasMatch(pin), isTrue, reason: 'pin=$pin');
      }
    });
  });

  group('computePinProof / verifyPinProof', () {
    const String pin = '482913';
    const String clientNonce = 'client-nonce-abc';
    const String hostNonce = 'host-nonce-xyz';

    test('确定性：同输入同输出，且为 64 hex 字符（SHA-256）', () {
      final String p1 = HibikiPairingProtocol.computePinProof(
          pin: pin, clientNonce: clientNonce, hostNonce: hostNonce);
      final String p2 = HibikiPairingProtocol.computePinProof(
          pin: pin, clientNonce: clientNonce, hostNonce: hostNonce);
      expect(p1, equals(p2));
      expect(p1.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(p1), isTrue);
    });

    test('正确 PIN + 正确 nonce → 校验通过', () {
      final String proof = HibikiPairingProtocol.computePinProof(
          pin: pin, clientNonce: clientNonce, hostNonce: hostNonce);
      expect(
        HibikiPairingProtocol.verifyPinProof(
          pin: pin,
          clientNonce: clientNonce,
          hostNonce: hostNonce,
          submittedProof: proof,
        ),
        isTrue,
      );
    });

    test('错误 PIN → 校验失败', () {
      final String proof = HibikiPairingProtocol.computePinProof(
          pin: pin, clientNonce: clientNonce, hostNonce: hostNonce);
      expect(
        HibikiPairingProtocol.verifyPinProof(
          pin: '000000', // 错误 PIN
          clientNonce: clientNonce,
          hostNonce: hostNonce,
          submittedProof: proof,
        ),
        isFalse,
      );
    });

    test('nonce 不匹配（重放到另一会话）→ 校验失败', () {
      final String proof = HibikiPairingProtocol.computePinProof(
          pin: pin, clientNonce: clientNonce, hostNonce: hostNonce);
      // host 端用另一对 nonce（另一会话）重算 → 不等。
      expect(
        HibikiPairingProtocol.verifyPinProof(
          pin: pin,
          clientNonce: 'other-client-nonce',
          hostNonce: hostNonce,
          submittedProof: proof,
        ),
        isFalse,
      );
      expect(
        HibikiPairingProtocol.verifyPinProof(
          pin: pin,
          clientNonce: clientNonce,
          hostNonce: 'other-host-nonce',
          submittedProof: proof,
        ),
        isFalse,
      );
    });

    test('归一化：大小写/空白噪声不影响比对', () {
      final String proof = HibikiPairingProtocol.computePinProof(
          pin: pin, clientNonce: clientNonce, hostNonce: hostNonce);
      expect(
        HibikiPairingProtocol.verifyPinProof(
          pin: pin,
          clientNonce: clientNonce,
          hostNonce: hostNonce,
          submittedProof: ' ${proof.toUpperCase()} ',
        ),
        isTrue,
      );
    });

    test('PIN 进入 MAC：交换 nonce 顺序得到不同 proof（分隔符防边界碰撞）', () {
      final String ab = HibikiPairingProtocol.computePinProof(
          pin: pin, clientNonce: 'a', hostNonce: 'bc');
      final String ab2 = HibikiPairingProtocol.computePinProof(
          pin: pin, clientNonce: 'ab', hostNonce: 'c');
      expect(ab, isNot(equals(ab2)));
    });
  });

  group('computePinRequired', () {
    test('公网入站恒强制 PIN', () {
      expect(
        HibikiPairingProtocol.computePinRequired(
            isLanPeer: false, lanRequiresPin: false),
        isTrue,
      );
      expect(
        HibikiPairingProtocol.computePinRequired(
            isLanPeer: false, lanRequiresPin: true),
        isTrue,
      );
    });

    test('LAN：随 host 设置（默认 false=免）', () {
      expect(
        HibikiPairingProtocol.computePinRequired(
            isLanPeer: true, lanRequiresPin: false),
        isFalse,
      );
      expect(
        HibikiPairingProtocol.computePinRequired(
            isLanPeer: true, lanRequiresPin: true),
        isTrue,
      );
    });
  });

  group('isPrivateLanAddress', () {
    test('私有/环回段判为 LAN', () {
      for (final String addr in <String>[
        '127.0.0.1',
        '10.0.0.5',
        '192.168.1.100',
        '172.16.0.1',
        '172.31.255.254',
        '169.254.1.2',
        '::1',
        'fe80::1',
        'fd00::1',
      ]) {
        expect(HibikiPairingProtocol.isPrivateLanAddress(addr), isTrue,
            reason: addr);
      }
    });

    test('公网/不可解析判为非 LAN（安全侧→强制 PIN）', () {
      for (final String? addr in <String?>[
        '8.8.8.8',
        '1.1.1.1',
        '172.32.0.1', // 超出 172.16/12
        '2001:4860:4860::8888',
        '',
        null,
        'not-an-ip',
      ]) {
        expect(HibikiPairingProtocol.isPrivateLanAddress(addr), isFalse,
            reason: '$addr');
      }
    });
  });

  group('HibikiPairSession', () {
    test('consumed 默认 false（首次 confirm 前可用）', () {
      final HibikiPairSession s = HibikiPairSession(
        sessionId: 'sid',
        clientNonce: 'cn',
        hostNonce: 'hn',
        pin: '123456',
        pinRequired: true,
        deviceName: 'dev',
        remoteAddress: '192.168.1.2',
        createdAt: DateTime(2026),
      );
      expect(s.consumed, isFalse);
    });
  });
}
