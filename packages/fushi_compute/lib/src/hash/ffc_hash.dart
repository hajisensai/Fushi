import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../fushi_compute_library.dart';

typedef _NewC = Pointer<Void> Function();
typedef _NewDart = Pointer<Void> Function();
typedef _UpdateC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _UpdateDart = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _Ed2kFinishC =
    Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Int32>);
typedef _Ed2kFinishDart =
    int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Int32>);
typedef _Sha256FinishC = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _Sha256FinishDart = int Function(Pointer<Void>, Pointer<Uint8>);
typedef _Crc32C = Uint32 Function(Uint32, Pointer<Uint8>, Size);
typedef _Crc32Dart = int Function(int, Pointer<Uint8>, int);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

/// native/fushi_compute/src/hash.rs 的 `ffc_hash_*` 绑定（每个库实例 lookup 一次）。
///
/// lookup 名写成字符串字面量：`native/fushi_compute/verify_abi.sh` 从这里抓期望符号集。
final class _HashBindings {
  _HashBindings._(DynamicLibrary lib)
    : ed2kNew = lib.lookupFunction<_NewC, _NewDart>('ffc_hash_ed2k_new'),
      ed2kUpdate = lib.lookupFunction<_UpdateC, _UpdateDart>(
        'ffc_hash_ed2k_update',
      ),
      ed2kFinish = lib.lookupFunction<_Ed2kFinishC, _Ed2kFinishDart>(
        'ffc_hash_ed2k_finish',
      ),
      ed2kFree = lib.lookupFunction<_FreeC, _FreeDart>('ffc_hash_ed2k_free'),
      sha256New = lib.lookupFunction<_NewC, _NewDart>('ffc_hash_sha256_new'),
      sha256Update = lib.lookupFunction<_UpdateC, _UpdateDart>(
        'ffc_hash_sha256_update',
      ),
      sha256Finish = lib.lookupFunction<_Sha256FinishC, _Sha256FinishDart>(
        'ffc_hash_sha256_finish',
      ),
      sha256Free = lib.lookupFunction<_FreeC, _FreeDart>(
        'ffc_hash_sha256_free',
      ),
      crc32 = lib.lookupFunction<_Crc32C, _Crc32Dart>(
        'ffc_hash_crc32',
        isLeaf: true,
      );

  final _NewDart ed2kNew;
  final _UpdateDart ed2kUpdate;
  final _Ed2kFinishDart ed2kFinish;
  final _FreeDart ed2kFree;
  final _NewDart sha256New;
  final _UpdateDart sha256Update;
  final _Sha256FinishDart sha256Finish;
  final _FreeDart sha256Free;
  final _Crc32Dart crc32;

  static final Expando<_HashBindings> _cache = Expando<_HashBindings>();

  /// 缺哈希域符号（库比绑定旧）抛 [FushiComputeUnavailableError]。
  static _HashBindings of(FushiCompute compute) {
    final _HashBindings? cached = _cache[compute];
    if (cached != null) return cached;
    try {
      return _cache[compute] = _HashBindings._(compute.library);
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('hash', e.message ?? e);
    }
  }
}

/// 原生哈希的公共骨架：上下文 + 原生输入缓冲区。
///
/// 调用方把数据写进 [buffer]（例如 `RandomAccessFile.readInto(hasher.buffer)`），
/// 再 [update] 实际写入的字节数，省掉一次 Dart → 原生的拷贝。用完必须 [close]
/// （放在 `finally` 里）；[close] 幂等。
sealed class FfcStreamingHash {
  FfcStreamingHash._(this._ctx, int bufferSize)
    : _buffer = malloc<Uint8>(bufferSize),
      bufferSize = bufferSize {
    buffer = _buffer.asTypedList(bufferSize);
  }

  Pointer<Void> _ctx;
  final Pointer<Uint8> _buffer;

  /// [buffer] 的长度。
  final int bufferSize;

  /// 原生内存上的输入缓冲区（[close] 之后不可再用）。
  late final Uint8List buffer;

  bool _finished = false;
  bool get _closed => _ctx == nullptr;

  int _update(Pointer<Void> ctx, Pointer<Uint8> data, int length);
  void _free(Pointer<Void> ctx);

