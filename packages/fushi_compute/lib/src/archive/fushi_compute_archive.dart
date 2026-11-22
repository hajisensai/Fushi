import 'dart:convert';
import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../hash/ffc_hash.dart' show FfcCancelFlag;

typedef _ProbeC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Uint64>,
      Pointer<Uint64>,
      Pointer<Uint8>,
    );
typedef _ProbeDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Uint64>,
      Pointer<Uint64>,
      Pointer<Uint8>,
    );
typedef _ExtractC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Uint64,
      Uint64,
      Pointer<Uint32>,
      Pointer<Uint64>,
      Pointer<Uint64>,
    );
typedef _ExtractDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      int,
      int,
      Pointer<Uint32>,
      Pointer<Uint64>,
      Pointer<Uint64>,
    );

/// native/fushi_compute/src/archive.rs 的 `ffc_archive_*` 绑定。
///
/// lookup 名写成字符串字面量：`native/fushi_compute/verify_abi.sh` 从这里抓期望符号集。
final class _ArchiveBindings {
  _ArchiveBindings._(DynamicLibrary lib)
    : probe = lib.lookupFunction<_ProbeC, _ProbeDart>('ffc_archive_probe'),
      extract = lib.lookupFunction<_ExtractC, _ExtractDart>(
        'ffc_archive_extract',
      );

  final _ProbeDart probe;
  final _ExtractDart extract;

  static final Expando<_ArchiveBindings> _cache = Expando<_ArchiveBindings>();

  static _ArchiveBindings of(FushiCompute compute) {
    final _ArchiveBindings? cached = _cache[compute];
    if (cached != null) return cached;
    try {
      return _cache[compute] = _ArchiveBindings._(compute.library);
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('archive', e.message ?? e);
    }
  }
}

/// 归档容器格式（与 archive.rs 的 `format` 同值）。
enum FfcArchiveFormat {
  unknown,
  zip,
  sevenZip,

  /// 只认出来、不在原生库里解（见 archive.rs 模块文档）。
  rar,
}

/// 归档加密情况（与 archive.rs 的 `encryption` 同值）。
enum FfcArchiveEncryption {
  none,

  /// 条目内容加密，条目表可读。
  entries,

  /// 条目表本身加密（7z `-mhe=on`）：不给口令连条目数都不知道。
  headers;

  bool get isEncrypted => this != none;
}

/// [ffcArchiveProbeSync] 的结果。
final class FfcArchiveInfo {
  const FfcArchiveInfo({
    required this.format,
    required this.encryption,
    required this.entryCount,
    required this.unpackedSize,
    required this.fingerprint,
  });

  final FfcArchiveFormat format;
  final FfcArchiveEncryption encryption;

  /// 文件条目数（不含目录；条目表加密时为 0）。
  final int entryCount;

  /// 条目表声明的解出总字节数（只作预检，可谎报）。
  final int unpackedSize;

  /// 归档指纹（64 位十六进制小写）：文件长度 + 头尾各 1 MiB 的 SHA-256，记住的口令按它找。
  final String fingerprint;
}

/// 解包失败的原因。
enum FfcArchiveFailure {
  /// 包加密了、没给口令。
  passwordRequired,

  /// 口令不对（或加密数据损坏，两者分不开）。
  wrongPassword,

  /// 条目路径不安全（zip-slip 等），整包拒绝。
  unsafeEntry,

  /// 解出的总字节数 / 文件数超过上限。
  tooLarge,

  /// 格式或压缩方法不支持（RAR、未编进的算法）。
  unsupported,

  /// 包坏了。
  corrupt,

  /// 读写失败。
  io,

  /// 经 [FfcCancelFlag] 取消。
  cancelled,

  /// 分卷包（`book.7z.001`…）拼不全：给的不是第一卷，或后面缺卷。
  missingVolume,
}

/// [ffcArchiveExtractSync] / [ffcArchiveProbeSync] 的业务失败。
final class FfcArchiveException implements Exception {
  const FfcArchiveException(this.failure, this.path, this.status);

  final FfcArchiveFailure failure;
  final String path;

  /// 原生返回码（排查用）。
  final int status;

  @override
  String toString() => 'FfcArchiveException: ${failure.name} ($status) $path';
}

/// [ffcArchiveExtractSync] 的统计。
final class FfcArchiveExtractStats {
  const FfcArchiveExtractStats({required this.files, required this.bytes});

  final int files;
  final int bytes;
}

