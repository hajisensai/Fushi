import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';

import 'package:fushi_engine/media/torrent/torrent_backend.dart';

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
    Iterable<InspectedTorrentFile> files = const <InspectedTorrentFile>[],
    this.suggestedName,
  }) : bytes = Uint8List.fromList(bytes),
       files = List<InspectedTorrentFile>.unmodifiable(files);

  final Uint8List bytes;

  /// 40-character id used by the existing native/qB backends. Pure v2
  /// torrents use the first 20 bytes of the SHA-256 info hash.
  final String torrentId;
  final String? v1InfoHash;
  final String? v2InfoHash;

  /// 种子内文件清单；[InspectedTorrentFile.index] 与下载后端的文件 index 同域。
  /// 这份清单在 add 副作用之前即可用于持久化“只下载哪些文件”的用户意图。
  final List<InspectedTorrentFile> files;

  /// `info.name`（优先 `name.utf-8`）的展示名；缺失/非文本返回 null。
  /// 手动添加任务用它预填标题。
  final String? suggestedName;

  TorrentMetainfoPayload toPayload({required String fileName}) =>
      TorrentMetainfoPayload(
        bytes: bytes,
        fileName: fileName,
        torrentId: torrentId,
        v1InfoHash: v1InfoHash,
        v2InfoHash: v2InfoHash,
      );
}

class InspectedTorrentFile {
  const InspectedTorrentFile({
    required this.index,
    required this.path,
    required this.length,
  });

  final int index;
  final String path;
  final int length;
}

/// Validates bencode and hashes the exact raw `info` dictionary byte range.
///
/// bencode 校验、info hash（SHA-1 / SHA-256）与文件清单解析只有一份实现：原生
/// `ffc_parse_bencode_inspect_torrent`（native/fushi_compute/src/parse/bencode.rs，错误消息与
/// 判定顺序见该模块注释），没有 Dart 回退；原生库不可用抛 `FushiComputeUnavailableError`。
/// 这里只做与 bencode 无关的入口检查、`expectedInfoHash` 比对与展示名 trim。
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

  final FfcTorrentInspection inspection = ffcInspectTorrentMetainfo(bytes);
  final int? errorCode = inspection.errorCode;
  if (errorCode != null) {
    throw TorrentMetainfoException(
      TorrentMetainfoErrorCode.values[errorCode],
      inspection.errorDetail!,
    );
  }

  final String? v1InfoHash = _hex(inspection.v1InfoHash);
  final String? v2InfoHash = _hex(inspection.v2InfoHash);
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

  String? suggestedName;
  final String? rawName = inspection.name;
  if (rawName != null) {
    final String decoded = rawName.trim();
    if (decoded.isNotEmpty) suggestedName = decoded;
  }

  final String? filesError = inspection.filesError;
  if (filesError != null) {
    throw TorrentMetainfoException(
      TorrentMetainfoErrorCode.invalidBencode,
      filesError,
    );
  }

  return InspectedTorrentMetainfo(
    bytes: bytes,
    torrentId: torrentId,
    v1InfoHash: v1InfoHash,
    v2InfoHash: v2InfoHash,
    files: <InspectedTorrentFile>[
      for (int index = 0; index < inspection.files.length; index++)
        InspectedTorrentFile(
          index: index,
          path: inspection.files[index].path,
          length: inspection.files[index].length,
        ),
    ],
    suggestedName: suggestedName,
  );
}

const String _hexDigits = '0123456789abcdef';

String? _hex(Uint8List? digest) {
  if (digest == null) return null;
  final StringBuffer out = StringBuffer();
  for (final int byte in digest) {
    out
      ..write(_hexDigits[byte >> 4])
      ..write(_hexDigits[byte & 0x0f]);
  }
  return out.toString();
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
