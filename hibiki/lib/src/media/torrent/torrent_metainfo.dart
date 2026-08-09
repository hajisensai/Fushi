import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:hibiki/src/media/torrent/torrent_backend.dart';

const int kMaximumTorrentMetainfoBytes = 16 * 1024 * 1024;

enum TorrentMetainfoErrorCode {
  empty,
  tooLarge,
  invalidBencode,
  missingInfo,
  unsupportedVersion,
  hashMismatch,
}

class TorrentMetainfoException extends FormatException {
  TorrentMetainfoException(this.code, String detail)
      : super('torrent metainfo ${code.name}: $detail');

  final TorrentMetainfoErrorCode code;
}

class InspectedTorrentMetainfo {
  InspectedTorrentMetainfo({
    required Uint8List bytes,
    required this.torrentId,
    required this.v1InfoHash,
    required this.v2InfoHash,
  }) : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;

  /// 40-character id used by the existing native/qB backends. Pure v2
  /// torrents use the first 20 bytes of the SHA-256 info hash.
  final String torrentId;
  final String? v1InfoHash;
  final String? v2InfoHash;

  TorrentMetainfoPayload toPayload({required String fileName}) =>
      TorrentMetainfoPayload(
        bytes: bytes,
        fileName: fileName,
        torrentId: torrentId,
        v1InfoHash: v1InfoHash,
        v2InfoHash: v2InfoHash,
      );
}

/// Validates bencode and hashes the exact raw `info` dictionary byte range.
InspectedTorrentMetainfo inspectTorrentMetainfo(
  Uint8List bytes, {
  String? expectedInfoHash,
}) {
  if (bytes.isEmpty) {
    throw TorrentMetainfoException(
      TorrentMetainfoErrorCode.empty,
      'body was empty',
    );
  }
  if (bytes.length > kMaximumTorrentMetainfoBytes) {
    throw TorrentMetainfoException(
      TorrentMetainfoErrorCode.tooLarge,
      'body exceeds $kMaximumTorrentMetainfoBytes bytes',
    );
  }

  final _BencodeReader reader = _BencodeReader(bytes);
  final _RootDictionary root = reader.readRootDictionary();
  final Map<String, Object?>? info = root.infoValue;
  if (info == null) {
    throw TorrentMetainfoException(
      TorrentMetainfoErrorCode.missingInfo,
      'root dictionary has no info dictionary',
    );
  }

  final bool hasV1Pieces = info['pieces'] is Uint8List;
  final bool hasV2 = info['meta version'] == 2;
  if (!hasV1Pieces && !hasV2) {
    throw TorrentMetainfoException(
      TorrentMetainfoErrorCode.unsupportedVersion,
      'info dictionary is neither v1 nor v2',
    );
  }

  final Uint8List rawInfo = Uint8List.sublistView(
    bytes,
    root.infoStart,
    root.infoEnd,
  );
  final String? v1InfoHash =
      hasV1Pieces ? crypto.sha1.convert(rawInfo).toString() : null;
  final String? v2InfoHash =
      hasV2 ? crypto.sha256.convert(rawInfo).toString() : null;
  final String torrentId = v1InfoHash ?? v2InfoHash!.substring(0, 40);

  final String? expected = _normalizeExpectedHash(expectedInfoHash);
  if (expected != null &&
      expected != v1InfoHash &&
      expected != v2InfoHash &&
      expected != torrentId) {
    throw TorrentMetainfoException(
      TorrentMetainfoErrorCode.hashMismatch,
      'declared info hash does not match metainfo',
    );
  }

  return InspectedTorrentMetainfo(
    bytes: bytes,
    torrentId: torrentId,
    v1InfoHash: v1InfoHash,
    v2InfoHash: v2InfoHash,
  );
}

String? _normalizeExpectedHash(String? raw) {
  if (raw == null) return null;
  String value = raw.trim().toLowerCase();
  for (final String prefix in <String>['urn:btih:', 'urn:btmh:1220']) {
    if (value.startsWith(prefix)) value = value.substring(prefix.length);
  }
  if (RegExp(r'^[0-9a-f]{40}$').hasMatch(value) ||
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    return value;
  }
  throw TorrentMetainfoException(
    TorrentMetainfoErrorCode.hashMismatch,
    'declared info hash has an unsupported format',
  );
}