FfcArchiveFailure? _failureOf(int status) => switch (status) {
  FfcStatus.ok => null,
  -20 => FfcArchiveFailure.passwordRequired,
  -21 => FfcArchiveFailure.wrongPassword,
  -22 => FfcArchiveFailure.unsafeEntry,
  -23 => FfcArchiveFailure.tooLarge,
  -24 => FfcArchiveFailure.unsupported,
  -25 => FfcArchiveFailure.missingVolume,
  FfcStatus.badInput => FfcArchiveFailure.corrupt,
  FfcStatus.ioError => FfcArchiveFailure.io,
  FfcStatus.cancelled => FfcArchiveFailure.cancelled,
  _ => throw StateError('ffc_archive_* returned $status'),
};

Pointer<Uint8> _utf8(Arena arena, String value, void Function(int) len) {
  final Uint8List bytes = utf8.encode(value);
  final Pointer<Uint8> ptr = arena<Uint8>(max(bytes.length, 1));
  ptr.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
  len(bytes.length);
  return ptr;
}

/// 探测归档（同步、读头尾各 1 MiB + 条目表；只该在后台 isolate 里调）。
///
/// RAR / 不认识的格式不抛，[FfcArchiveInfo.format] 说明；读不了 / 条目表坏抛
/// [FfcArchiveException]；库不可用抛 [FushiComputeUnavailableError]。
FfcArchiveInfo ffcArchiveProbeSync(String path, {FushiCompute? library}) {
  final _ArchiveBindings b = _ArchiveBindings.of(
    library ?? FushiCompute.require(),
  );
  return using((Arena arena) {
    int pathLen = 0;
    final Pointer<Uint8> p = _utf8(arena, path, (int n) => pathLen = n);
    final Pointer<Int32> format = arena<Int32>();
    final Pointer<Int32> encryption = arena<Int32>();
    final Pointer<Uint64> count = arena<Uint64>();
    final Pointer<Uint64> size = arena<Uint64>();
    final Pointer<Uint8> fp = arena<Uint8>(32);
    final int status = b.probe(p, pathLen, format, encryption, count, size, fp);
    final FfcArchiveFailure? failure = _failureOf(status);
    if (failure != null) throw FfcArchiveException(failure, path, status);
    final Uint8List digest = fp.asTypedListOutOfLine(32);
    return FfcArchiveInfo(
      format: FfcArchiveFormat.values[format.value],
      encryption: FfcArchiveEncryption.values[encryption.value],
      entryCount: count.value,
      unpackedSize: size.value,
      fingerprint: <String>[
        for (final int byte in digest) byte.toRadixString(16).padLeft(2, '0'),
      ].join(),
    );
  });
}

/// 把 zip / 7z [archivePath] 解进 [destDir]（同步；解压在原生库里一次做完，只该在后台
/// isolate 里调）。
///
/// [password] 为 null / 空 = 不给口令；[includeExtensions]（小写带点）非空时只解这些扩展名；
/// [maxTotalBytes] / [maxEntries] 按实际写出量强制，0 = 不限。失败抛 [FfcArchiveException]，
/// 已写出的文件不回滚（调用方给的应是自己建、失败就删的暂存目录）。
FfcArchiveExtractStats ffcArchiveExtractSync(
  String archivePath,
  String destDir, {
  String? password,
  Set<String> includeExtensions = const <String>{},
  int maxTotalBytes = 0,
  int maxEntries = 0,
  FfcCancelFlag? cancel,
  FushiCompute? library,
}) {
  final _ArchiveBindings b = _ArchiveBindings.of(
    library ?? FushiCompute.require(),
  );
  return using((Arena arena) {
    int pathLen = 0, destLen = 0, pwLen = 0, includeLen = 0;
    final Pointer<Uint8> p = _utf8(arena, archivePath, (int n) => pathLen = n);
    final Pointer<Uint8> d = _utf8(arena, destDir, (int n) => destLen = n);
    final Pointer<Uint8> pw = _utf8(
      arena,
      password ?? '',
      (int n) => pwLen = n,
    );
    final Pointer<Uint8> inc = _utf8(
      arena,
      includeExtensions.map((String e) => e.toLowerCase()).join('\n'),
      (int n) => includeLen = n,
    );
    final Pointer<Uint64> files = arena<Uint64>();
    final Pointer<Uint64> bytes = arena<Uint64>();
    final int status = b.extract(
      p,
      pathLen,
      d,
      destLen,
      pw,
      pwLen,
      inc,
      includeLen,
      maxTotalBytes,
      maxEntries,
      cancel == null ? nullptr : Pointer<Uint32>.fromAddress(cancel.address),
      files,
      bytes,
    );
    final FfcArchiveFailure? failure = _failureOf(status);
    if (failure != null)
      throw FfcArchiveException(failure, archivePath, status);
    return FfcArchiveExtractStats(files: files.value, bytes: bytes.value);
  });
}
