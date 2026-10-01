import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// AACS 1 content decryption with already supplied disc keys.
///
/// Implements the aligned-unit format also used by VideoLAN libaacs
/// (unit_key.c, aacs.c and crypto.c). This does not obtain drive credentials,
/// process media key blocks, remove bus encryption, or implement AACS 2/BD+.
/// Keep each instance in the reader isolate; decrypted keys are never logged.
final class AacsContentDecoder {
  AacsContentDecoder._(this._keys);

  factory AacsContentDecoder.fromUnitKeys(Iterable<Uint8List> unitKeys) {
    final keys = <AESEngine>[];
    for (final key in unitKeys) {
      if (key.length != 16) {
        throw const FormatException('AACS unit key must contain 16 bytes');
      }
      keys.add(AESEngine()..init(true, KeyParameter(Uint8List.fromList(key))));
    }
    if (keys.isEmpty) {
      throw const FormatException('AACS disc has no usable unit keys');
    }
    return AacsContentDecoder._(keys);
  }

  factory AacsContentDecoder.fromVolumeUniqueKey({
    required Uint8List unitKeyFile,
    required Uint8List volumeUniqueKey,
  }) {
    if (volumeUniqueKey.length != 16) {
      throw const FormatException('AACS volume key must contain 16 bytes');
    }
    if (unitKeyFile.length < 20 || unitKeyFile[17] == 0) {
      throw const FormatException('Invalid AACS unit key file header');
    }
    final data = ByteData.sublistView(unitKeyFile);
    final offset = data.getUint32(0);
    if (offset > unitKeyFile.length - 2) {
      throw const FormatException('Truncated AACS unit key table');
    }
    final count = data.getUint16(offset);
    if (count == 0 || offset + 16 + count * 48 > unitKeyFile.length) {
      throw const FormatException('Invalid AACS unit key table');
    }
    final aes = AESEngine()..init(false, KeyParameter(volumeUniqueKey));
    final keys = <Uint8List>[];
    for (var index = 0; index < count; index++) {
      final key = Uint8List(16);
      aes.processBlock(unitKeyFile, offset + 48 * (index + 1), key, 0);
      keys.add(key);
    }
    return AacsContentDecoder.fromUnitKeys(keys);
  }

  static const int alignedUnitLength = 6144;
  static final Uint8List _iv = Uint8List.fromList(const [
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

  final List<AESEngine> _keys;
  int _lastKey = 0;
  final Uint8List _candidate = Uint8List(alignedUnitLength);
  final Uint8List _contentKey = Uint8List(16);

  /// Decrypts one complete, 6144-byte-aligned unit in place.
  ///
  /// Key changes are detected on every unit, including after arbitrary seeks.
  /// A failed decode leaves the original input unchanged.
  void decryptUnit(Uint8List unit) {
    if (unit.length != alignedUnitLength) {
      throw const FormatException('AACS requires a complete 6144-byte unit');
    }
    if ((unit[0] & 0xc0) == 0) {
      if (!_validTransport(unit)) {
        throw const FormatException(
          'Invalid unencrypted Blu-ray transport unit',
        );
      }
      return;
    }
    for (var attempt = 0; attempt < _keys.length; attempt++) {
      final keyIndex = (_lastKey + attempt) % _keys.length;
      _keys[keyIndex].processBlock(unit, 0, _contentKey, 0);
      for (var index = 0; index < 16; index++) {
        _contentKey[index] ^= unit[index];
      }
      final cipher = CBCBlockCipher(AESEngine())
        ..init(false, ParametersWithIV(KeyParameter(_contentKey), _iv));
      _candidate.setRange(0, 16, unit);
      for (var offset = 16; offset < alignedUnitLength; offset += 16) {
        cipher.processBlock(unit, offset, _candidate, offset);
      }
      if (!_validTransport(_candidate)) continue;
      for (var offset = 0; offset < alignedUnitLength; offset += 192) {
        _candidate[offset] &= 0x3f;
      }
      unit.setAll(0, _candidate);
      _lastKey = keyIndex;
      return;
    }
    throw const FormatException(
      'AACS content decryption failed: disc key mismatch or unsupported protection',
    );
  }

  static bool _validTransport(Uint8List unit) {
    for (var offset = 4; offset < alignedUnitLength; offset += 192) {
      if (unit[offset] != 0x47) return false;
    }
    return true;
  }
}
