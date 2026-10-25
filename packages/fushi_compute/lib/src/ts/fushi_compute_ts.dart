import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

typedef _NewC = Pointer<Void> Function();
typedef _NewDart = Pointer<Void> Function();
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _NeedC = Uint64 Function(Pointer<Void>);
typedef _NeedDart = int Function(Pointer<Void>);
typedef _BoundC = Size Function(Pointer<Void>, Size);
typedef _BoundDart = int Function(Pointer<Void>, int);
typedef _FeedC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Size,
      Uint64,
      Int32,
      Pointer<Uint8>,
      Size,
      Pointer<Size>,
    );
typedef _FeedDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      int,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Size>,
    );

/// 解出的一个 PES：90 kHz 显示时间戳（已折回 33 位环绕）+ payload。
typedef FfcTsPacket = ({int pts90k, Uint8List data});

/// native/fushi_compute TS 字幕解复用域（`ffc_ts_*`）的绑定。
class FushiComputeTs {
  FushiComputeTs._(FushiCompute lib)
    : _new = lib.library.lookupFunction<_NewC, _NewDart>('ffc_ts_demux_new'),
      _free = lib.library.lookupFunction<_FreeC, _FreeDart>(
        'ffc_ts_demux_free',
      ),
      _freePtr = lib.library.lookup<NativeFunction<_FreeC>>(
        'ffc_ts_demux_free',
      ),
      _need = lib.library.lookupFunction<_NeedC, _NeedDart>(
        'ffc_ts_demux_need_offset',
      ),
      _bound = lib.library.lookupFunction<_BoundC, _BoundDart>(
        'ffc_ts_demux_output_bound',
      ),
      _feed = lib.library.lookupFunction<_FeedC, _FeedDart>(
        'ffc_ts_demux_feed',
      );

  final _NewDart _new;
  final _FreeDart _free;
  final Pointer<NativeFunction<_FreeC>> _freePtr;
  final _NeedDart _need;
  final _BoundDart _bound;
  final _FeedDart _feed;

  static FushiComputeTs? _instance;

  /// 默认库上的绑定；库不可用或缺符号抛 [FushiComputeUnavailableError]。
  static FushiComputeTs get instance =>
      _instance ??= bind(FushiCompute.require());

  /// 在指定库上绑定（测试用）。缺符号抛 [FushiComputeUnavailableError]。
  static FushiComputeTs bind(FushiCompute lib) {
    try {
      return FushiComputeTs._(lib);
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('ts', e.message ?? e);
    }
  }

  /// 新建解复用器句柄（原生内存，地址可以跨 isolate 传；用完 [close]）。
  int open() {
    final Pointer<Void> h = _new();
    if (h == nullptr) throw StateError('fushi_compute ffc_ts_demux_new failed');
    return h.address;
  }

  /// 释放 [open] 的句柄。
  void close(int handle) => _free(Pointer<Void>.fromAddress(handle));

  /// 给 [NativeFinalizer] 用的释放函数。
  Pointer<NativeFunction<Void Function(Pointer<Void>)>> get finalizer =>
      _freePtr;

  /// 下次 [feed] 的数据必须从这个文件偏移开始。
  int needOffset(int handle) => _need(Pointer<Void>.fromAddress(handle));

  /// 喂文件从 [base]（必须等于 [needOffset]）到当前文件尾的字节，返回本次新交出的 PES。
  /// [complete] 时按文件已写完收尾，之后该句柄不再接受输入。
  List<FfcTsPacket> feed(
    int handle,
    Uint8List data, {
    required int base,
    required bool complete,
  }) {
    final Pointer<Void> h = Pointer<Void>.fromAddress(handle);
    final Pointer<Uint8> src = NativeScratch.input.reserve(data.length);
    src.asTypedListOutOfLine(data.length).setAll(0, data);
    final int cap = _bound(h, data.length);
    final Pointer<Uint8> out = NativeScratch.output.reserve(cap);
    final Pointer<Size> outLen = malloc<Size>();
    try {
      final int status = _feed(
        h,
        src,
        data.length,
        base,
        complete ? 1 : 0,
        out,
        cap,
        outLen,
      );
      if (status != FfcStatus.ok) {
        throw StateError(
          'fushi_compute ffc_ts_demux_feed failed: status $status',
        );
      }
      final int n = outLen.value;
      // 一次拷回 Dart 堆，各包取它的视图（不逐包分配）。
      final Uint8List bytes = Uint8List.fromList(out.asTypedListOutOfLine(n));
      final ByteData view = ByteData.sublistView(bytes);
      final List<FfcTsPacket> packets = <FfcTsPacket>[];
      int o = 0;
      while (o + 12 <= n) {
        final int pts = view.getInt64(o, Endian.host);
        final int len = view.getUint32(o + 8, Endian.host);
        o += 12;
        packets.add((
          pts90k: pts,
          data: Uint8List.sublistView(bytes, o, o + len),
        ));
        o += len;
      }
      return packets;
    } finally {
      malloc.free(outLen);
    }
  }

  /// 一次性解完整段字节（[complete] 为假 = 文件还在增长，尾部没收完的不交出）。
  List<FfcTsPacket> demuxAll(Uint8List data, {required bool complete}) {
    final int h = open();
    try {
      return feed(h, data, base: 0, complete: complete);
    } finally {
      close(h);
    }
  }
}
