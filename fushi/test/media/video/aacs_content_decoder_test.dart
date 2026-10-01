import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/aacs_content_decoder.dart';
import 'package:pointycastle/export.dart';

void main() {
  final firstKey = Uint8List.fromList(List.generate(16, (i) => i));
  final secondKey = Uint8List.fromList(List.generate(16, (i) => 255 - i));

  test(
    'synthetic ciphertext agrees with independently generated AES vector',
    () {
      // Generated with System.Security.Cryptography.Aes (ECB derivation / CBC).
      expect(
        _encryptedUnit(firstKey).sublist(16, 48),
        base64Decode('kBc2giCyQQqCr49ZqMN+DAsmJ0AwmcTTgzahM2jejGI='),
      );
    },
  );

  test(
    'decodes every packet and detects CPS changes after arbitrary seeks',
    () {
      final decoder = AacsContentDecoder.fromUnitKeys([firstKey, secondKey]);
      for (final key in [secondKey, firstKey, secondKey]) {
        final unit = _encryptedUnit(key);
        decoder.decryptUnit(unit);
        expect(unit, _plainUnit());
      }
    },
  );

  test('decrypts the unit key table with a volume unique key', () {
    final vuk = Uint8List.fromList(List.generate(16, (i) => 99 + i));
    final keyFile = Uint8List(32 + 16 + 48 * 2);
    final header = ByteData.sublistView(keyFile)..setUint32(0, 32);
    keyFile[16] = 1;
    keyFile[17] = 1;
    header.setUint16(32, 2);
    final aes = AESEngine()..init(true, KeyParameter(vuk));
    aes.processBlock(firstKey, 0, keyFile, 80);
    aes.processBlock(secondKey, 0, keyFile, 128);
    final decoder = AacsContentDecoder.fromVolumeUniqueKey(
      unitKeyFile: keyFile,
      volumeUniqueKey: vuk,
    );
    final unit = _encryptedUnit(secondKey);
    decoder.decryptUnit(unit);
    expect(unit, _plainUnit());
  });

  test('wrong keys and corrupted packets fail without changing ciphertext', () {
    final decoder = AacsContentDecoder.fromUnitKeys([firstKey]);
    final unit = _encryptedUnit(secondKey);
    final original = Uint8List.fromList(unit);
    expect(() => decoder.decryptUnit(unit), throwsFormatException);
    expect(unit, original);
    final corrupted = _encryptedUnit(firstKey)..[3000] ^= 0x80;
    // Corrupt a TS sync byte, not merely payload (AACS has no payload MAC).
    corrupted[192 - 16 + 4] ^= 1;
    expect(() => decoder.decryptUnit(corrupted), throwsFormatException);
  });

  test('clear units pass through and partial units fail explicitly', () {
    final decoder = AacsContentDecoder.fromUnitKeys([firstKey]);
    final plain = _plainUnit();
    decoder.decryptUnit(plain);
    expect(plain, _plainUnit());
    expect(() => decoder.decryptUnit(Uint8List(6143)), throwsFormatException);
    expect(() => decoder.decryptUnit(Uint8List(6144)), throwsFormatException);
  });

  test('rejects malformed key files and key lengths', () {
    expect(() => AacsContentDecoder.fromUnitKeys([]), throwsFormatException);
    expect(
      () => AacsContentDecoder.fromUnitKeys([Uint8List(15)]),
      throwsFormatException,
    );
    for (final length in [0, 19, 20, 32, 80]) {
      final file = Uint8List(length);
      if (length >= 20) {
        file[17] = 1;
        ByteData.sublistView(file).setUint32(0, 0xffffffff);
      }
      expect(
        () => AacsContentDecoder.fromVolumeUniqueKey(
          unitKeyFile: file,
          volumeUniqueKey: firstKey,
        ),
        throwsFormatException,
      );
    }
  });
}

Uint8List _plainUnit() {
  final unit = Uint8List.fromList(List.generate(6144, (i) => (i * 7) & 255));
  for (var offset = 0; offset < unit.length; offset += 192) {
    unit[offset] &= 0x3f;
    unit[offset + 4] = 0x47;
  }
  return unit;
}

Uint8List _encryptedUnit(Uint8List key) {
  final unit = _plainUnit();
  for (var offset = 0; offset < unit.length; offset += 192) {
    unit[offset] |= 0x40;
  }
  final blockKey = Uint8List(16);
  (AESEngine()..init(true, KeyParameter(key))).processBlock(
    unit,
    0,
    blockKey,
    0,
  );
  for (var i = 0; i < 16; i++) {
    blockKey[i] ^= unit[i];
  }
  final iv = Uint8List.fromList([
    0x0b,
    0xa0,
    0xf8,
    0xdd,
    0xfe,
    0xa6,
    0x1f,
    0xb3,
    0xd8,
    0xdf,
    0x9f,
    0x56,
    0x6a,
    0x05,
    0x0f,
    0x78,
  ]);
  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(blockKey), iv));
  for (var offset = 16; offset < unit.length; offset += 16) {
    cipher.processBlock(unit, offset, unit, offset);
  }
  return unit;
}
