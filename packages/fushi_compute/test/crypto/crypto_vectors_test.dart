// 加密域与原 pointycastle Dart 实现逐字节一致（固定向量 crypto_vectors.json）。
//
// 原生库是硬依赖：找不到库（FUSHI_COMPUTE_LIB 或默认候选路径）这里直接失败，不 skip。
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

Map<String, Object?> _vectors() {
  final String sep = Platform.pathSeparator;
  final File file = File('test${sep}crypto${sep}crypto_vectors.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

void main() {
  final Map<String, Object?> vectors = _vectors();

  test('native library and crypto symbols are loadable', () {
    expect(() => FushiComputeCrypto.instance, returnsNormally);
  });

  test('AACS mixed stream: per-unit outcome, key rotation and bytes match', () {
    final Map<String, Object?> expected =
        vectors['aacs_mixed']! as Map<String, Object?>;
    final List<String> units = (expected['units']! as List<Object?>)
        .cast<String>();
    final Uint8List stream = aacsMixedStream();
    expect(_sha(stream), expected['ciphertext_sha256'], reason: 'ciphertext');
    final AacsNativeDecoder decoder = FushiComputeCrypto.instance.openAacs(
      aacsKeys().sublist(0, 3),
    );
    final List<String> outcomes = <String>[];
    // 整段一次调用；失败处记下形态，从下一单元接着解（等价于旧实现逐单元调用）。
    int unit = 0;
    final int total = stream.length ~/ kAacsUnit;
    while (unit < total) {
      final AacsUnitsResult result = decoder.decryptUnits(
        Uint8List.sublistView(stream, unit * kAacsUnit),
      );
      outcomes.addAll(List<String>.filled(result.unitsDone, 'ok'));
      unit += result.unitsDone;
      if (result.ok) break;
      outcomes.add(switch (result.status) {
        FfcCryptoStatus.aacsNoMatchingKey =>
          'FormatException: AACS content decryption failed: disc key mismatch or unsupported protection',
        FfcCryptoStatus.aacsClearUnitInvalid =>
          'FormatException: Invalid unencrypted Blu-ray transport unit',
        _ => 'status ${result.status}',
      });
      unit++;
    }
    expect(outcomes, units);
    expect(_sha(stream), expected['sha256']);
  });

  test('AACS failed unit and everything after it stay untouched', () {
    final List<Uint8List> keys = aacsKeys();
    final Uint8List batch = Uint8List(3 * kAacsUnit)
      ..setAll(0, encryptAacsUnit(keys[0], plainAacsUnit(1)))
      ..setAll(kAacsUnit, encryptAacsUnit(keys[3], plainAacsUnit(2)))
      ..setAll(2 * kAacsUnit, encryptAacsUnit(keys[0], plainAacsUnit(3)));
    final Uint8List original = Uint8List.fromList(batch);
    final AacsUnitsResult result = FushiComputeCrypto.instance
        .openAacs(<Uint8List>[keys[0]])
        .decryptUnits(batch);
    expect(result.status, FfcCryptoStatus.aacsNoMatchingKey);
    expect(result.unitsDone, 1);
    final Uint8List plain = plainAacsUnit(1);
    for (int offset = 0; offset < kAacsUnit; offset += 192) {
      plain[offset] &= 0x3f;
    }
    expect(Uint8List.sublistView(batch, 0, kAacsUnit), plain);
    expect(
      Uint8List.sublistView(batch, kAacsUnit),
      Uint8List.sublistView(original, kAacsUnit),
    );
  });

  test('AACS rejects partial units and empty key sets', () {
    final FushiComputeCrypto crypto = FushiComputeCrypto.instance;
    final AacsNativeDecoder decoder = crypto.openAacs(<Uint8List>[key16(1)]);
    expect(() => decoder.decryptUnits(Uint8List(6143)), throwsArgumentError);
    expect(() => decoder.decryptUnits(Uint8List(0)), throwsArgumentError);
    expect(() => crypto.openAacs(<Uint8List>[]), throwsArgumentError);
    expect(
      () => crypto.openAacs(<Uint8List>[Uint8List(15)]),
      throwsArgumentError,
    );
  });

  test('AES-128 ECB block decryption matches', () {
    final Uint8List data = pseudoRandomBytes(96, 78);
    FushiComputeCrypto.instance.aes128EcbDecryptInPlace(key16(77), data);
    expect(
      _sha(data),
      (vectors['aes128_ecb']! as Map<String, Object?>)['sha256'],
    );
  });

  group('HLS AES-CBC + PKCS7', () {
    final Map<String, Object?> expected =
        vectors['hls']! as Map<String, Object?>;
    for (final HlsVectorInput input in hlsVectorInputs()) {
      test(input.name, () {
        final Map<String, Object?> want = Map<String, Object?>.of(
          expected[input.name]! as Map<String, Object?>,
        );
        expect(_sha(input.data), want.remove('input_sha256'), reason: 'input');
        Object? got;
        try {
          final Uint8List out = FushiComputeCrypto.instance.aesCbcPkcs7Decrypt(
            input.data,
            input.key,
            input.iv,
          );
          got = <String, Object?>{'length': out.length, 'sha256': _sha(out)};
        } on ArgumentError catch (e) {
          got = <String, Object?>{'error': 'ArgumentError: ${e.message}'};
        }
        if (input.name == 'empty_input') {
          // pointycastle 对空输入抛 RangeError（越界 bug），原生绑定统一成 ArgumentError：
          // 两边都是「分片解不了」。
          expect(want['error'], startsWith('RangeError'));
          expect(got, <String, Object?>{
            'error':
                "ArgumentError: Input data length must be a multiple of cipher's block size",
          });
          return;
        }
        expect(got, want);
      });
    }
  });
}