  /// 把 [buffer] 前 [length] 字节追加进哈希。
  void update(int length) {
    RangeError.checkValueInInterval(length, 0, bufferSize, 'length');
    _checkUsable();
    _checkStatus(_update(_ctx, _buffer, length));
  }

  /// 追加任意 Dart 字节（经 [buffer] 分段拷贝）；读文件时优先直接 readInto [buffer]。
  void add(List<int> bytes) {
    int offset = 0;
    while (offset < bytes.length) {
      final int n = (bytes.length - offset).clamp(0, bufferSize);
      buffer.setRange(0, n, bytes, offset);
      update(n);
      offset += n;
    }
  }

  void _checkUsable() {
    if (_closed) throw StateError('native hasher already closed');
    if (_finished) throw StateError('native hasher already finalized');
  }

  static void _checkStatus(int status) {
    if (status != FfcStatus.ok) {
      throw StateError('fushi_compute hash call failed: status $status');
    }
  }

  /// 释放上下文与缓冲区；幂等。
  void close() {
    if (_closed) return;
    _free(_ctx);
    _ctx = nullptr;
    malloc.free(_buffer);
  }
}

/// AniDB ED2K（红 / 蓝两种整块边界变体，https://wiki.anidb.net/Ed2k-hash）。
final class FfcEd2kHasher extends FfcStreamingHash {
  FfcEd2kHasher._(this._b, Pointer<Void> ctx, int bufferSize)
    : super._(ctx, bufferSize);

  final _HashBindings _b;

  /// 新建上下文与 [bufferSize] 字节的原生输入缓冲区。库加载失败或缺符号抛
  /// [FushiComputeUnavailableError]。
  static FfcEd2kHasher create({
    int bufferSize = 1 << 20,
    FushiCompute? library,
  }) {
    final FushiCompute compute = library ?? FushiCompute.require();
    final _HashBindings b = _HashBindings.of(compute);
    final Pointer<Void> ctx = b.ed2kNew();
    if (ctx == nullptr) {
      throw StateError('ffc_hash_ed2k_new failed');
    }
    return FfcEd2kHasher._(b, ctx, bufferSize);
  }

  @override
  int _update(Pointer<Void> ctx, Pointer<Uint8> data, int length) =>
      _b.ed2kUpdate(ctx, data, length);

  @override
  void _free(Pointer<Void> ctx) => _b.ed2kFree(ctx);

  /// 结束：返回（红，蓝）十六进制小写；蓝只在长度恰为块大小的非零整数倍时非 null。
  (String, String?) finish() {
    _checkUsable();
    final Pointer<Uint8> out = malloc<Uint8>(32);
    final Pointer<Int32> hasAlternative = malloc<Int32>();
    try {
      FfcStreamingHash._checkStatus(_b.ed2kFinish(_ctx, out, hasAlternative));
      _finished = true;
      final Uint8List bytes = out.asTypedList(32);
      return (
        _hex(bytes, 0, 16),
        hasAlternative.value == 1 ? _hex(bytes, 16, 32) : null,
      );
    } finally {
      malloc.free(out);
      malloc.free(hasAlternative);
    }
  }
}

/// SHA-256。
final class FfcSha256Hasher extends FfcStreamingHash {
  FfcSha256Hasher._(this._b, Pointer<Void> ctx, int bufferSize)
    : super._(ctx, bufferSize);

  final _HashBindings _b;

  /// 新建上下文与 [bufferSize] 字节的原生输入缓冲区。库加载失败或缺符号抛
  /// [FushiComputeUnavailableError]。
  static FfcSha256Hasher create({
    int bufferSize = 1 << 20,
    FushiCompute? library,
  }) {
    final FushiCompute compute = library ?? FushiCompute.require();
    final _HashBindings b = _HashBindings.of(compute);
    final Pointer<Void> ctx = b.sha256New();
    if (ctx == nullptr) {
      throw StateError('ffc_hash_sha256_new failed');
    }
    return FfcSha256Hasher._(b, ctx, bufferSize);
  }

  @override
  int _update(Pointer<Void> ctx, Pointer<Uint8> data, int length) =>
      _b.sha256Update(ctx, data, length);

