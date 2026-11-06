// 加密域第二批：云同步文件混淆（整段文件 → 文件）与 P-256 ECDSA 的原生内核，与删除前的 Dart / pointycastle
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

    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ffc_sync_vec_');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });

    Uint8List run(void Function(String, String) op, List<int> input) {
      final File src = File('${dir.path}/in')..writeAsBytesSync(input);
      final File dst = File('${dir.path}/out');
      op(src.path, dst.path);
      return dst.readAsBytesSync();
    }

    test('obfuscate file = magic + XOR, matches the frozen bytes', () {
      final Uint8List out = run(crypto.syncObfuscateFile, data);
      expect(out.sublist(0, 8), const <int>[
        0x48, 0x42, 0x4B, 0x4F, 0x42, 0x46, 0x01, 0x00, //
      ]);
      expect(_sha(out), v['obfuscated_sha256']);
      expect(run(crypto.syncDeobfuscateFile, out), data);
    });

    test('multi-chunk file: the frozen prefix is unchanged, round-trips', () {
      // 3 MiB 多（跨 Rust 的 1 MiB 读块）：前 100003 字节就是冻结输入，其混淆前缀必须
      // 与冻结向量一致（位置绑定、与读块无关）。
      final Uint8List big = Uint8List(3 * 1024 * 1024 + 5)
        ..setAll(0, data)
        ..setAll(
          data.length,
          pseudoRandomBytes(3 * 1024 * 1024 + 5 - data.length, 7),
        );
      final Uint8List out = run(crypto.syncObfuscateFile, big);
      expect(out.length, big.length + 8);
      expect(
        _sha(Uint8List.sublistView(out, 0, 8 + data.length)),
        v['obfuscated_sha256'],
      );
      expect(run(crypto.syncDeobfuscateFile, out), big);
    });

    test('deobfuscate copies legacy plaintext (no magic / short) as is', () {
      expect(run(crypto.syncDeobfuscateFile, data), data);
      expect(run(crypto.syncDeobfuscateFile, const <int>[1, 2, 3]), const <int>[
        1,
        2,
        3,
      ]);
      expect(run(crypto.syncDeobfuscateFile, const <int>[]), isEmpty);
      expect(run(crypto.syncObfuscateFile, const <int>[]).length, 8);
    });

    test('non-ASCII paths (Chinese / space / kana / emoji) round-trip', () {
      // 用户安装版的数据根在 `D:\文档` 这类非 ASCII 路径下：源 / 目标路径各含一种。
      for (final String name in const <String>[
        '文档 数据',
        'with space',
        'かなカナ',
        'emoji 😀',
      ]) {
        final Directory sub = Directory(
          '${dir.path}${Platform.pathSeparator}$name',
        )..createSync();
        final String sep = Platform.pathSeparator;
        final File src = File('${sub.path}${sep}源 文件.bin')
          ..writeAsBytesSync(data);
        final File obf = File('${sub.path}${sep}混淆 ファイル😀.obf');
        final File back = File('${sub.path}${sep}还原 目标.bin');
        crypto.syncObfuscateFile(src.path, obf.path);
        expect(
          _sha(obf.readAsBytesSync()),
          v['obfuscated_sha256'],
          reason: name,
        );
        crypto.syncDeobfuscateFile(obf.path, back.path);
        expect(back.readAsBytesSync(), data, reason: name);
      }
    });

    test('I/O failure surfaces as FileSystemException', () {
      expect(
        () => crypto.syncDeobfuscateFile(
          '${dir.path}/missing',
          '${dir.path}/out',
        ),
        throwsA(isA<FileSystemException>()),
      );
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
