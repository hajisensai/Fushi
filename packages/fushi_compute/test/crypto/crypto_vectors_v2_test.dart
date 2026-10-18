// 加密域第二批：云同步 XOR 混淆与 P-256 ECDSA 的原生内核，与删除前的 Dart / pointycastle
// 实现逐字节一致（固定向量 crypto_vectors_v2.json）。
//
// 这里只验原生原语；带魔数 / 分块状态的 SyncObfuscator、带 SPKI / base64url 的
// LeaderboardIdentity、自签证书各在 fushi / fushi_engine 的测试里对同一份向量再验一遍。
// 原生库是硬依赖：找不到库这里直接失败，不 skip。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

import 'crypto_vector_inputs.dart';

String _sha(List<int> bytes) => hash.sha256.convert(bytes).toString();

Uint8List _hex(String hex) => Uint8List.fromList(<int>[
  for (int i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

Uint8List _b64url(String s) => base64Url.decode(base64Url.normalize(s));

Map<String, Object?> _vectors() {
  final String sep = Platform.pathSeparator;
  return jsonDecode(
        File('test${sep}crypto${sep}crypto_vectors_v2.json').readAsStringSync(),
      )
      as Map<String, Object?>;
}

void main() {
  final Map<String, Object?> vectors = _vectors();
  final FushiComputeCrypto crypto = FushiComputeCrypto.instance;

  group('sync XOR', () {
    final Map<String, Object?> v =
        vectors['sync_obfuscator']! as Map<String, Object?>;
    final Uint8List data = pseudoRandomBytes(100003, 901);

    test('input is the frozen one', () {
      expect(_sha(data), v['input_sha256']);
    });

    test('whole body from offset 0 (behind the 8-byte magic)', () {
      final Uint8List out = Uint8List(8 + data.length)
        ..setAll(0, const <int>[0x48, 0x42, 0x4B, 0x4F, 0x42, 0x46, 0x01, 0x00])
        ..setAll(8, crypto.syncXor(data, 0));
      expect(_sha(out), v['obfuscated_sha256']);
    });

    test('random access at arbitrary body offsets', () {
      final Uint8List obfuscated = Uint8List.fromList(crypto.syncXor(data, 0));
      final Map<String, Object?> at =
          v['body_at_offset_1000000_plus']! as Map<String, Object?>;
      for (final MapEntry<String, Object?> e in at.entries) {
        final int off = int.parse(e.key);
        final int len = (data.length - off).clamp(0, 5003);
        // 旧向量：把正文偏移 off 起的一段当作偏移 1000000 + off 来还原。
        expect(
          _sha(
            crypto.syncXor(
              Uint8List.sublistView(obfuscated, off, off + len),
              1000000 + off,
            ),
          ),
          e.value,
          reason: 'offset $off',
        );
      }
    });

    test('XOR is involutive and chunking-independent', () {
      final Uint8List whole = crypto.syncXor(data, 0);
      final List<int> pieced = <int>[];
      int offset = 0;
      for (final int size in const <int>[1, 7, 8, 31, 33, 4096, 65536]) {
        pieced.addAll(
          crypto.syncXor(
            Uint8List.sublistView(data, offset, offset + size),
            offset,
          ),
        );
        offset += size;
      }
      pieced.addAll(
        crypto.syncXor(Uint8List.sublistView(data, offset), offset),
      );
      expect(pieced, whole);
      expect(crypto.syncXor(whole, 0), data);
      expect(crypto.syncXor(const <int>[], 5), isEmpty);
    });
  });

  group('P-256 ECDSA primitives', () {
    final Map<String, Object?> v =
        vectors['ecdsa_p256']! as Map<String, Object?>;
    final List<String> messages = <String>[
      '',
      'a',
      'fushi-pair-device-v1\nsid\nhn\ncn\ndev\npub',
      '冴えない彼女の育てかた ' * 300,
    ];
    for (final String name in const <String>[
      'k0',
      'k1',
      'k2',
      'one',
      'n_minus_1',
    ]) {
      test('$name: public point and deterministic signatures', () {
        final Map<String, Object?> k = v[name]! as Map<String, Object?>;
        final Uint8List d = _hex(k['d']! as String);
        final Uint8List spki = _b64url(k['spki']! as String);
        final Uint8List point = crypto.p256PublicKey(d);
        expect(point, spki.sublist(26));
        final List<String> sigs = (k['signatures']! as List<Object?>)
            .cast<String>();
        for (int i = 0; i < messages.length; i++) {
          final Uint8List msg = Uint8List.fromList(utf8.encode(messages[i]));
          final Uint8List sig = crypto.p256SignSha256(d, msg);
          expect(sig, _b64url(sigs[i]), reason: 'message $i');
          expect(crypto.p256VerifySha256(point, msg, sig), isTrue);
        }
      });
    }

    test('invalid private keys throw ArgumentError', () {
      final BigInt n = BigInt.parse(
        'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
        radix: 16,
      );
      final Uint8List nBytes = _hex(n.toRadixString(16));
      expect(() => crypto.p256PublicKey(Uint8List(32)), throwsArgumentError);
      expect(() => crypto.p256PublicKey(nBytes), throwsArgumentError);
      expect(() => crypto.p256PublicKey(Uint8List(31)), throwsArgumentError);
      expect(
        () => crypto.p256SignSha256(Uint8List(32), const <int>[1]),
        throwsArgumentError,
      );
    });

    test(
      'verify rejects wrong lengths and off-curve points without throwing',
      () {
        final Map<String, Object?> k = v['k0']! as Map<String, Object?>;
        final Uint8List point = _b64url(k['spki']! as String).sublist(26);
        final Uint8List sig = _b64url(
          (k['signatures']! as List<Object?>)[2]! as String,
        );
        final Uint8List msg = Uint8List.fromList(utf8.encode(messages[2]));
        expect(crypto.p256VerifySha256(point.sublist(1), msg, sig), isFalse);
        expect(crypto.p256VerifySha256(point, msg, sig.sublist(1)), isFalse);
        final Uint8List offCurve = Uint8List.fromList(point)..[64] ^= 1;
        expect(crypto.p256VerifySha256(offCurve, msg, sig), isFalse);
      },
    );
  });
}
