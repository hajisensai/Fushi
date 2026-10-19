import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/video/bluray/aacs_content_decoder.dart';

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
    final crypto = FushiComputeCrypto.instance;
    keyFile.setAll(
      80,
      crypto.aesCbcEncryptNoPadding(firstKey, vuk, Uint8List(16)),
    );
    keyFile.setAll(
      128,
      crypto.aesCbcEncryptNoPadding(secondKey, vuk, Uint8List(16)),
    );
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

  group('failure classification (decoding still stops at the bad unit)', () {
    Matcher failure(
      AacsUnitFailure kind,
      int offset, {
      bool zeroFilled = false,
      String? text,
    }) => isA<AacsUnitDecryptException>()
        .having((e) => e.failure, 'failure', kind)
        .having((e) => e.unitOffset, 'unitOffset', offset)
        .having((e) => e.streamName, 'streamName', '00001.m2ts')
        .having((e) => e.zeroFilled, 'zeroFilled', zeroFilled)
        .having((e) => e.message, 'message', contains(text ?? ''));

    test('an all-zero unit is damaged data, never a key mismatch', () {
      // A read error filled with zeros: the first byte reads as "unencrypted".
      final decoder = AacsContentDecoder.fromUnitKeys([firstKey]);
      expect(
        () => decoder.decryptUnits(
          Uint8List(6144),
          streamOffset: 6144 * 7,
          streamName: '00001.m2ts',
        ),
        throwsA(
          failure(
            AacsUnitFailure.corruptData,
            6144 * 7,
            zeroFilled: true,
            text: 'at byte 43008 (aligned unit 7): the unit is all zero',
          ),
        ),
      );
    });

    test('a unit no key decodes after earlier units decrypted is damaged', () {
      final decoder = AacsContentDecoder.fromUnitKeys([firstKey, secondKey]);
      final bad = _encryptedUnit(firstKey);
      bad[192 - 16 + 4] ^= 1;
      final batch = Uint8List(3 * 6144)
        ..setAll(0, _encryptedUnit(secondKey))
        ..setAll(6144, bad)
        ..setAll(2 * 6144, _encryptedUnit(firstKey));
      final original = Uint8List.fromList(batch);
      expect(
        () => decoder.decryptUnits(
          batch,
          streamOffset: 6144 * 32,
          streamName: '00001.m2ts',
        ),
        throwsA(
          failure(
            AacsUnitFailure.corruptData,
            6144 * 33,
            text: 'earlier units of this stream decrypted with the disc key',
          ),
        ),
      );
      expect(Uint8List.sublistView(batch, 0, 6144), _plainUnit());
      expect(
        Uint8List.sublistView(batch, 6144),
        Uint8List.sublistView(original, 6144),
      );
    });

    test('a first encrypted unit no key decodes may be a key mismatch', () {
      final decoder = AacsContentDecoder.fromUnitKeys([firstKey]);
      // A clear unit decoding fine proves nothing about the key.
      decoder.decryptUnit(_plainUnit(), streamName: '00001.m2ts');
      expect(
        () => decoder.decryptUnit(
          _encryptedUnit(secondKey),
          streamOffset: 6144,
          streamName: '00001.m2ts',
        ),
        throwsA(
          failure(
            AacsUnitFailure.keyMismatchOrCorrupt,
            6144,
            text: 'the disc key does not match (check KEYDB.cfg)',
          ),
        ),
      );
    });

    test('a zero-filled sector is damaged data even without a prior unit', () {
      final decoder = AacsContentDecoder.fromUnitKeys([firstKey]);
      final unit = _encryptedUnit(firstKey)..fillRange(4096, 6144, 0);
      expect(
        () => decoder.decryptUnit(unit, streamName: '00001.m2ts'),
        throwsA(
          failure(
            AacsUnitFailure.corruptData,
            0,
            text: 'zero-filled 2048-byte sector',
          ),
        ),
      );
    });
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
  final blockKey = FushiComputeCrypto.instance.aesCbcEncryptNoPadding(
    unit.sublist(0, 16),
    key,
    Uint8List(16),
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
  unit.setAll(
    16,
    FushiComputeCrypto.instance.aesCbcEncryptNoPadding(
      unit.sublist(16),
      blockKey,
      iv,
    ),
  );
  return unit;
}
