import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';

/// Why an aligned unit could not be decrypted.
enum AacsUnitFailure {
  /// The unit's bytes are damaged; the disc key is not at fault. Either the
  /// unit is marked unencrypted but is not a valid MPEG-TS unit (a zero-filled
  /// read error lands here), it contains a zero-filled 2048-byte sector, or no
  /// disc key decrypts it although this stream already decrypted units with
  /// the same keys.
  corruptData,

  /// No disc key decrypts the unit and nothing yet proves the keys right:
  /// a KEYDB entry that does not match the disc, unsupported protection, or a
  /// damaged first encrypted unit. The data alone cannot tell these apart.
  keyMismatchOrCorrupt,
}

/// A unit failed to decrypt. [unitOffset] is the unit's byte offset in the
/// stream file named [streamName] (a bare file name, never a full path).
///
/// Still a [FormatException], so existing `on FormatException` handlers keep
/// working; decoding stops at this unit either way.
final class AacsUnitDecryptException extends FormatException {
  AacsUnitDecryptException({
    required this.failure,
    required this.unitOffset,
    this.streamName,
    this.markedUnencrypted = false,
    this.zeroFilled = false,
    this.zeroSector = false,
  }) : super(
         _describe(
           failure,
           unitOffset,
           streamName,
           markedUnencrypted,
           zeroFilled,
           zeroSector,
         ),
       );

  final AacsUnitFailure failure;
  final int unitOffset;
  final String? streamName;

  /// The unit's header says it is not encrypted, yet it is not a valid
  /// transport unit (no key is involved in reading it).
  final bool markedUnencrypted;

  /// The whole 6144-byte unit is zero (typical read-error fill).
  final bool zeroFilled;

  /// At least one 2048-byte sector of the unit is zero.
  final bool zeroSector;

  static String _describe(
    AacsUnitFailure failure,
    int unitOffset,
    String? streamName,
    bool markedUnencrypted,
    bool zeroFilled,
    bool zeroSector,
  ) {
    final String where =
        '${streamName ?? 'the stream'} at byte $unitOffset '
        '(aligned unit ${unitOffset ~/ AacsContentDecoder.alignedUnitLength})';
    return switch (failure) {
      AacsUnitFailure.corruptData when zeroFilled =>
        'Corrupt Blu-ray stream data in $where: the unit is all zero, typically '
            'a disc read error filled with zeros; not a disc key problem',
      AacsUnitFailure.corruptData when zeroSector =>
        'Corrupt Blu-ray stream data in $where: the unit contains a '
            'zero-filled 2048-byte sector (disc read error); not a disc key '
            'problem',
      AacsUnitFailure.corruptData when markedUnencrypted =>
        'Corrupt Blu-ray stream data in $where: the unit is marked unencrypted '
            'but is not a valid MPEG-TS unit; not a disc key problem',
      AacsUnitFailure.corruptData =>
        'Corrupt Blu-ray stream data in $where: earlier units of this stream '
            'decrypted with the disc key but this one does not decode; the '
            'disc or its copy is damaged',
      AacsUnitFailure.keyMismatchOrCorrupt =>
        'AACS decryption failed in $where: the disc key does not match '
            '(check KEYDB.cfg), the protection is unsupported, or the data is '
            'damaged',
    };
  }
}

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
  void decryptUnit(Uint8List unit, {int streamOffset = 0, String? streamName}) {
    if (unit.length != alignedUnitLength) {
      throw const FormatException('AACS requires a complete 6144-byte unit');
    }
    decryptUnits(unit, streamOffset: streamOffset, streamName: streamName);
  }

  /// Decrypts consecutive whole units in place with a single native call.
  ///
  /// Units are processed in order. On the first unit that fails, that unit and
  /// everything after it are left unchanged (the ones before it are already
  /// decrypted) and an [AacsUnitDecryptException] is thrown — the same outcome
  /// as calling [decryptUnit] unit by unit and stopping at the first error.
  ///
  /// [streamOffset] is the byte offset of [units] in the stream file and
  /// [streamName] its bare file name; both only label the error.
  void decryptUnits(
    Uint8List units, {
    int streamOffset = 0,
    String? streamName,
  }) {
    if (units.isEmpty || units.length % alignedUnitLength != 0) {
      throw const FormatException('AACS requires a complete 6144-byte unit');
    }
    final AacsUnitsResult result = _native.decryptUnits(units);
    if (result.ok) return;
    final int start = result.unitsDone * alignedUnitLength;
    // A failed unit is left untouched, so these describe the bytes as read.
    final Uint8List unit = Uint8List.sublistView(
      units,
      start,
      start + alignedUnitLength,
    );
    bool zeroSector = false;
    bool zeroFilled = true;
    for (int sector = 0; sector < alignedUnitLength; sector += 2048) {
      bool zero = true;
      for (int i = sector; i < sector + 2048; i++) {
        if (unit[i] != 0) {
          zero = false;
          break;
        }
      }
      zeroSector = zeroSector || zero;
      zeroFilled = zeroFilled && zero;
    }
    throw AacsUnitDecryptException(
      failure: result.status == FfcCryptoStatus.aacsNoMatchingKey
          ? AacsUnitFailure.keyMismatchOrCorrupt
          : AacsUnitFailure.corruptData,
      unitOffset: streamOffset + start,
      streamName: streamName,
      markedUnencrypted: result.status == FfcCryptoStatus.aacsClearUnitInvalid,
      zeroFilled: zeroFilled,
      zeroSector: zeroSector,
    );
  }
}
