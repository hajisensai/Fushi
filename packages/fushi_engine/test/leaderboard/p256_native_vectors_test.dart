// LeaderboardIdentity / 互联设备钥匙 / host 自签证书改走 native/fushi_compute 之后，与删除前
// 的 pointycastle / basic_utils 实现逐字节一致：签名、SPKI、账户 id、验签结果（含 high-s、
// 混合编码点等边角）、证书 TBS 与 PKCS#8 私钥 PEM。向量由旧实现生成：
// packages/fushi_compute/test/crypto/crypto_vectors_v2.json。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/sync/pairing/interconnect_device_key.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:test/test.dart';

Map<String, Object?> _vectors() {
  final String sep = Platform.pathSeparator;
  return jsonDecode(
        File(
          '..${sep}fushi_compute${sep}test${sep}crypto${sep}crypto_vectors_v2.json',
        ).readAsStringSync(),
      )
      as Map<String, Object?>;
}

Uint8List _hex(String hex) => Uint8List.fromList(<int>[
  for (int i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

String _toHex(List<int> b) =>
    b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _be32(BigInt v) {
  final Uint8List out = Uint8List(32);
  for (int i = 31; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}

BigInt _big(List<int> b) =>
    b.fold(BigInt.zero, (BigInt a, int x) => (a << 8) | BigInt.from(x));

void main() {
  final Map<String, Object?> vectors = _vectors();
  final Map<String, Object?> ecdsa =
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
    test(
      'LeaderboardIdentity $name: spki / accountId / signatures / verify',
      () {
        final Map<String, Object?> k = ecdsa[name]! as Map<String, Object?>;
        final LeaderboardIdentity id = LeaderboardIdentity.fromPrivateKey(
          _hex(k['d']! as String),
        );
        expect(id.pubkeyBase64Url, k['spki']);
        expect(id.accountId, k['accountId']);
        final List<String> sigs = (k['signatures']! as List<Object?>)
            .cast<String>();
        for (int i = 0; i < messages.length; i++) {
          expect(id.sign(messages[i]), sigs[i], reason: 'message $i');
        }

        // 与生成器同样构造的验签边角，结果必须与旧实现相同。
        final Uint8List spki = id.spki;
        final String m = messages[2];
        final Uint8List sig0 = leaderboardBase64UrlDecode(sigs[2]);
        final BigInt r = _big(sig0.sublist(0, 32));
        final BigInt s = _big(sig0.sublist(32));
        final Uint8List flipped = Uint8List.fromList(sig0)..[40] ^= 1;
        final Uint8List hybrid = Uint8List.fromList(spki)
          ..[26] = (spki[90] & 1) == 1 ? 0x07 : 0x06;
        final Uint8List hybridWrong = Uint8List.fromList(spki)
          ..[26] = (spki[90] & 1) == 1 ? 0x06 : 0x07;
        final Uint8List offCurve = Uint8List.fromList(spki)..[90] ^= 1;
        final Map<String, bool> got = <String, bool>{
          'valid': LeaderboardIdentity.verify(spki, m, sigs[2]),
          'other_message': LeaderboardIdentity.verify(spki, '$m ', sigs[2]),
          'high_s': LeaderboardIdentity.verify(
            spki,
            m,
            leaderboardBase64Url(<int>[..._be32(r), ..._be32(kP256Order - s)]),
          ),
          'flipped': LeaderboardIdentity.verify(
            spki,
            m,
            leaderboardBase64Url(flipped),
          ),
          'r_zero': LeaderboardIdentity.verify(
            spki,
            m,
            leaderboardBase64Url(<int>[...Uint8List(32), ..._be32(s)]),
          ),
          's_n': LeaderboardIdentity.verify(
            spki,
            m,
            leaderboardBase64Url(<int>[..._be32(r), ..._be32(kP256Order)]),
          ),
          'short_sig': LeaderboardIdentity.verify(
            spki,
            m,
            leaderboardBase64Url(sig0.sublist(0, 63)),
          ),
          'bad_base64': LeaderboardIdentity.verify(spki, m, '***'),
          'hybrid_point': LeaderboardIdentity.verify(hybrid, m, sigs[2]),
          'hybrid_wrong_parity': LeaderboardIdentity.verify(
            hybridWrong,
            m,
            sigs[2],
          ),
          'off_curve': LeaderboardIdentity.verify(offCurve, m, sigs[2]),
          'short_spki': LeaderboardIdentity.verify(
            spki.sublist(0, 90),
            m,
            sigs[2],
          ),
        };
        expect(got, k['verify']);
      },
    );
  }

  test('invalid private keys throw ArgumentError as before', () {
    expect(
      () => LeaderboardIdentity.fromPrivateKey(Uint8List(32)),
      throwsArgumentError,
    );
    expect(
      () => LeaderboardIdentity.fromPrivateKey(_be32(kP256Order)),
      throwsArgumentError,
    );
    expect(
      () => LeaderboardIdentity.fromPrivateKey(Uint8List(31)),
      throwsArgumentError,
    );
  });

  test(
    'interconnect device key: sign / verify roundtrip, encoding unchanged',
    () {
      final Map<String, Object?> k = ecdsa['k1']! as Map<String, Object?>;
      final Uint8List d = _hex(k['d']! as String);
      final InterconnectDeviceKey key = InterconnectDeviceKey.decodePrivateKey(
        leaderboardBase64Url(d),
      );
      expect(key.pubkey, k['spki']);
      expect(key.encodePrivateKey(), leaderboardBase64Url(d));
      final String proof = key.signPairProof(
        sessionId: 's',
        hostNonce: 'h',
        clientNonce: 'c',
        clientDeviceId: 'dev',
      );
      expect(
        verifyInterconnectPairDeviceProof(
          sessionId: 's',
          hostNonce: 'h',
          clientNonce: 'c',
          clientDeviceId: 'dev',
          devicePubkey: key.pubkey,
          proof: proof,
        ),
        isTrue,
      );
    },
  );

  group('self-signed TLS certificate', () {
    final Map<String, Object?> t =
        vectors['tls_self_signed']! as Map<String, Object?>;
    final Uint8List d = _hex(t['d']! as String);
    final ({Uint8List tbsDer, String certificatePem, String privateKeyPem})
    built = FushiSelfSignedCertGenerator.build(
      privateKey: d,
      commonName: t['cn']! as String,
      sans: (t['sans']! as List<Object?>).cast<String>(),
      notBefore: DateTime.parse(t['not_before_utc']! as String),
      days: t['days']! as int,
    );

    test('TBSCertificate bytes and PKCS#8 PEM match basic_utils', () {
      expect(_toHex(built.tbsDer), t['tbs_der_hex']);
      expect(built.privateKeyPem, t['private_key_pkcs8_pem']);
    });

    test('certificate PEM framing matches and the signature verifies', () {
      final String oldPem = t['certificate_pem_example']! as String;
      // 头尾与行分隔（\r\n）与旧实现一致；签名值不同（旧实现 k 随机，现为 RFC 6979）。
      expect(
        built.certificatePem.startsWith('-----BEGIN CERTIFICATE-----\n'),
        isTrue,
      );
      expect(
        built.certificatePem.endsWith('\n-----END CERTIFICATE-----'),
        isTrue,
      );
      expect(
        built.certificatePem.split('\r\n').length,
        oldPem.split('\r\n').length,
      );
      final String body = built.certificatePem
          .split('\n')
          .where((String l) => !l.startsWith('-----'))
          .join()
          .replaceAll('\r', '');
      final Uint8List der = base64.decode(body);
      final String derHex = _toHex(der);
      expect(derHex.contains(t['tbs_der_hex']! as String), isTrue);
      expect(derHex.contains(t['sig_alg_der_hex']! as String), isTrue);
      // 签名 = DER SEQ{INTEGER r, INTEGER s}，对 TBS 验签。
      final LeaderboardIdentity id = LeaderboardIdentity.fromPrivateKey(d);
      final Uint8List point = id.spki.sublist(26);
      final Uint8List sigDer = _lastBitString(der);
      final (BigInt rr, BigInt ss) = _parseSig(sigDer);
      expect(
        FushiComputeCrypto.instance.p256VerifySha256(
          point,
          built.tbsDer,
          Uint8List.fromList(<int>[..._be32(rr), ..._be32(ss)]),
        ),
        isTrue,
      );
      expect(
        FushiTlsIdentityStore.fingerprintOf(built.certificatePem),
        isNotEmpty,
      );
    });
  });
}

/// 证书 DER 末尾的 BIT STRING（签名值）去掉「未用位」字节后的内容。
Uint8List _lastBitString(Uint8List der) {
  // 外层 SEQUENCE 头。
  int i = 1;
  i += der[i] & 0x80 != 0 ? 1 + (der[i] & 0x7f) : 1;
  // 依次跳过 tbs、sigAlg。
  for (int skip = 0; skip < 2; skip++) {
    i = _next(der, i);
  }
  // BIT STRING。
  int len = der[i + 1];
  int body = i + 2;
  if (len & 0x80 != 0) {
    final int n = len & 0x7f;
    len = 0;
    for (int j = 0; j < n; j++) {
      len = (len << 8) | der[i + 2 + j];
    }
    body = i + 2 + n;
  }
  return Uint8List.sublistView(der, body + 1, body + len);
}

int _next(Uint8List der, int i) {
  int len = der[i + 1];
  int body = i + 2;
  if (len & 0x80 != 0) {
    final int n = len & 0x7f;
    len = 0;
    for (int j = 0; j < n; j++) {
      len = (len << 8) | der[i + 2 + j];
    }
    body = i + 2 + n;
  }
  return body + len;
}

(BigInt, BigInt) _parseSig(Uint8List seq) {
  int i = 2; // SEQUENCE 头（签名长度 < 128）
  final int rLen = seq[i + 1];
  final BigInt r = _big(seq.sublist(i + 2, i + 2 + rLen));
  i += 2 + rLen;
  final int sLen = seq[i + 1];
  final BigInt s = _big(seq.sublist(i + 2, i + 2 + sLen));
  return (r, s);
}
