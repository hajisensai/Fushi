import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/pairing/hibiki_pairing_protocol.dart';

/// TODO-961 M1 §3.6 协议单元测试：nonce 生成、pinProof HMAC 计算/校验、错误 PIN
/// 拒绝、pinRequired 分支、LAN 地址判定。全部纯函数，无 IO。
void main() {
  group('generateNonce', () {
    test('每次生成不同的非空 base64url（无填充）', () {
      final String a = FushiPairingProtocol.generateNonce();
      final String b = FushiPairingProtocol.generateNonce();
      expect(a, isNotEmpty);
      expect(b, isNotEmpty);
      expect(a, isNot(equals(b)));
      expect(a.contains('='), isFalse);
    });
  });

  group('generatePin', () {
    test('恒为 6 位数字字符串（前导零保留）', () {
      for (var i = 0; i < 200; i++) {
        final String pin = FushiPairingProtocol.generatePin();
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
      final String p1 = FushiPairingProtocol.computePinProof(
          pin: pin, clientNonce: clientNonce, hostNonce: hostNonce);
      final String p2 = FushiPairingProtocol.computePinProof(
          pin: pin, clientNonce: clientNonce, hostNonce: hostNonce);
      expect(p1, equals(p2));
      expect(p1.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(p1), isTrue);
    });

    test('正确 PIN + 正确 nonce → 校验通过', () {
      final String proof = FushiPairingProtocol.computePinProof(
          pin: pin, clientNonce: clientNonce, hostNonce: hostNonce);
      expect(
        FushiPairingProtocol.verifyPinProof(
          pin: pin,
          clientNonce: clientNonce,
          hostNonce: hostNonce,
          submittedProof: proof,
        ),
        isTrue,
      );
    });

    test('错误 PIN → 校验失败', () {
      final String proof = FushiPairingProtocol.computePinProof(
          pin: pin, clientNonce: clientNonce, hostNonce: hostNonce);
      expect(
        FushiPairingProtocol.verifyPinProof(
          pin: '000000', // 错误 PIN
          clientNonce: clientNonce,
          hostNonce: hostNonce,
          submittedProof: proof,
        ),
        isFalse,
      );
    });

    test('nonce 不匹配（重放到另一会话）→ 校验失败', () {
      final String proof = FushiPairingProtocol.computePinProof(
          pin: pin, clientNonce: clientNonce, hostNonce: hostNonce);
      // host 端用另一对 nonce（另一会话）重算 → 不等。
      expect(
        FushiPairingProtocol.verifyPinProof(
          pin: pin,
          clientNonce: 'other-client-nonce',
          hostNonce: hostNonce,
          submittedProof: proof,
        ),
        isFalse,
      );
      expect(
        FushiPairingProtocol.verifyPinProof(
          pin: pin,
          clientNonce: clientNonce,
          hostNonce: 'other-host-nonce',
          submittedProof: proof,
        ),
        isFalse,
      );
    });

    test('归一化：大小写/空白噪声不影响比对', () {
      final String proof = FushiPairingProtocol.computePinProof(
          pin: pin, clientNonce: clientNonce, hostNonce: hostNonce);
      expect(
        FushiPairingProtocol.verifyPinProof(
          pin: pin,
          clientNonce: clientNonce,
          hostNonce: hostNonce,
          submittedProof: ' ${proof.toUpperCase()} ',
        ),
        isTrue,
      );
    });

    test('PIN 进入 MAC：交换 nonce 顺序得到不同 proof（分隔符防边界碰撞）', () {
      final String ab = FushiPairingProtocol.computePinProof(
          pin: pin, clientNonce: 'a', hostNonce: 'bc');
      final String ab2 = FushiPairingProtocol.computePinProof(
          pin: pin, clientNonce: 'ab', hostNonce: 'c');
      expect(ab, isNot(equals(ab2)));
    });
  });

  group('computePinRequired', () {
    test('公网入站恒强制 PIN', () {
      expect(
        FushiPairingProtocol.computePinRequired(
            isLanPeer: false, lanRequiresPin: false),
        isTrue,
      );
      expect(
        FushiPairingProtocol.computePinRequired(
            isLanPeer: false, lanRequiresPin: true),
        isTrue,
      );
    });

    test('LAN：随 host 设置（默认 false=免）', () {
      expect(
        FushiPairingProtocol.computePinRequired(
            isLanPeer: true, lanRequiresPin: false),
        isFalse,
      );
      expect(
        FushiPairingProtocol.computePinRequired(
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
        expect(FushiPairingProtocol.isPrivateLanAddress(addr), isTrue,
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
        expect(FushiPairingProtocol.isPrivateLanAddress(addr), isFalse,
            reason: '$addr');
      }
    });
  });

  group('FushiPairSession', () {
    test('consumed 默认 false（首次 confirm 前可用）', () {
      final FushiPairSession s = FushiPairSession(
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

  group('FushiPinRateLimiter', () {
    final DateTime t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);

    FushiPinRateLimiter limiter() => FushiPinRateLimiter(
          maxFailures: 3,
          failureWindow: const Duration(minutes: 5),
          lockoutDuration: const Duration(minutes: 15),
        );

    test('阈值前不锁定；第 maxFailures 次失败即锁定', () {
      final FushiPinRateLimiter rl = limiter();
      expect(rl.isLockedOut('ip:1.2.3.4', t0), isFalse);
      expect(rl.recordFailure('ip:1.2.3.4', t0), isFalse); // 1
      expect(rl.recordFailure('ip:1.2.3.4', t0), isFalse); // 2
      expect(rl.isLockedOut('ip:1.2.3.4', t0), isFalse);
      expect(rl.recordFailure('ip:1.2.3.4', t0), isTrue); // 3 → 锁定
      expect(rl.isLockedOut('ip:1.2.3.4', t0), isTrue);
    });

    test('锁定退避窗口内被拒，窗口后自动恢复', () {
      final FushiPinRateLimiter rl = limiter();
      rl.recordFailure('ip:a', t0);
      rl.recordFailure('ip:a', t0);
      rl.recordFailure('ip:a', t0); // 锁定 15min
      // 窗口内仍锁定。
      expect(
          rl.isLockedOut('ip:a', t0.add(const Duration(minutes: 14))), isTrue);
      // 窗口后自动恢复（退避可恢复、有界）。
      expect(
          rl.isLockedOut('ip:a', t0.add(const Duration(minutes: 15))), isFalse);
      // 恢复后计数已清零：再失败一次不会立刻又锁。
      expect(rl.recordFailure('ip:a', t0.add(const Duration(minutes: 16))),
          isFalse);
    });

    test('成功配对清零该来源计数（不株连未来）', () {
      final FushiPinRateLimiter rl = limiter();
      rl.recordFailure('ip:b', t0);
      rl.recordFailure('ip:b', t0); // 2 次，未到阈值
      rl.recordSuccess('ip:b'); // 清零
      // 清零后再失败两次仍未锁（若没清零则第 1 次就到阈值 3）。
      expect(rl.recordFailure('ip:b', t0), isFalse); // 1
      expect(rl.recordFailure('ip:b', t0), isFalse); // 2
    });

    test('滑动窗口：失败冷却出窗口后计数重置', () {
      final FushiPinRateLimiter rl = limiter();
      rl.recordFailure('ip:c', t0); // 1
      rl.recordFailure('ip:c', t0); // 2
      // 距上次失败超过 5min 窗口 → 下一次失败视为窗口重开（计数=1，不触锁）。
      expect(rl.recordFailure('ip:c', t0.add(const Duration(minutes: 6))),
          isFalse);
    });

    test('不同来源各自独立计数（不互相株连）', () {
      final FushiPinRateLimiter rl = limiter();
      rl.recordFailure('ip:x', t0);
      rl.recordFailure('ip:x', t0);
      rl.recordFailure('ip:x', t0); // x 锁定
      expect(rl.isLockedOut('ip:x', t0), isTrue);
      expect(rl.isLockedOut('dev:y', t0), isFalse); // y 未受影响
    });

    test('prune 回收冷却记录但保留锁定中的记录', () {
      final FushiPinRateLimiter rl = limiter();
      rl.recordFailure('ip:cold', t0); // 单次失败，未锁
      rl.recordFailure('ip:hot', t0);
      rl.recordFailure('ip:hot', t0);
      rl.recordFailure('ip:hot', t0); // hot 锁定
      expect(rl.trackedSourceCount, 2);
      // 推进超过失败窗口但未到锁定期满：cold 应被回收，hot 仍保留（否则=提前解锁）。
      rl.prune(t0.add(const Duration(minutes: 6)));
      expect(rl.trackedSourceCount, 1);
      expect(
          rl.isLockedOut('ip:hot', t0.add(const Duration(minutes: 6))), isTrue);
    });

    test('跟踪来源数受上限约束（防伪造来源撑爆内存）', () {
      final FushiPinRateLimiter rl = FushiPinRateLimiter(
        maxFailures: 3,
        maxTrackedSources: 8,
      );
      for (int i = 0; i < 100; i++) {
        rl.recordFailure('ip:flood-$i', t0.add(Duration(seconds: i)));
      }
      expect(rl.trackedSourceCount, lessThanOrEqualTo(8));
    });
  });
}