class _RootDictionary {
  const _RootDictionary({
    required this.infoValue,
    required this.infoStart,
    required this.infoEnd,
  });

  final Map<String, Object?>? infoValue;
  final int infoStart;
  final int infoEnd;
}

class _BencodeReader {
  _BencodeReader(this.bytes);

  final Uint8List bytes;
  int index = 0;
  int valueCount = 0;

  _RootDictionary readRootDictionary() {
    try {
      if (_take() != 0x64) _invalid('root value must be a dictionary');
      Map<String, Object?>? infoValue;
      int infoStart = -1;
      int infoEnd = -1;
      final Set<String> keys = <String>{};
      while (_peek() != 0x65) {
        final String key = _readKey();
        if (!keys.add(key)) _invalid('duplicate root key');
        final int valueStart = index;
        final Object? value = _readValue(1);
        if (key == 'info') {
          if (value is! Map<String, Object?>) {
            _invalid('info must be a dictionary');
          }
          infoValue = value;
          infoStart = valueStart;
          infoEnd = index;
        }
      }
      index++;
      if (index != bytes.length) _invalid('trailing bytes after root value');
      return _RootDictionary(
        infoValue: infoValue,
        infoStart: infoStart,
        infoEnd: infoEnd,
      );
    } on TorrentMetainfoException {
      rethrow;
    } on Object {
      _invalid('truncated or malformed bencode');
    }
  }

  Object? _readValue(int depth) {
    if (depth > 100) _invalid('maximum nesting depth exceeded');
    valueCount++;
    if (valueCount > 1000000) _invalid('too many bencode values');
    final int marker = _peek();
    if (marker >= 0x30 && marker <= 0x39) return _readBytes();
    if (marker == 0x69) return _readInteger();
    if (marker == 0x6c) return _readList(depth + 1);
    if (marker == 0x64) return _readDictionary(depth + 1);
    _invalid('unknown bencode marker');
  }

  int _readInteger() {
    index++;
    final int start = index;
    while (_peek() != 0x65) {
      final int byte = _take();
      if (byte != 0x2d && (byte < 0x30 || byte > 0x39)) {
        _invalid('invalid integer');
      }
    }
    final String raw = ascii.decode(bytes.sublist(start, index));
    index++;
    if (raw.isEmpty ||
        raw == '-' ||
        raw == '-0' ||
        (raw.startsWith('0') && raw.length > 1) ||
        (raw.startsWith('-0') && raw.length > 2)) {
      _invalid('non-canonical integer');
    }
    final int? value = int.tryParse(raw);
    if (value == null) _invalid('integer is outside supported range');
    return value;
  }

  Uint8List _readBytes() {
    final int lengthStart = index;
    while (_peek() != 0x3a) {
      final int byte = _take();
      if (byte < 0x30 || byte > 0x39) _invalid('invalid byte string length');
    }
    final String rawLength = ascii.decode(bytes.sublist(lengthStart, index));
    index++;
    if (rawLength.isEmpty ||
        (rawLength.startsWith('0') && rawLength.length > 1)) {
      _invalid('non-canonical byte string length');
    }
    final int? length = int.tryParse(rawLength);
    if (length == null || length < 0 || index + length > bytes.length) {
      _invalid('byte string exceeds input');
    }
    final Uint8List value = Uint8List.sublistView(bytes, index, index + length);
    index += length;
    return value;
  }

  List<Object?> _readList(int depth) {
    index++;
    final List<Object?> values = <Object?>[];
    while (_peek() != 0x65) {
      values.add(_readValue(depth));
    }
    index++;
    return values;
  }

  Map<String, Object?> _readDictionary(int depth) {
    index++;
    final Map<String, Object?> values = <String, Object?>{};
    while (_peek() != 0x65) {
      final String key = _readKey();
      if (values.containsKey(key)) _invalid('duplicate dictionary key');
      values[key] = _readValue(depth);
    }
    index++;
    return values;
  }

  String _readKey() => utf8.decode(_readBytes(), allowMalformed: true);

  int _peek() {
    if (index >= bytes.length) _invalid('unexpected end of input');
    return bytes[index];
  }

  int _take() {
    final int value = _peek();
    index++;
    return value;
  }

  Never _invalid(String detail) {
    throw TorrentMetainfoException(
      TorrentMetainfoErrorCode.invalidBencode,
      detail,
    );
  }
}
