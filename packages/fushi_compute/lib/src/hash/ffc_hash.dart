import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

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
typedef _BatchC =
    Int32 Function(Pointer<Uint8>, Pointer<Uint64>, Size, Pointer<Uint64>);
typedef _BatchDart =
    int Function(Pointer<Uint8>, Pointer<Uint64>, int, Pointer<Uint64>);
typedef _UuidBatchC =
    Int32 Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint64>,
      Size,
      Pointer<Uint8>,
    );
typedef _UuidBatchDart =
    int Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint64>,
      int,
      Pointer<Uint8>,
    );
typedef _PowSolveC =
    Int32 Function(Pointer<Uint8>, Size, Uint32, Pointer<Uint64>);
typedef _PowSolveDart = int Function(Pointer<Uint8>, int, int, Pointer<Uint64>);
typedef _PowCheckC =
    Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>, Size, Uint32);
typedef _PowCheckDart =
    int Function(Pointer<Uint8>, int, Pointer<Uint8>, int, int);
typedef _EqualC = Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>, Size);
typedef _EqualDart = int Function(Pointer<Uint8>, int, Pointer<Uint8>, int);
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
      ),
      uuidV5Batch = lib.lookupFunction<_UuidBatchC, _UuidBatchDart>(
        'ffc_hash_uuid_v5_batch',
        isLeaf: true,
      ),
      hash53Batch = lib.lookupFunction<_BatchC, _BatchDart>(
        'ffc_hash_hash53_batch',
        isLeaf: true,
      ),
      // 求解要跑约 2^bits 次 SHA-256，不设叶子调用以免长时间挡住 GC。
      powSolve = lib.lookupFunction<_PowSolveC, _PowSolveDart>(
        'ffc_hash_pow_solve',
      ),
      powCheck = lib.lookupFunction<_PowCheckC, _PowCheckDart>(
        'ffc_hash_pow_check',
        isLeaf: true,
      ),
      bytesEqual = lib.lookupFunction<_EqualC, _EqualDart>(
        'ffc_hash_bytes_equal',
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
  final _UuidBatchDart uuidV5Batch;
  final _BatchDart hash53Batch;
  final _PowSolveDart powSolve;
  final _PowCheckDart powCheck;
  final _EqualDart bytesEqual;

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
/// （放在 `finally` 里）；[close] 幂等。输入缓冲区由 [NativeScratch] 持有：忘了 [close]
/// 也会随对象回收 / isolate 退出释放（上下文仍要 [close]）。
sealed class FfcStreamingHash implements Finalizable {
  FfcStreamingHash._(this._ctx, int bufferSize)
    : _bufferOwner = NativeScratch.fixed(bufferSize),
      bufferSize = bufferSize {
    buffer = _bufferOwner.pointer.asTypedListOutOfLine(bufferSize);
  }

  Pointer<Void> _ctx;
  final NativeScratch _bufferOwner;

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
    _checkStatus(_update(_ctx, _bufferOwner.pointer, length));
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
    _bufferOwner.release();
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
      final Uint8List bytes = out.asTypedListOutOfLine(32);
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
      return _hex(out.asTypedListOutOfLine(32), 0, 32);
    } finally {
      malloc.free(out);
    }
  }
}

/// CRC-32 的分段大小 = 拷贝用暂存区大小（每个 isolate 一块，首次使用时分配，isolate
/// 退出时经 [NativeScratch] 的 finalizer 释放）。
const int _crcSlice = 1 << 20;
final NativeScratch _crcScratch = NativeScratch.fixed(_crcSlice);

