import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_signing.dart';
import 'package:test/test.dart';

import 'leaderboard_test_support.dart';

/// Dart 向量的固定私钥：sha256('fushi-leaderboard-dart-vector-1')。固定私钥 + RFC 6979
/// 确定性签名 → 生成的 dart-pointycastle.json 逐字节可复现。
Uint8List _vectorKey() => Uint8List.fromList(
  crypto.sha256.convert(utf8.encode('fushi-leaderboard-dart-vector-1')).bytes,
);

void main() {
  group('签名串', () {
    test('与 auth.js signingString 同形：方法大写、空体哈希', () {
      expect(
        leaderboardSigningString('get', '/v1/me', 5, const <int>[]),
        'GET\n/v1/me\n5\n'
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });
  });

  group('LeaderboardIdentity', () {
    test('SPKI 91 字节、未压缩点、账户 id 16 字符', () {
      final LeaderboardIdentity id = LeaderboardIdentity.fromPrivateKey(
        _vectorKey(),
      );
      expect(id.spki.length, 91);
      expect(id.spki[26], 0x04);
      expect(id.accountId.length, 16);
      expect(id.accountId, leaderboardAccountIdFromSpki(id.spki));
      expect(id.privateKey, _vectorKey());
    });

    test('generate 可注入随机源且可复现；默认源每次不同', () {
      final LeaderboardIdentity a = LeaderboardIdentity.generate(
        random: Random(7),
      );
      final LeaderboardIdentity b = LeaderboardIdentity.generate(
        random: Random(7),
      );
      expect(a.accountId, b.accountId);
      expect(
        LeaderboardIdentity.generate().accountId,
        isNot(LeaderboardIdentity.generate().accountId),
      );
    });

    test('签名确定性、可验、改消息 / 改签名 / 换钥匙都不过', () {
      final LeaderboardIdentity id = LeaderboardIdentity.fromPrivateKey(
        _vectorKey(),
      );
      final String sig = id.sign('hello');
      expect(id.sign('hello'), sig);
      expect(leaderboardBase64UrlDecode(sig).length, 64);
      expect(sig.contains('='), isFalse);
      expect(LeaderboardIdentity.verify(id.spki, 'hello', sig), isTrue);
      expect(LeaderboardIdentity.verify(id.spki, 'hello ', sig), isFalse);
      final LeaderboardIdentity other = LeaderboardIdentity.generate(
        random: Random(1),
      );
      expect(LeaderboardIdentity.verify(other.spki, 'hello', sig), isFalse);
      expect(LeaderboardIdentity.verify(id.spki, 'hello', 'AAAA'), isFalse);
      expect(LeaderboardIdentity.verify(id.spki, 'hello', '!!'), isFalse);
      expect(LeaderboardIdentity.verify(Uint8List(10), 'hello', sig), isFalse);
    });

    test('私钥长度或范围不对抛 ArgumentError', () {
      expect(
        () => LeaderboardIdentity.fromPrivateKey(Uint8List(31)),
        throwsArgumentError,
      );
      expect(
        () => LeaderboardIdentity.fromPrivateKey(Uint8List(32)),
        throwsArgumentError,
      );
      expect(
        () => LeaderboardIdentity.fromPrivateKey(
          Uint8List.fromList(List<int>.filled(32, 0xff)),
        ),
        throwsArgumentError,
      );
    });
  });

  group('恢复码', () {
    test('往返一致，容忍首尾空白', () {
      final LeaderboardIdentity id = LeaderboardIdentity.fromPrivateKey(
        _vectorKey(),
      );
      final String code = id.toRecoveryCode();
      expect(code, startsWith('FUSHI1-'));
      expect(code.length, 'FUSHI1-'.length + 43 + 1 + 4);
      final LeaderboardIdentity back = LeaderboardIdentity.fromRecoveryCode(
        '  $code\n',
      );
      expect(back.accountId, id.accountId);
      expect(back.privateKey, id.privateKey);
    });

    test('私钥段含 - 也能按定长解析（多把随机钥匙）', () {
      final Random rng = Random(42);
      for (int i = 0; i < 64; i++) {
        final LeaderboardIdentity id = LeaderboardIdentity.generate(
          random: rng,
        );
        expect(
          LeaderboardIdentity.fromRecoveryCode(id.toRecoveryCode()).accountId,
          id.accountId,
        );
      }
    });

    test('校验和 / 前缀 / 长度错抛 FormatException', () {
      final String code = LeaderboardIdentity.fromPrivateKey(
        _vectorKey(),
      ).toRecoveryCode();
      final String last = code[code.length - 1];
      final String flipped =
          code.substring(0, code.length - 1) + (last == 'A' ? 'B' : 'A');
      expect(
        () => LeaderboardIdentity.fromRecoveryCode(flipped),
        throwsFormatException,
      );
      expect(
        () => LeaderboardIdentity.fromRecoveryCode(code.substring(1)),
        throwsFormatException,
      );
      expect(
        () => LeaderboardIdentity.fromRecoveryCode('${code}A'),
        throwsFormatException,
      );
      expect(
        () => LeaderboardIdentity.fromRecoveryCode(''),
        throwsFormatException,
      );
      // 私钥段改一个字符：校验和对不上。
      final String keyFlip =
          'FUSHI1-${code[7] == 'A' ? 'B' : 'A'}${code.substring(8)}';
      expect(
        () => LeaderboardIdentity.fromRecoveryCode(keyFlip),
        throwsFormatException,
      );
    });
  });

  group('跨语言向量', () {
    test('JS WebCrypto 向量：签名串 / SPKI / 账户 id 一致，JS 签名 Dart 能验', () {
      final Map<String, dynamic> v = readVector('js-webcrypto.json');
      final Map<String, dynamic> jwk = (v['jwk'] as Map<Object?, Object?>)
          .cast<String, dynamic>();
      expect(
        leaderboardSigningString(
          v['method'] as String,
          v['path'] as String,
          v['time'] as int,
          utf8.encode(v['body'] as String),
        ),
        v['message'],
      );
      final LeaderboardIdentity id = LeaderboardIdentity.fromPrivateKey(
        leaderboardBase64UrlDecode(jwk['d'] as String),
      );
      expect(id.pubkeyBase64Url, v['spki']);
      expect(id.accountId, v['accountId']);
      expect(
        LeaderboardIdentity.verify(
          id.spki,
          v['message'] as String,
          v['signature'] as String,
        ),
        isTrue,
      );
      expect(
        LeaderboardIdentity.verify(
          id.spki,
          '${v['message']} ',
          v['signature'] as String,
        ),
        isFalse,
      );
    });

    test('生成 dart-pointycastle.json（Worker 侧 vectors.test.js 验证）', () {
      final LeaderboardIdentity id = LeaderboardIdentity.fromPrivateKey(
        _vectorKey(),
      );
      const String method = 'POST';
      const String path = '/v1/shelf?x=1';
      const int time = 1790000000000;
      final String body = jsonEncode(<String, dynamic>{
        'put': <Map<String, dynamic>>[
          <String, dynamic>{
            'kind': 'book',
            'refs': <String>['isbn:9784040000011'],
            'title': '冴えない彼女の育てかた 11',
          },
        ],
      });
      final String message = leaderboardSigningString(
        method,
        path,
        time,
        utf8.encode(body),
      );
      final Uint8List spki = id.spki;
      final Map<String, dynamic> vector = <String, dynamic>{
        'producer': 'dart-pointycastle',
        'jwk': <String, dynamic>{
          'kty': 'EC',
          'crv': 'P-256',
          'd': leaderboardBase64Url(id.privateKey),
          'x': leaderboardBase64Url(spki.sublist(27, 59)),
          'y': leaderboardBase64Url(spki.sublist(59, 91)),
        },
        'spki': id.pubkeyBase64Url,
        'accountId': id.accountId,
        'method': method,
        'path': path,
        'time': time,
        'body': body,
        'message': message,
        'signature': id.sign(message),
      };
      expect(
        LeaderboardIdentity.verify(
          spki,
          message,
          vector['signature'] as String,
        ),
        isTrue,
      );
      final String text =
          '${const JsonEncoder.withIndent('  ').convert(vector)}\n';
      final File out = File(
        '${leaderboardVectorDir().path}/dart-pointycastle.json',
      );
      if (!out.existsSync() || out.readAsStringSync() != text) {
        out.writeAsStringSync(text);
      }
      expect(out.readAsStringSync(), text);
    });
  });
}
