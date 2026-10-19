import 'dart:ffi';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

/// 每个 isolate 一块只增不减的原生暂存区，给内核调用当输入 / 输出缓冲。
///
/// 每次调用都新 malloc 一块几 MB 的缓冲，代价主要是缺页（大块分配直接走系统页，每次都是
/// 新页）：实测 600 条字幕合成里这部分占了一半时间。暂存区复用同一批页；它从不交给调用方
/// （结果一律拷回 Dart 堆），isolate 退出时由 [NativeFinalizer] 释放。
///
/// 只能同步用：拿到的指针在下一次 [reserve] 前有效。内核调用都是同步 FFI，同一 isolate 里
/// 不会交错。
final class NativeScratch implements Finalizable {
  NativeScratch();

  static final NativeFinalizer _finalizer = NativeFinalizer(malloc.nativeFree);

  Pointer<Uint8> _ptr = nullptr;
  int _capacity = 0;

  /// 超过这个大小的暂存区不长期留着：下一次小请求时换回小块（长命 isolate 不因为偶尔一张
  /// 4K 图一直攥着几十 MB）。
  static const int retainLimit = 16 << 20;

  /// 至少 [bytes] 字节的暂存区（内容未定义）。
  Pointer<Uint8> reserve(int bytes) {
    if (bytes > _capacity ||
        (_capacity > retainLimit && bytes <= retainLimit)) {
      if (_capacity > 0) {
        _finalizer.detach(this);
        malloc.free(_ptr);
      }
      _capacity = math.max(bytes, 64 * 1024);
      _ptr = malloc<Uint8>(_capacity);
      _finalizer.attach(
        this,
        _ptr.cast(),
        detach: this,
        externalSize: _capacity,
      );
    }
    return _ptr;
  }

  /// 输入用的那一块（每 isolate 一个）。
  static final NativeScratch input = NativeScratch();

  /// 输出用的那一块（每 isolate 一个）。
  static final NativeScratch output = NativeScratch();
}
