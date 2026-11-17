import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';

// 本地多字节编码探测（`ffc_text_legacy_decode`，判据在
// native/fushi_compute/src/legacy_text.rs，与曲库 ID3 乱码修复同一份源码）的绑定。
//
// 唯一的运行时实现：没有 Dart 回退（Dart 本身也没有 Shift_JIS / GBK 解码器）。原生库或
// 符号缺失时首次使用抛 [FushiComputeUnavailableError]。

typedef _LegacyDecodeC =
    Int32 Function(
      Pointer<Uint8>,
      Pointer<Uint32>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _LegacyDecodeDart =
    int Function(
      Pointer<Uint8>,
      Pointer<Uint32>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );

/// [LegacyTextDecoder.decodeBatch] 判出的编码（与原生输出里的代号 1..4 同序）。
enum LegacyTextEncoding { shiftJis, gbk, eucJp, big5 }

/// 一批同源原始字节串（如同一个 zip 里没带 UTF-8 标志的条目名）整批判编码并解码。
abstract final class LegacyTextDecoder {
  static _LegacyDecodeDart? _decode;

  static _LegacyDecodeDart _load() {
    final FushiCompute compute = FushiCompute.require();
    // lookup 名写成字符串字面量：verify_abi.sh 从绑定源码抓期望符号集。
    try {
      return compute.library.lookupFunction<_LegacyDecodeC, _LegacyDecodeDart>(
        'ffc_text_legacy_decode',
        isLeaf: true,
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('text', e.message ?? e);
    }
  }

  /// [raw] 整批判编码（Shift_JIS → GBK → EUC-JP → Big5，整批一起计分），判出时返回编码与
  /// 逐项解码结果（与输入同序）；全 ASCII、像真 Latin-1 文本或没有候选能零错误解开时返回
  /// null，调用方保持原样。
  static ({LegacyTextEncoding encoding, List<String> texts})? decodeBatch(
    List<Uint8List> raw,
  ) {
    final int count = raw.length;
    if (count == 0) return null;
    final _LegacyDecodeDart decode = _decode ??= _load();
    final FushiCompute compute = FushiCompute.require();
    int total = 0;
    for (final Uint8List item in raw) {
      total += item.length;
    }
    final Pointer<Uint8> bytes = calloc<Uint8>(total == 0 ? 1 : total);
    final Pointer<Uint32> offsets = calloc<Uint32>(count + 1);
    final Pointer<Pointer<Uint8>> outPtr = calloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = calloc<Size>();
    try {
      final Uint8List bytesView = bytes.asTypedListOutOfLine(
        total == 0 ? 1 : total,
      );
      final Uint32List offsetsView = offsets.asTypedListOutOfLine(count + 1);
      int cursor = 0;
      for (int i = 0; i < count; i++) {
        offsetsView[i] = cursor;
        bytesView.setAll(cursor, raw[i]);
        cursor += raw[i].length;
      }
      offsetsView[count] = cursor;
      final int status = decode(bytes, offsets, count, outPtr, outLen);
      if (status != FfcStatus.ok) {
        throw StateError('ffc_text_legacy_decode failed with status $status');
      }
      final Pointer<Uint8> out = outPtr.value;
      final int len = outLen.value;
      if (out == nullptr) return null;
      try {
        final Uint8List view = out.asTypedListOutOfLine(len);
        final ByteData data = ByteData.sublistView(view);
        final int code = data.getUint32(0, Endian.little);
        final int base = 4 * (count + 2);
        final List<String> texts = <String>[
          for (int i = 0; i < count; i++)
            utf8.decode(
              Uint8List.sublistView(
                view,
                base + data.getUint32(4 * (1 + i), Endian.little),
                base + data.getUint32(4 * (2 + i), Endian.little),
              ),
            ),
        ];
        return (encoding: LegacyTextEncoding.values[code - 1], texts: texts);
      } finally {
        compute.freeBytes(out, len);
      }
    } finally {
      calloc.free(bytes);
      calloc.free(offsets);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }
}