  @override
  void _free(Pointer<Void> ctx) => _b.sha256Free(ctx);

  /// 结束：返回 64 位十六进制小写摘要（与 `crypto` 的 `Digest.toString()` 同形）。
  String finishHex() {
    _checkUsable();
    final Pointer<Uint8> out = malloc<Uint8>(32);
    try {
      FfcStreamingHash._checkStatus(_b.sha256Finish(_ctx, out));
      _finished = true;
      return _hex(out.asTypedList(32), 0, 32);
    } finally {
      malloc.free(out);
    }
  }
}

/// CRC-32 的分段大小 = 拷贝用暂存区大小（每个 isolate 一块，按需分配一次）。
const int _crcSlice = 1 << 20;
Pointer<Uint8> _crcScratch = nullptr;

/// CRC-32（IEEE，zip 用的那个）：在 [crc]（上一段结果，首段 0）之上续算 [bytes]。
/// 与 `package:archive` 的 `getCrc32(bytes, crc)` 同语义，可分段链式调用。
/// 字节按 1 MiB 一段拷进原生暂存区再算（FFI 不能直接借用 Dart 堆上的数组）。
/// 库不可用抛 [FushiComputeUnavailableError]。
int ffcCrc32(List<int> bytes, [int crc = 0, FushiCompute? library]) {
  final _HashBindings b = _HashBindings.of(library ?? FushiCompute.require());
  if (_crcScratch == nullptr) _crcScratch = malloc<Uint8>(_crcSlice);
  final Uint8List scratch = _crcScratch.asTypedList(_crcSlice);
  int value = crc & 0xffffffff;
  for (int offset = 0; offset < bytes.length; offset += _crcSlice) {
    final int n = min(bytes.length - offset, _crcSlice);
    scratch.setRange(0, n, bytes, offset);
    value = b.crc32(value, _crcScratch, n);
  }
  return value;
}

/// 内存里一段字节的 SHA-256（64 位十六进制小写）。库不可用抛 [FushiComputeUnavailableError]。
String ffcSha256Bytes(List<int> bytes, {FushiCompute? library}) {
  final FfcSha256Hasher hasher = FfcSha256Hasher.create(
    bufferSize: min(max(bytes.length, 1), 1 << 20),
    library: library,
  );
  try {
    hasher.add(bytes);
    return hasher.finishHex();
  } finally {
    hasher.close();
  }
}

/// 整个文件的 SHA-256（64 位十六进制小写），异步读：1 MiB 一块读进原生缓冲区，
/// 每块的哈希只占 1 ms 量级，可以在 UI isolate 上用（与原来 `sha256.bind(openRead())`
/// 同样不长时间阻塞事件循环）。库不可用抛 [FushiComputeUnavailableError]。
Future<String> ffcSha256File(String path, {FushiCompute? library}) async {
  final FfcSha256Hasher hasher = FfcSha256Hasher.create(library: library);
  try {
    final RandomAccessFile input = await File(path).open();
    try {
      while (true) {
        final int count = await input.readInto(hasher.buffer);
        if (count == 0) break;
        hasher.update(count);
      }
    } finally {
      await input.close();
    }
    return hasher.finishHex();
  } finally {
    hasher.close();
  }
}

/// 用原生 SHA-256 哈希整个文件，返回 64 位十六进制小写摘要。
///
/// 同步读：只该在后台 isolate 里调。库不可用抛 [FushiComputeUnavailableError]。
String ffcSha256FileSync(String path, {FushiCompute? library}) {
  final FfcSha256Hasher hasher = FfcSha256Hasher.create(library: library);
  try {
    final RandomAccessFile input = File(path).openSync();
    try {
      while (true) {
        final int count = input.readIntoSync(hasher.buffer);
        if (count == 0) break;
        hasher.update(count);
      }
    } finally {
      input.closeSync();
    }
    return hasher.finishHex();
  } finally {
    hasher.close();
  }
}

String _hex(Uint8List bytes, int start, int end) {
  const String digits = '0123456789abcdef';
  final StringBuffer out = StringBuffer();
  for (int i = start; i < end; i++) {
    out
      ..write(digits[bytes[i] >> 4])
      ..write(digits[bytes[i] & 15]);
  }
  return out.toString();
}
