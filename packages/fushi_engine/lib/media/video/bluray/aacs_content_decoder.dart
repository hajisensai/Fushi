import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';

/// AACS 1 content decryption with already supplied disc keys.
///
/// Implements the aligned-unit format also used by VideoLAN libaacs
/// (unit_key.c, aacs.c and crypto.c). This does not obtain drive credentials,
/// process media key blocks, remove bus encryption, or implement AACS 2/BD+.
///
/// The cipher work (unit key derivation, CBC, TS sync check, CPI clearing and
/// the multi-key retry) runs in native/fushi_compute (`ffc_crypto_aacs_*`),
/// one FFI call per batch of units. The native library is required: without it
/// construction throws [FushiComputeUnavailableError]. Keep each instance in the
/// isolate that created it; decrypted keys are never logged.
final class AacsContentDecoder {
  AacsContentDecoder._(this._native);

  factory AacsContentDecoder.fromUnitKeys(Iterable<Uint8List> unitKeys) {
    final List<Uint8List> keys = <Uint8List>[];
    for (final Uint8List key in unitKeys) {
      if (key.length != 16) {
        throw const FormatException('AACS unit key must contain 16 bytes');
      }
      keys.add(key);
    }
    if (keys.isEmpty) {
      throw const FormatException('AACS disc has no usable unit keys');
    }
    return AacsContentDecoder._(FushiComputeCrypto.instance.openAacs(keys));
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
    final ByteData data = ByteData.sublistView(unitKeyFile);
    final int offset = data.getUint32(0);
    if (offset > unitKeyFile.length - 2) {
      throw const FormatException('Truncated AACS unit key table');
    }
    final int count = data.getUint16(offset);
    if (count == 0 || offset + 16 + count * 48 > unitKeyFile.length) {
      throw const FormatException('Invalid AACS unit key table');
    }
    final Uint8List encrypted = Uint8List(count * 16);
    for (int index = 0; index < count; index++) {
      final int start = offset + 48 * (index + 1);
      encrypted.setRange(index * 16, index * 16 + 16, unitKeyFile, start);
    }
    FushiComputeCrypto.instance.aes128EcbDecryptInPlace(
      volumeUniqueKey,
      encrypted,
    );
    final List<Uint8List> keys = <Uint8List>[
      for (int index = 0; index < count; index++)
        Uint8List.sublistView(encrypted, index * 16, index * 16 + 16),
    ];
    try {
      return AacsContentDecoder.fromUnitKeys(keys);
    } finally {
      encrypted.fillRange(0, encrypted.length, 0);
    }
  }

  static const int alignedUnitLength = 6144;

  final AacsNativeDecoder _native;

  /// Decrypts one complete, 6144-byte-aligned unit in place.
  ///
  /// Key changes are detected on every unit, including after arbitrary seeks.
  /// A failed decode leaves the original input unchanged.
  void decryptUnit(Uint8List unit) {
    if (unit.length != alignedUnitLength) {
      throw const FormatException('AACS requires a complete 6144-byte unit');
    }
    decryptUnits(unit);
  }

  /// Decrypts consecutive whole units in place with a single native call.
  ///
  /// Units are processed in order. On the first unit that fails, that unit and
  /// everything after it are left unchanged (the ones before it are already
  /// decrypted) and a [FormatException] is thrown — the same outcome as calling
  /// [decryptUnit] unit by unit and stopping at the first error.
  void decryptUnits(Uint8List units) {
    if (units.isEmpty || units.length % alignedUnitLength != 0) {
      throw const FormatException('AACS requires a complete 6144-byte unit');
    }
    final AacsUnitsResult result = _native.decryptUnits(units);
    switch (result.status) {
      case FfcStatus.ok:
        return;
      case FfcCryptoStatus.aacsClearUnitInvalid:
        throw const FormatException(
          'Invalid unencrypted Blu-ray transport unit',
        );
      default:
        throw const FormatException(
          'AACS content decryption failed: disc key mismatch or unsupported protection',
        );
    }
  }
}
