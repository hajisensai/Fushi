import 'dart:typed_data';

import 'fushi_rwkv_library.dart';

/// `FrwkvReview.present` 的位（与 native/fushi_rwkv/src/lib.rs 一致）。
abstract final class FrwkvPresent {
  static const int noteId = 1 << 0;
  static const int deckId = 1 << 1;
  static const int presetId = 1 << 2;
  static const int duration = 1 << 3;
  static const int cardType = 1 << 4;
  static const int dayOffset = 1 << 5;
  static const int elapsedDays = 1 << 6;
  static const int elapsedSeconds = 1 << 7;
}

/// 一批 `FrwkvReview`（80 字节一行，小端，与 C 结构体同布局），整块交给原生库：
/// 全量回放可能是几百万行，逐行跨 FFI 不可接受。
class RwkvRows {
  RwkvRows([int capacity = 64])
    : _bytes = ByteData(capacity.clamp(1, 1 << 30) * kFrwkvReviewSize);

  /// 从已编码的字节构造（长度须是 80 的倍数）。
  RwkvRows.fromBytes(Uint8List bytes)
    : _bytes = ByteData.sublistView(bytes),
      _length = bytes.length ~/ kFrwkvReviewSize {
    if (bytes.length % kFrwkvReviewSize != 0) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'not a multiple of $kFrwkvReviewSize',
      );
    }
  }

  ByteData _bytes;
  int _length = 0;

  int get length => _length;
  bool get isEmpty => _length == 0;

  /// 已写入的行（不复制）。
  Uint8List get bytes => _bytes.buffer.asUint8List(
    _bytes.offsetInBytes,
    _length * kFrwkvReviewSize,
  );

  /// 追加一行。`ease`：0 = 无评分，1..4 = Again/Hard/Good/Easy。可空字段为 null 即「没有」。
  /// 字段语义见 native/fushi_rwkv/README.md「字段语义」。
  void add({
    required int cardId,
    int? noteId,
    int? deckId,
    int? presetId,
    required int ease,
    int? durationMs,
    int? cardType,
    int? dayOffset,
    int? elapsedDays,
    int? elapsedSeconds,
  }) {
    if (ease < 0 || ease > 4) {
      throw ArgumentError.value(ease, 'ease', 'must be 0..4');
    }
    if ((_length + 1) * kFrwkvReviewSize > _bytes.lengthInBytes) {
      final ByteData grown = ByteData(_bytes.lengthInBytes * 2);
      grown.buffer.asUint8List().setRange(0, _length * kFrwkvReviewSize, bytes);
      _bytes = grown;
    }
    final int at = _length * kFrwkvReviewSize;
    int present = 0;
    void put(int index, int? value, int bit) {
      _bytes.setInt64(at + 8 * index, value ?? 0, Endian.little);
      if (value != null) present |= bit;
    }

    _bytes.setInt64(at, cardId, Endian.little);
    put(1, noteId, FrwkvPresent.noteId);
    put(2, deckId, FrwkvPresent.deckId);
    put(3, presetId, FrwkvPresent.presetId);
    put(4, durationMs, FrwkvPresent.duration);
    put(5, cardType, FrwkvPresent.cardType);
    put(6, dayOffset, FrwkvPresent.dayOffset);
    put(7, elapsedDays, FrwkvPresent.elapsedDays);
    put(8, elapsedSeconds, FrwkvPresent.elapsedSeconds);
    _bytes.setUint32(at + 72, present, Endian.little);
    _bytes.setUint8(at + 76, ease);
    _bytes.setUint8(at + 77, 0);
    _bytes.setUint8(at + 78, 0);
    _bytes.setUint8(at + 79, 0);
    _length++;
  }

  /// 追加 [other] 的全部行（原样复制字节）。
  void addRows(RwkvRows other) {
    final int needed = (_length + other.length) * kFrwkvReviewSize;
    if (needed > _bytes.lengthInBytes) {
      final ByteData grown = ByteData(
        needed > 2 * _bytes.lengthInBytes ? needed : 2 * _bytes.lengthInBytes,
      );
      grown.buffer.asUint8List().setRange(0, _length * kFrwkvReviewSize, bytes);
      _bytes = grown;
    }
    _bytes.buffer
        .asUint8List(_bytes.offsetInBytes)
        .setRange(_length * kFrwkvReviewSize, needed, other.bytes);
    _length += other.length;
  }

  int cardIdAt(int index) =>
      _bytes.getInt64(index * kFrwkvReviewSize, Endian.little);
  int easeAt(int index) => _bytes.getUint8(index * kFrwkvReviewSize + 76);
  int dayOffsetAt(int index) =>
      _bytes.getInt64(index * kFrwkvReviewSize + 48, Endian.little);
}
