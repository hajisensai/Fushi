import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';

typedef _InspectC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _InspectDart =
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);

/// 输出布局常量（与 `native/fushi_compute/src/parse/bencode.rs` 一致）。
const int _headerBytes = 80;
const int _fileRecordBytes = 16;

/// [ffcInspectTorrentMetainfo] 的文件条目：路径已按 Dart `utf8.decode(allowMalformed: true)`
/// 解码并用 `/` 连接。
final class FfcTorrentFile {
  const FfcTorrentFile(this.path, this.length);

  final String path;
  final int length;
}

/// 一份 .torrent 的 bencode 检查结果（原生 `ffc_parse_bencode_inspect_torrent`）。
///
/// [errorCode] 非 null = 致命错误（值是 `TorrentMetainfoErrorCode` 的下标，消息在
/// [errorDetail]），其余字段无意义。否则 [v1InfoHash] / [v2InfoHash] 至少一个非 null；
/// [filesError] 非 null 表示文件清单不合法（错误码 invalidBencode，由调用方在 hash 比对之后
/// 抛出，保持旧实现的报错先后），此时 [files] 为空。
final class FfcTorrentInspection {
  const FfcTorrentInspection._({
    this.errorCode,
    this.errorDetail,
    this.v1InfoHash,
    this.v2InfoHash,
    this.name,
    this.filesError,
    this.files = const <FfcTorrentFile>[],
  });

  final int? errorCode;
  final String? errorDetail;

  /// info 字典原始字节的 SHA-1（20 字节；有 `pieces` 字节串时）。
  final Uint8List? v1InfoHash;

  /// info 字典原始字节的 SHA-256（32 字节；`meta version == 2` 时）。
  final Uint8List? v2InfoHash;

  /// `info.name.utf-8 ?? info.name` 是非空字节串时的解码结果（未 trim）。
  final String? name;
  final String? filesError;
  final List<FfcTorrentFile> files;
}

final class _BencodeBindings {
  _BencodeBindings._(DynamicLibrary lib)
    : inspect = lib.lookupFunction<_InspectC, _InspectDart>(
        'ffc_parse_bencode_inspect_torrent',
      );

  final _InspectDart inspect;

  static final Expando<_BencodeBindings> _cache = Expando<_BencodeBindings>();

  static _BencodeBindings of(FushiCompute compute) {
    final _BencodeBindings? cached = _cache[compute];
    if (cached != null) return cached;
    try {
      return _cache[compute] = _BencodeBindings._(compute.library);
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }
}

/// 严格校验一份 .torrent 的 bencode，算 info hash，读出 name 与文件清单。
///
/// 这是该解析**唯一**的实现（`native/fushi_compute/src/parse/bencode.rs`），没有 Dart 回退；
/// 库不可用抛 [FushiComputeUnavailableError]。[bytes] 必须非空（空 / 超大的入口检查是调用方
/// 的事，见 `inspectTorrentMetainfo`）。
FfcTorrentInspection ffcInspectTorrentMetainfo(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw ArgumentError.value(bytes, 'bytes', 'must not be empty');
  }
  final FushiCompute compute = FushiCompute.require();
  final _BencodeBindings bindings = _BencodeBindings.of(compute);
  final Pointer<Uint8> input = malloc<Uint8>(bytes.length);
  final Pointer<Pointer<Uint8>> outPtr = calloc<Pointer<Uint8>>();
  final Pointer<Size> outLen = calloc<Size>();
  try {
    input.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
    final int status = bindings.inspect(input, bytes.length, outPtr, outLen);
    if (status != FfcStatus.ok) {
      throw StateError(
        'ffc_parse_bencode_inspect_torrent failed with status $status',
      );
    }
    final Pointer<Uint8> out = outPtr.value;
    final int length = outLen.value;
    try {
      return _decode(out, length);
    } finally {
      compute.freeBytes(out, length);
    }
  } finally {
    malloc.free(input);
    calloc.free(outPtr);
    calloc.free(outLen);
  }
}

FfcTorrentInspection _decode(Pointer<Uint8> out, int length) {
  final Uint8List raw = out.asTypedListOutOfLine(length);
  final ByteData header = ByteData.sublistView(raw, 0, _headerBytes);
  int word(int at) => header.getUint32(at, Endian.little);
  final int outcome = word(0);
  final int fileCount = outcome == 0 ? word(60) : 0;
  final int poolStart = _headerBytes + fileCount * _fileRecordBytes;
  final Uint16List pool = _pool(out, raw, poolStart);
  String text(int at) {
    final int start = word(at);
    return String.fromCharCodes(pool, start, start + word(at + 4));
  }

  if (outcome != 0) {
    return FfcTorrentInspection._(errorCode: word(4), errorDetail: text(64));
  }
  final int flags = word(4);
  final List<FfcTorrentFile> files = List<FfcTorrentFile>.generate(fileCount, (
    int i,
  ) {
    final int at = _headerBytes + i * _fileRecordBytes;
    final ByteData record = ByteData.sublistView(
      raw,
      at,
      at + _fileRecordBytes,
    );
    final int start = record.getUint32(8, Endian.little);
    return FfcTorrentFile(
      String.fromCharCodes(
        pool,
        start,
        start + record.getUint32(12, Endian.little),
      ),
      record.getInt64(0, Endian.little),
    );
  }, growable: false);
  return FfcTorrentInspection._(
    v1InfoHash: flags & 1 != 0 ? Uint8List.fromList(raw.sublist(8, 28)) : null,
    v2InfoHash: flags & 2 != 0 ? Uint8List.fromList(raw.sublist(28, 60)) : null,
    name: flags & 4 != 0 ? text(72) : null,
    filesError: flags & 8 != 0 ? text(64) : null,
    files: files,
  );
}

/// 结果尾部的 UTF-16 池。原生分配一般是 8 字节对齐的，可直接映射；万一落在奇地址就拷一份。
Uint16List _pool(Pointer<Uint8> out, Uint8List raw, int start) {
  final int units = (raw.length - start) ~/ 2;
  if (units == 0) return Uint16List(0);
  if ((out.address + start) % 2 == 0) {
    return Pointer<Uint16>.fromAddress(
      out.address + start,
    ).asTypedListOutOfLine(units);
  }
  return Uint8List.fromList(
    raw.sublist(start, start + units * 2),
  ).buffer.asUint16List();
}
