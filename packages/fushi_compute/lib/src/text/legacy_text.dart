import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';

// 旧编码探测的绑定：短字节串整批（`ffc_text_legacy_decode`，判据在
// native/fushi_compute/src/legacy_text.rs，与曲库 ID3 乱码修复同一份源码）与整份文档
// （`ffc_text_decode_document`，native/fushi_compute/src/document_charset.rs：chardetng 认
// EUC-KR / 单字节编码，中日编码交给 legacy_text）。
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

typedef _LegacyDecodeDocumentC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _LegacyDecodeDocumentDart =
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);

/// [LegacyTextDecoder.decodeBatch] 判出的编码（与原生输出里的代号 1..4 同序）。
enum LegacyTextEncoding { shiftJis, gbk, eucJp, big5 }

/// 本地多字节编码的探测与解码：一批同源短字节串（如同一个 zip 里没带 UTF-8 标志的条目名）
/// 走 [decodeBatch]，一整份文本文件走 [decodeDocument]。
abstract final class LegacyTextDecoder {
  static _LegacyDecodeDart? _decode;
  static _LegacyDecodeDocumentDart? _decodeDocument;

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

  static _LegacyDecodeDocumentDart _loadDocument() {
    final FushiCompute compute = FushiCompute.require();
    // 故意不是 leaf 调用：整份文档的解码与输入等长（1 MB 约 55～95 ms），调用方把大输入放
    // 后台 isolate，而 leaf 调用期间线程到不了 safepoint，同一 isolate group 的 GC（含 UI
    // isolate 触发的）要等它返回。输入已拷进原生内存、原生侧不回调 Dart，不需要 leaf。
    try {
      return compute.library
          .lookupFunction<_LegacyDecodeDocumentC, _LegacyDecodeDocumentDart>(
            'ffc_text_decode_document',
          );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('text', e.message ?? e);
    }
  }

  /// **整份文档**（一个字幕 / 歌词 / 播放列表 / 纯文本文件的全部字节）判编码并解码，
  /// `encoding` 是判出编码的 WHATWG 名（`Shift_JIS` / `GBK` / `EUC-JP` / `Big5` / `EUC-KR` /
  /// `windows-1251` …）。chardetng 认出的 EUC-KR、单字节编码直接采用；中日编码的候选与计分
  /// 同 [decodeBatch]，容错口径按整份文件放宽（少量坏字节解成 U+FFFD）。判据见
  /// native/fushi_compute/src/document_charset.rs。
  ///
  /// 全 ASCII、基本是 UTF-8（只坏了少数几处）、或没有编码能在容错口径内解开时返回 null，
  /// 调用方保持原有处理。开头的 UTF-8 BOM 不算正文（现实里有「UTF-8 BOM + 本地编码正文」
  /// 的坏文件）。
  ///
  /// 同步调用，耗时与输入等长（实测约 55～95 ms / MB，1 ms ≈ 12～18 KB）：大输入由调用方
  /// 放后台 isolate（`fushi_audio` 的 `decodeLegacyText` 按 `kLegacyDecodeInlineMaxBytes` 分流）。
  static ({String encoding, String text})? decodeDocument(Uint8List bytes) {
    final int length = bytes.length;
    if (length == 0) return null;
    final _LegacyDecodeDocumentDart decode = _decodeDocument ??=
        _loadDocument();
    final FushiCompute compute = FushiCompute.require();
    final Pointer<Uint8> input = calloc<Uint8>(length);
    final Pointer<Pointer<Uint8>> outPtr = calloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = calloc<Size>();
    try {
      input.asTypedListOutOfLine(length).setAll(0, bytes);
      final int status = decode(input, length, outPtr, outLen);
      if (status != FfcStatus.ok) {
        throw StateError('ffc_text_decode_document failed with status $status');
      }
      final Pointer<Uint8> out = outPtr.value;
      final int len = outLen.value;
      if (out == nullptr) return null;
      try {
        final Uint8List view = out.asTypedListOutOfLine(len);
        final int nameLength = ByteData.sublistView(
          view,
        ).getUint32(0, Endian.little);
        return (
          encoding: ascii.decode(
            Uint8List.sublistView(view, 4, 4 + nameLength),
          ),
          text: utf8.decode(Uint8List.sublistView(view, 4 + nameLength)),
        );
      } finally {
        compute.freeBytes(out, len);
      }
    } finally {
      calloc.free(input);
      calloc.free(outPtr);
      calloc.free(outLen);
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