/// CRC-32（IEEE，zip 用的那个）：在 [crc]（上一段结果，首段 0）之上续算 [bytes]。
/// 与 `package:archive` 的 `getCrc32(bytes, crc)` 同语义，可分段链式调用。
/// 字节按 1 MiB 一段拷进原生暂存区再算（FFI 不能直接借用 Dart 堆上的数组）。
/// 库不可用抛 [FushiComputeUnavailableError]。
int ffcCrc32(List<int> bytes, [int crc = 0, FushiCompute? library]) {
  final _HashBindings b = _HashBindings.of(library ?? FushiCompute.require());
  final Pointer<Uint8> ptr = _crcScratch.pointer;
  final Uint8List scratch = ptr.asTypedListOutOfLine(_crcSlice);
  int value = crc & 0xffffffff;
  for (int offset = 0; offset < bytes.length; offset += _crcSlice) {
    final int n = min(bytes.length - offset, _crcSlice);
    scratch.setRange(0, n, bytes, offset);
    value = b.crc32(value, ptr, n);
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

/// 把若干字节串打包成「连续数据 + n+1 个偏移」放进原生内存，跑 [body]，然后释放。
T _withPacked<T>(
  List<List<int>> items,
  T Function(Pointer<Uint8> data, Pointer<Uint64> offsets) body,
) {
  int total = 0;
  for (final List<int> item in items) {
    total += item.length;
  }
  final Pointer<Uint8> data = malloc<Uint8>(max(total, 1));
  final Pointer<Uint64> offsets = malloc<Uint64>(items.length + 1);
  try {
    final Uint8List dataView = data.asTypedListOutOfLine(max(total, 1));
    final Uint64List offsetView = offsets.asTypedListOutOfLine(
      items.length + 1,
    );
    int at = 0;
    for (int i = 0; i < items.length; i++) {
      offsetView[i] = at;
      dataView.setRange(at, at + items[i].length, items[i]);
      at += items[i].length;
    }
    offsetView[items.length] = at;
    return body(data, offsets);
  } finally {
    malloc.free(data);
    malloc.free(offsets);
  }
}

/// 批量 RFC 9562 UUIDv5（SHA-1）：第 i 个以 `namespaces[16i..16i+16]` 为命名空间、
/// [names] 第 i 项（UTF-8 字节）为名字，返回 16n 字节（已置版本 / 变体位）。
/// 一次 FFI 调用算完整批；单个也走这里（n = 1）。库不可用抛 [FushiComputeUnavailableError]。
Uint8List ffcUuidV5Batch(
  Uint8List namespaces,
  List<List<int>> names, {
  FushiCompute? library,
}) {
  if (namespaces.length != 16 * names.length) {
    throw ArgumentError.value(
      namespaces.length,
      'namespaces',
      'must be 16 bytes per name (${names.length} names)',
    );
  }
  if (names.isEmpty) return Uint8List(0);
  final _HashBindings b = _HashBindings.of(library ?? FushiCompute.require());
  final Pointer<Uint8> ns = malloc<Uint8>(namespaces.length);
  final Pointer<Uint8> out = malloc<Uint8>(namespaces.length);
  try {
    ns.asTypedListOutOfLine(namespaces.length).setAll(0, namespaces);
    _withPacked<void>(names, (Pointer<Uint8> data, Pointer<Uint64> offsets) {
      FfcStreamingHash._checkStatus(
        b.uuidV5Batch(ns, data, offsets, names.length, out),
      );
    });
    return Uint8List.fromList(out.asTypedListOutOfLine(namespaces.length));
  } finally {
    malloc.free(ns);
    malloc.free(out);
  }
}

/// 工作量证明求解：最小的 nonce 使 SHA-256([prefix] ‖ 十进制 nonce) 至少有 [bits] 个前导零位。
/// 一次 FFI 调用解完（CPU 密集，调用方放后台 isolate）。[bits] 不超过 64。
int ffcPowSolve(List<int> prefix, int bits, {FushiCompute? library}) {
  final _HashBindings b = _HashBindings.of(library ?? FushiCompute.require());
  final Pointer<Uint8> p = malloc<Uint8>(max(prefix.length, 1));
  final Pointer<Uint64> nonce = malloc<Uint64>();
  try {
    p.asTypedListOutOfLine(max(prefix.length, 1)).setAll(0, prefix);
    FfcStreamingHash._checkStatus(b.powSolve(p, prefix.length, bits, nonce));
    return nonce.value;
  } finally {
    malloc.free(p);
    malloc.free(nonce);
  }
}

/// 工作量证明校验：SHA-256([prefix] ‖ [nonce]) 是否至少有 [bits] 个前导零位。
bool ffcPowCheck(
  List<int> prefix,
  List<int> nonce,
  int bits, {
  FushiCompute? library,
}) {
  final _HashBindings b = _HashBindings.of(library ?? FushiCompute.require());
  return _withPacked<bool>(<List<int>>[prefix, nonce], (
    Pointer<Uint8> data,
    Pointer<Uint64> offsets,
  ) {
    final int status = b.powCheck(
      data,
      prefix.length,
      data + prefix.length,
      nonce.length,
      bits,
    );
    if (status < 0) FfcStreamingHash._checkStatus(status);
    return status == 1;
  });
}

const int _equalSlice = 1 << 20;
final NativeScratch _equalScratch = NativeScratch.fixed(2 * _equalSlice);

/// 两段字节是否完全相同（长度不同即不同）。按 1 MiB 一段拷进原生暂存区比较。
bool ffcBytesEqual(List<int> a, List<int> b, {FushiCompute? library}) {
  final _HashBindings bind = _HashBindings.of(
    library ?? FushiCompute.require(),
  );
  if (a.length != b.length) return false;
  final Pointer<Uint8> left = _equalScratch.pointer;
  final Pointer<Uint8> right = left + _equalSlice;
  final Uint8List leftView = left.asTypedListOutOfLine(_equalSlice);
  final Uint8List rightView = right.asTypedListOutOfLine(_equalSlice);
  for (int offset = 0; offset < a.length; offset += _equalSlice) {
    final int n = min(a.length - offset, _equalSlice);
    leftView.setRange(0, n, a, offset);
    rightView.setRange(0, n, b, offset);
    final int status = bind.bytesEqual(left, n, right, n);
    if (status < 0) FfcStreamingHash._checkStatus(status);
    if (status == 0) return false;
  }
  return true;
}

/// 单个 UUIDv5 / hash53 的暂存区：一次调用不做任何 malloc（单个调用点很多，FFI 之外的
/// 分配会比哈希本身还贵）。每个 isolate 一份，按需增长；isolate 退出时经 [NativeScratch]
/// 的 finalizer 释放。
final NativeScratch _singleScratch = NativeScratch(minCapacity: 256);

/// 固定槽：offsets（2 × u64）、namespace + 输出（32 B）、hash53 输出（1 × u64）。
final NativeScratch _singleSlots = NativeScratch.fixed(16 + 32 + 8);
final Pointer<Uint64> _singleOffsets = _singleSlots.pointer.cast<Uint64>();
final Pointer<Uint8> _singleNamespace = _singleSlots.pointer + 16;
final Pointer<Uint64> _singleOut = (_singleSlots.pointer + 48).cast<Uint64>();

Pointer<Uint8> _singleInput(List<int> bytes) {
  final Pointer<Uint8> data = _singleScratch.reserve(bytes.length);
  data.asTypedListOutOfLine(bytes.length).setRange(0, bytes.length, bytes);
  _singleOffsets[0] = 0;
  _singleOffsets[1] = bytes.length;
  return data;
}

/// 单个 UUIDv5：[namespace] 16 字节、[name] 为 UTF-8 字节，返回 16 字节（已置版本 / 变体位）。
/// 与 [ffcUuidV5Batch] 同一个 Rust 函数（n = 1），只是不分配。
Uint8List ffcUuidV5(
  Uint8List namespace,
  List<int> name, {
  FushiCompute? library,
}) {
  if (namespace.length != 16) {
    throw ArgumentError.value(
      namespace.length,
      'namespace',
      'must be 16 bytes',
    );
  }
  final _HashBindings b = _HashBindings.of(library ?? FushiCompute.require());
  final Pointer<Uint8> data = _singleInput(name);
  final Uint8List ns = _singleNamespace.asTypedListOutOfLine(32);
  ns.setRange(0, 16, namespace);
  FfcStreamingHash._checkStatus(
    b.uuidV5Batch(
      _singleNamespace,
      data,
      _singleOffsets,
      1,
      _singleNamespace + 16,
    ),
  );
  return Uint8List.fromList(Uint8List.sublistView(ns, 16, 32));
}

/// 53 位确定性正整数（SHA-256 前 7 字节大端取低 53 位，0 记作 1）：`ffc_hash_hash53_batch`
/// 的 n = 1，不分配。库不可用抛 [FushiComputeUnavailableError]。
int ffcHash53(List<int> bytes, {FushiCompute? library}) {
  final _HashBindings b = _HashBindings.of(library ?? FushiCompute.require());
  final Pointer<Uint8> data = _singleInput(bytes);
  FfcStreamingHash._checkStatus(
    b.hash53Batch(data, _singleOffsets, 1, _singleOut),
  );
  return _singleOut.value;
}

/// 批量 [ffcHash53]：第 i 项 = `UTF-8([prefix]) ‖ UTF-8(inputs[i])` 的 hash53，结果按顺序对应
/// （与逐个 `ffcHash53(utf8.encode(prefix + inputs[i]))` 逐值相同）。整批一次
/// `ffc_hash_hash53_batch`，循环在 Rust 侧。
///
/// 字符串直接编码进一块原生内存（「连续数据 + n+1 个偏移」），不先攒一整批 Dart 字节数组：
/// 纯 ASCII 的项（UUID 一类的 id 是绝大多数）逐码元写入，其余项才走 `utf8.encode`（孤立代理
/// 与 `utf8.encode` 同样写成 U+FFFD）。[prefix] 必须是 ASCII——这样前缀与各项分别编码再拼接
/// 才恒等于整串编码（`SrsIds.ankiNumericIds` 的 `anki-id/` 不必为每个 id 拼一次字符串）。
/// 原生内存只活在本次调用内（try/finally 释放）。库不可用抛 [FushiComputeUnavailableError]。
Uint64List ffcHash53Batch(
  List<String> inputs, {
  String prefix = '',
  FushiCompute? library,
}) {
  for (int i = 0; i < prefix.length; i++) {
    if (prefix.codeUnitAt(i) >= 0x80) {
      throw ArgumentError.value(prefix, 'prefix', 'must be ASCII');
    }
  }
  final int n = inputs.length;
  if (n == 0) return Uint64List(0);
  final _HashBindings b = _HashBindings.of(library ?? FushiCompute.require());
  // 第一遍：总字节数；非 ASCII 项编码一次留着第二遍用（ASCII 项字节数 = 码元数）。
  final List<Uint8List?> encoded = List<Uint8List?>.filled(n, null);
  int total = prefix.length * n;
  for (int i = 0; i < n; i++) {
    final String s = inputs[i];
    bool ascii = true;
    for (int k = 0; k < s.length; k++) {
      if (s.codeUnitAt(k) >= 0x80) {
        ascii = false;
        break;
      }
    }
    if (ascii) {
      total += s.length;
    } else {
      final Uint8List bytes = utf8.encode(s);
      encoded[i] = bytes;
      total += bytes.length;
    }
  }
  final Pointer<Uint8> data = malloc<Uint8>(max(total, 1));
  final Pointer<Uint64> offsets = malloc<Uint64>(n + 1);
  final Pointer<Uint64> out = malloc<Uint64>(n);
  try {
    final Uint8List dataView = data.asTypedListOutOfLine(max(total, 1));
    final Uint64List offsetView = offsets.asTypedListOutOfLine(n + 1);
    int at = 0;
    for (int i = 0; i < n; i++) {
      offsetView[i] = at;
      for (int k = 0; k < prefix.length; k++) {
        dataView[at++] = prefix.codeUnitAt(k);
      }
      final Uint8List? bytes = encoded[i];
      if (bytes != null) {
        dataView.setRange(at, at + bytes.length, bytes);
        at += bytes.length;
      } else {
        final String s = inputs[i];
        for (int k = 0; k < s.length; k++) {
          dataView[at++] = s.codeUnitAt(k);
        }
      }
    }
    offsetView[n] = at;
    FfcStreamingHash._checkStatus(b.hash53Batch(data, offsets, n, out));
    return Uint64List.fromList(out.asTypedListOutOfLine(n));
  } finally {
    malloc.free(data);
    malloc.free(offsets);
    malloc.free(out);
  }
}
