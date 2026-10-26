import 'dart:ffi';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

/// 本包所有长寿命原生内存（每 isolate 一份的输入 / 输出暂存区、固定小输出槽、对象自带的
/// 原生数组）的唯一 owner：分配即挂 [NativeFinalizer]，对象不可达或所在 isolate 退出时
/// 释放；实现 [Finalizable]，持有它的局部变量 / `this` 在作用域内一直保活。
///
/// 每次调用都新 malloc 一块几 MB 的缓冲，代价主要是缺页（大块分配直接走系统页，每次都是
/// 新页）：实测 600 条字幕合成里这部分占了一半时间。暂存区复用同一批页；它从不交给调用方
/// （结果一律拷回 Dart 堆）。
///
/// 只能同步用：拿到的指针在下一次 [reserve] / [release] 前有效。内核调用都是同步 FFI，
/// 同一 isolate 里不会交错。持有它的类必须 `implements Finalizable`：从它取出的裸指针交给
/// 原生调用时，owner 必须仍在保活域里（守卫 test/native_lifetime_guard_test.dart）。
final class NativeScratch implements Finalizable {
  /// 可增长的暂存区：首次 [reserve] 至少分配 [minCapacity] 字节。
  NativeScratch({int minCapacity = 64 * 1024})
    : _minCapacity = math.max(1, minCapacity);

  /// 定长槽（输出参数、密钥缓冲、对象自带的原生数组）：立即分配 [bytes] 字节并清零，
  /// 之后 [pointer] 不变（不要再对它 [reserve] 更大的尺寸）。
  NativeScratch.fixed(int bytes) : _minCapacity = math.max(1, bytes) {
    _allocate(_minCapacity);
    _ptr.asTypedListOutOfLine(_capacity).fillRange(0, _capacity, 0);
  }

  static final NativeFinalizer _finalizer = NativeFinalizer(malloc.nativeFree);

  final int _minCapacity;
  Pointer<Uint8> _ptr = nullptr;
  int _capacity = 0;

  /// 超过这个大小的暂存区不长期留着：下一次小请求时换回小块（长命 isolate 不因为偶尔一张
  /// 4K 图一直攥着几十 MB）。
  static const int retainLimit = 16 << 20;

  /// 当前块的字节数（尚未分配时为 0）。
  int get capacity => _capacity;

  /// 当前块（尚未分配时先按最小容量分配）。永不为 nullptr。
  Pointer<Uint8> get pointer => _capacity == 0 ? reserve(0) : _ptr;

  /// 至少 [bytes] 字节的暂存区（内容未定义）。
  ///
  /// 零长请求同样返回一块非空内存：冷 isolate 的第一次调用与暖缓存之后的调用必须交给原生侧
  /// 同一种指针形态（空输入 → 原生按坏输入处理），不能冷的时候传 nullptr（HBK-AUDIT-006）。
  Pointer<Uint8> reserve(int bytes) {
    if (_capacity == 0 ||
        bytes > _capacity ||
        (_capacity > retainLimit && bytes <= retainLimit)) {
      int next = math.max(bytes, _minCapacity);
      // 在保留上限内按倍增长，逐步变长的输入不至于每次都重新分配。
      final int doubled = _capacity * 2;
      if (bytes > _capacity && doubled > next && doubled <= retainLimit) {
        next = doubled;
      }
      _allocate(next);
    }
    return _ptr;
  }

  /// 立即归还当前块（之后再 [reserve] / [pointer] 会重新分配）；幂等。
  void release() {
    if (_capacity == 0) return;
    _finalizer.detach(this);
    malloc.free(_ptr);
    _ptr = nullptr;
    _capacity = 0;
  }

  void _allocate(int bytes) {
    release();
    _ptr = malloc<Uint8>(bytes);
    _capacity = bytes;
    _finalizer.attach(this, _ptr.cast(), detach: this, externalSize: bytes);
  }

  /// 输入用的那一块（每 isolate 一个）。
  static final NativeScratch input = NativeScratch();

  /// 输出用的那一块（每 isolate 一个）。
  static final NativeScratch output = NativeScratch();
}
